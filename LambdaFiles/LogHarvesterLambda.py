import os
import boto3
import json

# Initialize CloudWatch Logs client outside the handler for context reuse
client = boto3.client('logs')

# Collect log group names from environment variables once, for reuse
log_groups = []
index = 0
while True:
    log_group_name = os.environ.get(f"aws_cloudwatch_log_group_Source_Name_{index}")
    if log_group_name is None:
        break
    log_groups.append(log_group_name)
    index += 1

def lambda_handler(event, context):
    # Parse the timestamp from the POST request body
    body = json.loads(event['body'])
    timestamp = body['timestamp']

    # Get the search string from environment variable
    search_string = os.environ.get("StringSearch")

    # Store filtered logs
    filtered_logs = []

    # Iterate through each log group and filter logs
    for group in log_groups:
        # Query logs in the log group based on filters
        queried_logs = client.filter_log_events(
            logGroupName=group,
            startTime=int(timestamp),
            filterPattern=search_string
        )

        # Add filtered logs to the list
        filtered_logs.extend(queried_logs.get('events', []))

    # Return the filtered logs
    return {
        'statusCode': 200,
        'body': json.dumps(filtered_logs)
    }
