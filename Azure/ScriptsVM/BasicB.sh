#!/bin/bash

# Checa se o Python 3 está instalado
if ! command -v python3 &>/dev/null; then
    echo "Python 3 não encontrado. Por favor, instale o Python 3 para continuar."
    exit 1
fi

# Cria um diretório para o servidor web, se não existir
DIRECTORY="web_server"
if [ ! -d "$DIRECTORY" ]; then
    mkdir "$DIRECTORY"
fi

# Entra no diretório
cd "$DIRECTORY"

# Cria uma página HTML simples
cat >index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Teste de Instância</title>
</head>
<body>
    <h1>Teste de Instância</h1>
    <p>Esta é uma página de teste.</p>
</body>
</html>
EOF

# Inicia o servidor web Python na porta 8000
echo "Servidor iniciando na porta 8000..."
python3 -m http.server 80
