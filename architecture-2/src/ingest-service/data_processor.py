import boto3
import pandas as pd
import sqlalchemy
import logging
import os
import json
import urllib.parse
import random

logging.basicConfig(format="[%(levelname)s] ; %(message)s", level=logging.DEBUG)
logger = logging.getLogger(__name__)


class DataProcessor:
    def __init__(self):
        self.sqs_queue_url = os.environ.get("sqs_queue_url")
        self.sqs = boto3.client("sqs")
        self.s3 = boto3.client("s3")

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
                queue_message = json.loads(message[0].get("Body"))
                bucket_name = queue_message.get("Records")[0]["s3"]["bucket"]["name"]
                obj_key = urllib.parse.unquote_plus(
                    queue_message["Records"][0]["s3"]["object"]["key"], encoding="utf-8"
                )
                file_data = self.get_file_from_s3(bucket_name, obj_key)
                file_data = self.load_and_clean_data(file_data)
                self.ingest_data(file_data)
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
            QueueUrl=self.sqs_queue_url, MaxNumberOfMessages=1, AttributeNames=["ApproximateReceiveCount"],
            VisibilityTimeout=3600
        ).get("Messages", [])

    def get_file_from_s3(self, bucket_name, obj_key) -> str:
        """Get file from S3 bucket.

        Args:
            bucket_name (str): Bucket name.
            obj_key (str): Object key.

        Returns:
            dict: File data.

        Raises:
            Exception: If the object does not exist.
            KeyError: If the object does not have a "Body" key.
        """
        self.s3.download_file(Bucket=bucket_name, Key=obj_key, Filename="./data.tsv")
        return "./data.tsv"

    def load_and_clean_data(self, file_data) -> pd.DataFrame:
        """Load and clean data. Convert "genres" from comma-separated string to list.
        Replace  with None in the "endYear" column.

        Args:
            file_data: File data.

        Returns:
            pandas.DataFrame: Dataframe with the loaded and cleaned data.
        """

        def converter(x):
            return None if pd.isna(x) or x == "\\N" else x

        data = pd.read_csv(
            file_data, sep="\\t", header=0, names=[
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

        data["genres"] = data["genres"].apply(lambda x: None if pd.isna(x) else x.split(","))
        for col in ["title_type", "primary_title", "original_title"]:
            data[col] = data[col].apply(lambda x: None if pd.isna(x) else str(x).translate(str(x).maketrans({"'": "''", "%": "%%", "\\": ""})))
        return data

    def ingest_data(self, data) -> None:
        """Ingest data to Redshift. Create the "ac" table if it does not exist. Append the data to the "ac" table.

        Args:
            data (pandas.DataFrame): Dataframe with the data to be ingested.

        Returns:
            None
        """
        file_path = f"./data_{random.randint(1, 1000000000000000000000)}.parquet"
        data.to_parquet(file_path, index=False)
        self.upload_to_s3(file_path)
        return None

    def upload_to_s3(self, file_path: str):
        """Upload file to S3 bucket.

        Args:
            file_path (str): Path to the file to be uploaded.

        Returns:
            None
        """
        self.s3.upload_file(file_path, os.environ.get("analytics_bucket"), file_path.split("/")[-1])
        return None

    def delete_message_from_queue(self, receipt_handle) -> None:
        """Delete message from SQS queue.

        Args:
            receipt_handle (str): Receipt handle of the message to be deleted.

        Returns:
            None
        """
        self.sqs.delete_message(QueueUrl=self.sqs_queue_url, ReceiptHandle=receipt_handle)
        return None


if __name__ == "__main__":
    try:
        processor = DataProcessor()
        processor.process_data()
    except Exception as e:
        logger.error(f"Error processing data: {e}")
        print(f"Error processing data: {e}")