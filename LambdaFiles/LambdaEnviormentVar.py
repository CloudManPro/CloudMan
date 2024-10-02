import boto3
import os

# Read Environment Variables
LAMBDA_NAME = os.getenv("LAMBDA_NAME")
REGION = os.getenv("REGION")
ACCOUNT_ID = os.getenv("ACCOUNT")
S3_NAME = os.getenv("AWS_S3_BUCKET_TARGET_NAME_0")
S3_REGION = os.getenv("AWS_S3_BUCKET_TARGET_REGION_0")
TABLE_NAME_1 = os.getenv("AWS_DYNAMODB_TABLE_TARGET_NAME_0")
TABLE_REGION_1 = os.getenv("AWS_DYNAMODB_TABLE_TARGET_REGION_0")
TABLE_NAME_2 = os.getenv("AWS_DYNAMODB_TABLE_TARGET_NAME_1")
TABLE_REGION_2 = os.getenv("AWS_DYNAMODB_TABLE_TARGET_REGION_1")
SQS_NAME = os.getenv("AWS_SQS_QUEUE_SOURCE_NAME_0")
SQS_ARN = os.getenv("AWS_SQS_QUEUE_SOURCE_ARN_0")

# Initialize AWS resources
DYNAMODB_1 = boto3.resource(
    'dynamodb', region_name=TABLE_REGION_1).Table(TABLE_NAME_1)
DYNAMODB_2 = boto3.resource(
    'dynamodb', region_name=TABLE_REGION_2).Table(TABLE_NAME_2)
LAMBDA_CLIENT = boto3.client('lambda', region_name=REGION)
S3_CLIENT = boto3.client('s3', region_name=S3_REGION)


def lambda_handler(event, context):
    # Example operation on DynamoDB
    DYNAMODB_2.put_item(Item={'ID': "1", "Owner": f"Criado por {LAMBDA_NAME}"})

    # Print out values for debugging
    print("Lambda Name:", LAMBDA_NAME)
    print("Lambda Region:", REGION)
    print("Lambda Account:", ACCOUNT_ID)
    print("Bucket Name:", S3_NAME)
    print("DynamoDB 1:", TABLE_NAME_1)
    print("DynamoDB 2:", TABLE_NAME_2)
    print("SQS Name:", SQS_NAME)
    print("SQS ARN:", SQS_ARN)
