def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'statusDescription': "200 OK",
        'isBase64Encoded': False,
        'headers': {
            'Content-Type': 'text/plain'
        },
        'body': 'Hello Lambda'
    }
