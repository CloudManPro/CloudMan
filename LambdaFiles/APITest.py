import boto3
import json
import os

# Retrieve DynamoDB table information from environment variables
dynamodb_table_name = os.environ['aws_dynamodb_table_Target_Name_0']
dynamodb_region = os.environ['aws_dynamodb_table_Target_Region_0']
# Create a DynamoDB resource with the specified region
dynamodb = boto3.resource('dynamodb', region_name=dynamodb_region)
table = dynamodb.Table(dynamodb_table_name)

# Headers to enable CORS
cors_headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
}
# Used with CloudMan CI/CD
Version = os.environ.get('CloudManCICDVersion', "")
Stage = os.environ.get('CloudManCICDStage', "")
AppName = os.environ.get('CloudManCICDAppName', "")


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
                'headers': cors_headers,
                'body': json.dumps('Key and Data must be a valid value.')
            }
        # Save or update the item in DynamoDB
        table.put_item(Item={'ID': key, 'data': data})
        print(f"Data saved or updated for key : {key} using {http_method}")
        return {
            'statusCode': 200,
            'headers': cors_headers,
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
            # Considerando que AppName, Stage e Version já foram lidas anteriormente
            # Modifica o valor do atributo 'data' para adicionar a string desejada
            item = response['Item']
            if 'data' in item and AppName != "":
                item['data'] += f", from App Name:{AppName} Stage:{Stage} Version:{Version}"

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
            'headers': cors_headers,
            'body': json.dumps('Unsupported HTTP method.')
        }
