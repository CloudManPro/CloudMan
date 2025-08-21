import boto3
import json
import os

# Retrieve DynamoDB table information from environment variables
DYNAMODB_TABLE_NAME = os.environ['AWS_DYNAMODB_TABLE_TARGET_NAME_0']
DYNAMODB_REGION = os.environ['AWS_DYNAMODB_TABLE_TARGET_REGION_0']

# Create a DynamoDB resource with the specified region
dynamodb = boto3.resource('dynamodb', region_name=DYNAMODB_REGION)
table = dynamodb.Table(DYNAMODB_TABLE_NAME)

# Headers to enable CORS
CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
}

# Used with CloudMan CI/CD
VERSION = os.environ.get('CLOUDMAN_CICD_VERSION', "")
STAGE = os.environ.get('CLOUDMAN_CICD_STAGE', "")
APP_NAME = os.environ.get('CLOUDMAN_CICD_APPNAME', "")


def lambda_handler(event, context):

    print("Event", event)
    http_method = event['httpMethod']
    print(f"Received HTTP method: {http_method}")

    if http_method in ['POST', 'PUT']:
        body = event['body']
        print("body", body)
        body = json.loads(body)
        print("body", body)
        key = body["Value"][0]
        data = body["Value"][1] + ":" + http_method

        if key == "" or data == "":
            return {
                'statusCode': 200,
                'headers': CORS_HEADERS,
                'body': json.dumps('Key and Data must be a valid value.')
            }
        # Save or update the item in DynamoDB
        table.put_item(Item={'ID': key, 'data': data})
        print(f"Data saved or updated for key : {key} using {http_method}")
        return {
            'statusCode': 200,
            'headers': CORS_HEADERS,
            'body': json.dumps(f"Data saved or updated for key : {key}, using {http_method}")
        }

    elif http_method == 'GET':
        # Checking if 'queryStringParameters' is None
        if event['queryStringParameters'] is None:
            return {
                'statusCode': 400,
                'body': json.dumps('No query string parameters provided.')
            }

        key = event['queryStringParameters']['ID']
        # Fetch the item from DynamoDB

        response = table.get_item(Key={'ID': key})

        if 'Item' in response:
            print(f"Item retrieved for key: {key}")
            # Considerando que APP_NAME, STAGE e VERSION já foram lidas anteriormente
            # Modifica o valor do atributo 'data' para adicionar a string desejada
            item = response['Item']
            if 'data' in item and APP_NAME != "":
                item['data'] += f", from App Name:{APP_NAME} Stage:{STAGE} Version:{VERSION}"

            return {
                'statusCode': 200,
                'body': json.dumps(item)
            }
        else:
            print(f"Key not found: {key}")
            return {
                'statusCode': 404,
                'body': json.dumps('Key not found')
            }

    else:
        print(f"Unsupported HTTP method: {http_method}")
        return {
            'statusCode': 400,
            'headers': CORS_HEADERS,
            'body': json.dumps('Unsupported HTTP method.')
        }
