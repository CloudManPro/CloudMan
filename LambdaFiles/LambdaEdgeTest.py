import json


def lambda_handler(event, context):
    # Obtém o nome da função Lambda do contexto e converte para minúsculas
    function_name = context.function_name.lower()

    # Determina o tipo de evento e contexto com base no nome da função
    event_type = 'response' if 'response' in function_name else 'request'
    context_type = 'viewer' if 'viewer' in function_name else 'origin'

    # Define a chave correta com base nos tipos identificados
    record_key = event_type  # Será 'request' ou 'response' conforme determinado acima

    try:
        record = event['Records'][0]['cf'][record_key]
    except KeyError as e:
        print(f"Erro ao acessar '{record_key}': {e}")
        # Retorne um erro HTTP ou alguma resposta padrão
        return {
            'status': '500',
            'statusDescription': 'Internal Server Error',
            'headers': {
                'content-type': [{
                    'key': 'content-type',
                    'value': 'text/plain'
                }]
            },
            'body': f'Erro interno: {record_key} não encontrado no evento.'
        }

    print(f"{record_key}:", record)

    # Define um nome de cookie e cabeçalho distinto para cada combinação de evento e contexto
    # Ex: 'viewer-request'
    cookie_name = f'{context_type}-{event_type}'.lower()

    # Define o valor do cookie
    new_cookie = f'{cookie_name}=active; Path=/; Secure'

    # Adiciona o cabeçalho Set-Cookie ao request ou response
    if 'headers' not in record:
        record['headers'] = {}

    # Manipular os cookies existentes e adicionar o novo cookie
    if 'cookie' in record['headers']:
        # Concatena o novo cookie à string existente com ponto e vírgula
        existing_cookies = record['headers']['cookie'][0]['value']
        record['headers']['cookie'][0]['value'] = f'{existing_cookies}; {new_cookie}'
    else:
        # Se não existem cookies, inicializa com o novo cookie
        record['headers']['cookie'] = [{'key': 'Cookie', 'value': new_cookie}]

    # Retorna o record atualizado com os novos cabeçalhos
    return record
