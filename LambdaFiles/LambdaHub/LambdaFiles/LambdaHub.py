
import json

def lambda_handler(event, context):
    # This is an auto-generated basic Lambda function.
    print("Executing the auto-generated basic Lambda function.")
    return {
        'statusCode': 200,
        'body': json.dumps('Successfully executed the basic function!')
    }
