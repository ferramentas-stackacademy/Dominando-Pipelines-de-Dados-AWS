import boto3
import pandas as pd
import sqlalchemy
import logging
import os
import json
import urllib.parse

from math import ceil

logging.basicConfig(format='[%(levelname)s] ; %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)


class DataProcessor:
    def __init__(self):
        self.sqs_queue_url = os.environ.get('sqs_queue_url')
        self.sqs = boto3.client('sqs')
        self.s3 = boto3.client('s3')
        self.redshift_conn = sqlalchemy.create_engine(
            f'postgresql+psycopg2://{os.environ.get("redshift_user")}:{os.environ.get("redshift_password")}@{os.environ.get("redshift_host")}:5439/{os.environ.get("redshift_db")}',
            pool_pre_ping=True
        ).connect()

    def process_data(self) -> None:
        """Process data from SQS queue and ingest it to Redshift.

        This function is responsible for processing the data from the SQS queue and ingest it to Redshift.
        """
        while True:
            message = self.get_message_from_queue()
            if not message:
                break
            receipt_handle = message[0].get("ReceiptHandle")
            receive_count = message[0].get("Attributes").get("ApproximateReceiveCount")
            try:
                queue_message = json.loads(message[0].get('Body'))
                bucket_name = queue_message.get('Records')[0]['s3']['bucket']['name']
                obj_key = urllib.parse.unquote_plus(
                    queue_message['Records'][0]['s3']['object']['key'], encoding='utf-8'
                )
                file_data = self.get_file_from_s3(bucket_name, obj_key)
                file_data = self.load_and_clean_data(file_data)
                self.ingest_data_to_redshift(file_data)
                self.delete_message_from_queue(receipt_handle)
                logger.info(f"Successfully processed and ingested data from {obj_key}.")
            except Exception as e:
                logger.error(f"Error processing data from {message}: {e}")
                if int(receive_count) >= 2:
                    self.delete_message_from_queue(receipt_handle)
                    logger.info(f"""Message with receipt handle {receipt_handle} has been
                    deleted after {receive_count} failures.""")

    def get_message_from_queue(self) -> dict:
        """Get message from SQS queue.

        Returns:
            dict: Message from SQS queue.
        """
        return self.sqs.receive_message(
            QueueUrl=self.sqs_queue_url, MaxNumberOfMessages=1, AttributeNames=['ApproximateReceiveCount'],
            VisibilityTimeout=3600
        ).get('Messages', [])

    def get_file_from_s3(self, bucket_name, obj_key) -> str:
        """Get file from S3 bucket.

        Args:
            bucket_name (str): Bucket name.
            obj_key (str): Object key.

        Returns:
            dict: File data.

        Raises:
            Exception: If the object does not exist.
            KeyError: If the object does not have a 'Body' key.
        """
        self.s3.download_file(Bucket=bucket_name, Key=obj_key, Filename="./data.tsv")
        return "./data.tsv"

    def load_and_clean_data(self, file_data) -> pd.DataFrame:
        """Load and clean data. Convert 'genres' from comma-separated string to list.
        Replace  with None in the 'endYear' column.

        Args:
            file_data: File data.

        Returns:
            pandas.DataFrame: Dataframe with the loaded and cleaned data.
        """

        def converter(x):
            return None if pd.isna(x) or x == "\\N" else x

        data = pd.read_csv(
            file_data, sep='\\t', header=0, names=[
                "title_id", "title_type", "primary_title", "original_title",
                "is_adult", "start_year", "end_year", "runtime_minutes", "genres"
            ], converters={
                "title_type": lambda x: converter(x),
                "primary_title": lambda x: converter(x),
                "original_title": lambda x: converter(x),
                "is_adult": lambda x: converter(x),
                "start_year": lambda x: converter(x),
                "end_year": lambda x: converter(x),
                "runtime_minutes": lambda x: converter(x),
                "genres": lambda x: converter(x)
            }
        )

        data['genres'] = data['genres'].apply(lambda x: None if pd.isna(x) else x.split(','))
        for col in ['title_type', 'primary_title', 'original_title']:
            data[col] = data[col].apply(lambda x: None if pd.isna(x) else str(x).translate(str(x).maketrans(
                {"'": "''", "%": "%%", "\\": ""})))
        return data

    def ingest_data_to_redshift(self, data) -> None:
        """Ingest data to Redshift. Create the 'ac' table if it does not exist. Append the data to the 'ac' table.

        Args:
            data (pandas.DataFrame): Dataframe with the data to be ingested.

        Returns:
            None
        """
        insert_template = """
         INSERT INTO movies_shows (title_id, title_type, primary_title, original_title, is_adult,
                                    start_year, end_year, runtime_minutes, genres)
         VALUES {values}
         """
        value_template = "('{title_id}', '{title_type}', '{primary_title}', '{original_title}', {is_adult}," \
                         "{start_year}, {end_year}, {runtime_minutes}, JSON_PARSE('{genres}'))"
        total_chunk_size = 1_000
        total_chunks = ceil(len(data) / total_chunk_size)
        logger.info(f"Total chunk size: {total_chunk_size} - Total rows: {len(data)} - Total chunks: {total_chunks}")
        for i in range(total_chunks):
            logger.info(f"Processing chunk {i} of {total_chunks} - Start: {i * total_chunk_size} - End: {(i + 1) * total_chunk_size}")
            df_chunk = data[i * total_chunk_size:(i + 1) * total_chunk_size].copy()
            values = ', '.join(
                value_template.format(
                    title_id=row['title_id'],
                    title_type=row['title_type'] if row['title_type'] else 'null',
                    primary_title=row['primary_title'] if row['primary_title'] else 'null',
                    original_title=row['original_title'] if row['original_title'] else 'null',
                    is_adult=row['is_adult'] if row['is_adult'] else 'null',
                    start_year=row['start_year'] if row['start_year'] else 'null',
                    end_year=row['end_year'] if row['end_year'] else 'null',
                    runtime_minutes=row['runtime_minutes'] if row['runtime_minutes'] else 'null',
                    genres=json.dumps(row['genres']) if row['genres'] else 'null'
                )
                for _, row in df_chunk.iterrows()
            )
            self.redshift_conn.execute(insert_template.format(values=values))
            logger.info(f"Processed chunk {i} of {total_chunks} - Start: {i * total_chunk_size} - End: {(i + 1) * total_chunk_size}")
        return None

    def delete_message_from_queue(self, receipt_handle) -> None:
        """Delete message from SQS queue.

        Args:
            receipt_handle (str): Receipt handle of the message to be deleted.

        Returns:
            None
        """
        self.sqs.delete_message(QueueUrl=self.sqs_queue_url,
                                ReceiptHandle=receipt_handle)  # delete received message from queue
        return None


if __name__ == '__main__':
    processor = DataProcessor()
    processor.process_data()
