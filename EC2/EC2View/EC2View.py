import boto3
from flask import Flask, render_template_string, request

app = Flask(__name__)

# Lista de recursos da AWS para seleção
aws_resources = [
    {'type': 'S3', 'name': 'bucket1'},
    {'type': 'S3', 'name': 'bucket2'},
    {'type': 'EFS', 'mount_point': '/mnt/efs1'},
    {'type': 'DynamoDB', 'table_name': 'Tabela1'},
    # Adicione outros recursos aqui
]

# Função para listar arquivos de um bucket S3
def list_s3_files(bucket_name):
    s3 = boto3.client('s3')
    contents = []
    try:
        for item in s3.list_objects(Bucket=bucket_name)['Contents']:
            contents.append(item['Key'])
    except Exception as e:
        contents.append(str(e))
    return contents

# Função para listar arquivos de um EFS
def list_efs_files(mount_point):
    try:
        files = os.listdir(mount_point)
    except Exception as e:
        files = [str(e)]
    return files

# Função para listar itens de uma tabela DynamoDB
def list_dynamodb_items(table_name):
    dynamodb = boto3.client('dynamodb')
    items = []
    try:
        response = dynamodb.scan(
            TableName=table_name,
            FilterExpression='attribute_exists(ID)'
        )
        for item in response.get('Items', []):
            items.append(item)
    except Exception as e:
        items.append(str(e))
    return items

@app.route('/', methods=['GET', 'POST'])
def index():
    selected_resource = None
    data = []

    if request.method == 'POST':
        resource_type = request.form.get('resource_type')
        resource_name = request.form.get('resource_name')
        
        if resource_type == 'S3':
            selected_resource = resource_name
            data = list_s3_files(selected_resource)
        elif resource_type == 'EFS':
            selected_resource = resource_name
            data = list_efs_files(selected_resource)
        elif resource_type == 'DynamoDB':
            selected_resource = resource_name
            data = list_dynamodb_items(selected_resource)

    return render_template_string('''
    <h1>Selecionar Recurso AWS</h1>
    <form method="post">
        <label for="resource">Escolha um recurso:</label>
        <select name="resource_type" id="resource_type">
            {% for resource in aws_resources %}
                <option value="{{ resource.type }}">{{ resource.type }}</option>
            {% endfor %}
        </select>
        <select name="resource_name" id="resource_name">
            {% for resource in aws_resources %}
                <option value="{{ resource.name }}">{{ resource.name }}</option>
            {% endfor %}
        </select>
        <input type="submit" value="Listar">
    </form>

    {% if selected_resource %}
        <h2>Dados em {{ selected_resource }}:</h2>
        <ul>
            {% for item in data %}
                <li>{{ item }}</li>
            {% endfor %}
        </ul>
    {% endif %}
    ''', aws_resources=aws_resources, selected_resource=selected_resource, data=data)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
