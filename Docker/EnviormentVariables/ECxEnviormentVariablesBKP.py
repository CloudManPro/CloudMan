import boto3
import os
import logging
import watchtower
from fastapi import FastAPI, Request

#Read Enviorment Variables
InstanceName = os.getenv("Name")
Region = os.getenv("Region")
AccountID = os.getenv("Account")
S3Name = os.getenv("aws_s3_bucket_Target_Name_0")
S3Region = os.getenv("aws_s3_bucket_Target_Region_0")
TableName1 = os.getenv("aws_dynamodb_table_Target_Name_0")
TableRegion1 = os.getenv("aws_dynamodb_table_Target_Region_0")
TableName2 = os.getenv("aws_dynamodb_table_Target_Name_1")
TableRegion2 = os.getenv("aws_dynamodb_table_Target_Region_1")
SQSName = os.getenv("aws_sqs_queue_Source_Name_0")
SQSARN = os.getenv("aws_sqs_queue_Source_ARN_0")
VarLogs = os.environ.get('EnableStatusLogs', "True")
boto3_session=boto3.Session(region_name=Region)
CloudWatchName = os.environ.get('aws_cloudwatch_log_group_Target_Name_0', "")
if VarLogs == "True" and CloudWatchName != "":
    StatusLogsEnabled = True
else:
    StatusLogsEnabled = False
# Configurar logging
app = FastAPI()
'''if CloudWatchName != "":
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)
    cw_handler = watchtower.CloudWatchLogHandler(
        log_group=CloudWatchName,
        stream_name=InstanceName
    )
    logger.addHandler(cw_handler)
    logger.info(f"EC2 Host: {InstanceName} Region {Region}")
dynamodb1 = boto3.resource('dynamodb', region_name=TableRegion1).Table(TableName1)
dynamodb2 = boto3.resource('dynamodb', region_name=TableRegion2).Table(TableName2)
s3 = boto3.client('s3', region_name=S3Region) 
dynamodb2.put_item(Item={'ID': "1", "Owner": f"Criado por {InstanceName}"})
logger.info (f"Instance Name {InstanceName}")
logger.info (f"Lambda Region {Region}")
logger.info (f"Lambda Account {AccountID}")
logger.info (f"Bucket Name {S3Name}")
logger.info (f"DynamoDB 1 {TableName1}")
logger.info (f"DynamoDB 2 {TableName2}")
logger.info (f"SQS Name {SQSName}")
logger.info (f"SQS ARN {SQSARN}")'''


