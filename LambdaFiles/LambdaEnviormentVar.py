import boto3
import os

#Read Enviorment Variables
LambdaName = os.getenv("LambdaName")
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


dynamodb1 = boto3.resource('dynamodb', region_name=TableRegion1).Table(TableName1)
dynamodb2 = boto3.resource('dynamodb', region_name=TableRegion2).Table(TableName2)
lambda_client = boto3.client('lambda', region_name=Region)
s3 = boto3.client('s3', region_name=S3Region) 

def lambda_handler(event, context):
    dynamodb2.put_item(Item={'ID': "1", "Owner": f"Criado por {LambdaName}"})
    print ("Lambda Name ",LambdaName)
    print ("Lambda Region ",Region)
    print ("Lambda Account ",AccountID)
    print ("Bucket Name",S3Name)
    print ("DynamoDB 1 ",TableName1)
    print ("DynamoDB 2 ",TableName2)
    print ("SQS Name",SQSName)
    print ("SQS ARN",SQSARN)


