#!/bin/bash

# Checa se o Python 3 está instalado
if ! command -v python3 &>/dev/null; then
    echo "Python 3 não encontrado. Por favor, instale o Python 3 para continuar."
    exit 1
fi

# Define o diretório para o servidor web
DIRECTORY="web_server"
if [ ! -d "$DIRECTORY" ]; then
    mkdir "$DIRECTORY"
fi

cd "$DIRECTORY"

# Cria um script Python para obter metadados e servir uma página web
cat >server.py <<EOF
import http.server
import socketserver
from urllib.request import urlopen, Request
import json
PORT = 8080
class MyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if True: #self.path == '/':
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()

            # Tenta obter metadados da instância
            try:
                req = Request("http://169.254.169.254/metadata/instance?api-version=2021-02-01&format=json", headers={"Metadata": "true"})
                with urlopen(req, timeout=2) as response:
                    metadata = json.loads(response.read().decode())
                    
                    # Constrói a página HTML com os metadados
                    html_content = """
                    <!DOCTYPE html>
                    <html>
                    <head>
                      <title>Instance Information</title>
                    </head>
                    <body>
                      <h1>Azure VM Instance Information</h1>
                      <p>Location: {location}</p>
                      <p>Name: {name}</p>
                      <p>Offer: {offer}</p>
                      <p>Resource Group Name: {resourceGroupName}</p>
                      <p>SKU: {sku}</p>
                      <p>OS Disk Caching: {osDiskCaching}</p>
                      <p>OS Disk Create Option: {osDiskCreateOption}</p>
                      <p>Disk Size GB: {diskSizeGB}</p>
                      <p>Zone: {zone}</p>
                      <p>Private IP Address: {privateIpAddress}</p>
                      <p>Subnet Address: {subnetAddress}</p>
                      <p>Subnet Prefix: {subnetPrefix}</p>
                    </body>
                    </html>
                    """.format(
                        location=metadata['compute']['location'],
                        name=metadata['compute']['name'],
                        offer=metadata['compute']['offer'],
                        resourceGroupName=metadata['compute']['resourceGroupName'],
                        sku=metadata['compute']['sku'],
                        osDiskCaching=metadata['compute']['storageProfile']['osDisk']['caching'],
                        osDiskCreateOption=metadata['compute']['storageProfile']['osDisk']['createOption'],
                        diskSizeGB=metadata['compute']['storageProfile']['osDisk']['diskSizeGB'],
                        zone=metadata['compute']['zone'],
                        privateIpAddress=metadata['network']['interface'][0]['ipv4']['ipAddress'][0]['privateIpAddress'],
                        subnetAddress=metadata['network']['interface'][0]['ipv4']['subnet'][0]['address'],
                        subnetPrefix=metadata['network']['interface'][0]['ipv4']['subnet'][0]['prefix']
                    )
                    self.wfile.write(bytes(html_content, "utf-8"))
            except Exception as e:
                error_message = "<html><body><h1>Error</h1><p>{}</p></body></html>".format(str(e))
                self.wfile.write(bytes(error_message, "utf-8"))

Handler = MyHandler

with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print("Serving at port", PORT)
    httpd.serve_forever()

EOF

# Inicia o servidor web Python
echo "Servidor iniciando na porta 8080..."
python3 server.py
