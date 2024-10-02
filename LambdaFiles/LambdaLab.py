import json
from my_math_functions import multiply


def lambda_handler(event, context):
    # Importing the function from the Lambda Layer
    print("Event:", event)

    # Parsing query parameters
    params = event.get('queryStringParameters', {})
    if not params or 'num1' not in params or 'num2' not in params:
        return {
            'statusCode': 400,
            'body': json.dumps('Parameters num1 and num2 are required')
        }

    try:
        # Converting parameters to integers
        num1 = int(params['num1'])
        num2 = int(params['num2'])

        # Calling the multiply function from the Lambda Layer
        result = multiply(num1, num2)
        print("Result:", result)

        # Returning the result
        return {
            'statusCode': 200,
            'body': json.dumps({'result': result})
        }

    except ValueError:
        print("Error: Parameters must be integers")
        return {
            'statusCode': 400,
            'body': json.dumps('Parameters must be integers')
        }

    except Exception as e:
        print(f"Unexpected error: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps('Internal server error')
        }
