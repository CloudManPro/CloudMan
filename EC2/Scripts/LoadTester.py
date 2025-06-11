<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Ferramenta de Teste de Carga</title>
    <style>
        body { font-family: sans-serif; line-height: 1.6; margin: 20px; background-color: #f4f4f4; }
        .container { max-width: 600px; margin: auto; background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1, h2 { color: #333; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; }
        .form-group input { width: 95%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; }
        .button-group { display: flex; gap: 10px; }
        .btn { padding: 10px 15px; border: none; border-radius: 4px; color: #fff; cursor: pointer; font-size: 16px; }
        .btn-start { background-color: #28a745; }
        .btn-stop { background-color: #dc3545; }
        .results { margin-top: 20px; padding: 15px; border: 1px solid #ddd; border-radius: 4px; }
        #status-bar, #success-bar, #error-bar { padding: 10px; border-radius: 4px; margin-bottom: 10px; }
        #status-bar { background-color: #e9ecef; color: #495057; }
        #success-bar { background-color: #d4edda; color: #155724; }
        #error-bar { background-color: #f8d7da; color: #721c24; }
    </style>
</head>
<body>

<div class="container">
    <h1>Ferramenta de Teste de Carga</h1>
    
    <div class="configuracao">
        <h2>Configuração do Teste</h2>
        <form action="/start_test" method="post">
            <div class="form-group">
                <label for="url">URL de Destino</label>
                <input type="text" id="url" name="url" value="https://google.com" required>
            </div>
            <div class="form-group">
                <label for="users">Usuários Virtuais</label>
                <input type="number" id="users" name="users" value="10" required>
            </div>
            <div class="form-group">
                <label for="requests">Requisições por Usuário</label>
                <input type="number" id="requests" name="requests" value="5" required>
            </div>
            <div class="form-group">
                <label for="rampup">Ramp-up (s)</label>
                <input type="number" id="rampup" name="rampup" value="5" required>
            </div>
            <div class="button-group">
                <button type="submit" class="btn btn-start">Iniciar Teste</button>
        </form>
        <form action="/stop_test" method="post" style="margin: 0;">
                <button type="submit" class="btn btn-stop">Parar Teste</button>
            </div>
        </form>
    </div>

    <div class="results">
        <h2>Resultados em Tempo Real</h2>
        <div id="status-bar">Status: Ocioso</div>
        <div id="success-bar">Sucessos: 0</div>
        <div id="error-bar">Erros: 0</div>
    </div>
</div>

<script>
    function updateStatus() {
        fetch('/status')
            .then(response => response.json())
            .then(data => {
                document.getElementById('status-bar').textContent = 'Status: ' + data.status_message;
                document.getElementById('success-bar').textContent = 'Sucessos: ' + data.success;
                document.getElementById('error-bar').textContent = 'Erros: ' + data.error;
            })
            .catch(error => {
                console.error('Erro ao buscar status:', error);
                document.getElementById('status-bar').textContent = 'Status: Erro de comunicação com o servidor.';
            });
    }
    // Atualiza o status a cada 1 segundo
    setInterval(updateStatus, 1000);
    // Chama uma vez no início para carregar o estado inicial
    document.addEventListener('DOMContentLoaded', updateStatus);
</script>

</body>
</html>
