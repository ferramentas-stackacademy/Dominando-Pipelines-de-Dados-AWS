FROM python:3.10
WORKDIR /usr/src/app
COPY ./requirements.txt ./
COPY ./data_processor.py ./
COPY ./credentials /root/.aws/credentials
RUN pip install --no-cache-dir -r requirements.txt
CMD [ "python", "./data_processor.py" ]