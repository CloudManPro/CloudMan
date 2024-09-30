import boto3
import json


def lambda_handler(event, context):
    print("Lambda handler iniciado.")

    # Obtendo o nome da Lambda
    lambda_name = context.function_name
    print(f"Nome da Lambda: {lambda_name}")

    # Extraindo o nome do parâmetro a partir do nome da Lambda
    try:
        parameter_name = lambda_name.split('_env_')[-1]
        print(f"Nome do parâmetro extraído: {parameter_name}")
    except IndexError:
        print("Erro: Formato do nome da Lambda não é compatível com '_env_'.")
        raise ValueError(
            "Formato do nome da Lambda não é compatível com '_env_'.")

    # Inicializando o cliente do SSM para acessar o Parameter Store
    ssm = boto3.client('ssm', region_name='us-east-1')
    print("Cliente SSM inicializado.")

    # Obtendo o valor do parâmetro bluegreen do Parameter Store
    try:
        parameter = ssm.get_parameter(Name='bluegreen', WithDecryption=True)
        parameter_value = parameter['Parameter']['Value']
        print(f"Valor do parâmetro bluegreen obtido: {parameter_value}")
        bluegreen_vars = json.loads(parameter_value)
        print(f"JSON carregado: {bluegreen_vars}")

        # Extraindo as URLs das variáveis blueurl e greenurl
        blue_url = bluegreen_vars.get('blueurl')
        green_url = bluegreen_vars.get('greenurl')
        print(f"URL Blue: {blue_url}, URL Green: {green_url}")

        # Extraindo o nome do cookie, com valor padrão CloudmanCookie se não existir
        cookie_name = bluegreen_vars.get('CloudmanCookie', 'CloudmanCookie')
        print(f"Nome do cookie: {cookie_name}")

    except Exception as e:
        print(f"Erro ao obter ou carregar o parâmetro bluegreen: {e}")
        raise ValueError(
            f"Erro ao obter ou carregar o parâmetro bluegreen: {e}")

    # Manipulação de request e response do evento CloudFront
    request = event['Records'][0]['cf']['request']
    headers = request['headers']
    print("Request inicial:", request)
    print("Headers iniciais:", headers)

    # Verifica se o cookie já existe na requisição
    cookies = headers.get('cookie', [])
    print(f"Cookies recebidos: {cookies}")
    cookie_exists = any(
        f'{cookie_name}=' in cookie['value'] for cookie in cookies)
    print(f"Cookie {cookie_name} existe nos cookies: {cookie_exists}")

    # Preparando o redirecionamento para a URL do ambiente blue
    response = {
        'status': '302',
        'statusDescription': 'Found',
        'headers': {
            'location': [{
                'key': 'Location',
                'value': blue_url  # Redireciona para a URL do blueurl
            }]
        }
    }

    # Se o cookie não existir, insere o cookie
    if not cookie_exists:
        headers['set-cookie'] = [
            {
                'key': 'Set-Cookie',
                'value': f'{cookie_name}=blue; Path=/; Secure; HttpOnly; SameSite=Lax'
            }
        ]
        print(f"Cookie {cookie_name} inserido: {headers['set-cookie']}")
        response['headers']['set-cookie'] = [{
            'key': 'Set-Cookie',
            'value': f'{cookie_name}=blue; Path=/; Secure; HttpOnly; SameSite=Lax'
        }]

    # Redireciona para a URL blueurl, independentemente de existir ou não o cookie
    print("Redirecionamento para a URL Blue:", response)
    return response
