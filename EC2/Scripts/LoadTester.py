import threading
import time
import requests
import logging
import statistics
from flask import Flask, jsonify, request, redirect, url_for

# --- 1. Configuração do Logging Detalhado ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - [%(threadName)s] - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# --- 2. Conteúdo HTML da Interface ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Ferramenta de Teste de Carga</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; line-height: 1.6; margin: 20px; background-color: #f4f7f9; color: #333; }
        .container { max-width: 650px; margin: auto; background: #fff; padding: 25px 30px; border-radius: 8px; box-shadow: 0 4px 10px rgba(0,0,0,0.05); }
        h1, h2 { color: #2c3e50; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: bold; }
        .form-group input { width: 95%; padding: 12px; border: 1px solid #ccc; border-radius: 4px; transition: border-color 0.3s; }
        .form-group input:focus { border-color: #3498db; outline: none; }
        .button-group { display: flex; gap: 10px; margin-top: 20px; }
        .btn { flex-grow: 1; padding: 12px 15px; border: none; border-radius: 4px; color: #fff; cursor: pointer; font-size: 16px; font-weight: bold; transition: background-color 0.3s, transform 0.1s; }
        .btn:disabled { background-color: #bdc3c7; cursor: not-allowed; }
        .btn:active { transform: scale(0.98); }
        .btn-start { background-color: #27ae60; } .btn-start:hover { background-color: #229954; }
        .btn-stop { background-color: #c0392b; } .btn-stop:hover { background-color: #a93226; }
        .results { margin-top: 30px; padding: 20px; border: 1px solid #e0e0e0; border-radius: 4px; background-color: #fafafa; }
        .bar { padding: 12px; border-radius: 4px; margin-bottom: 10px; font-weight: 500; }
        #status-bar { background-color: #e9ecef; color: #495057; border-left: 5px solid #6c757d; }
        #success-bar { background-color: #d4edda; color: #155724; border-left: 5px solid #28a745; }
        #error-bar { background-color: #f8d7da; color: #721c24; border-left: 5px solid #dc3545; }
        #summary-container { display: none; margin-top: 20px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid #eee; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
<div class="container">
    <h1>Ferramenta de Teste de Carga</h1>
    <div class="configuracao">
        <h2>Configuração do Teste</h2>
        <form id="start-form">
            <div class="form-group"><label for="url">URL de Destino</label><input type="text" id="url" name="url" required></div>
            <div class="form-group"><label for="users">Usuários Virtuais</label><input type="number" id="users" name="users" value="10" min="1" required></div>
            <div class="form-group"><label for="requests">Requisições por Usuário</label><input type="number" id="requests" name="requests" value="5" min="1" required></div>
            <div class="form-group"><label for="rampup">Ramp-up (s)</label><input type="number" id="rampup" name="rampup" value="5" min="0" required></div>
        </form>
        <div class="button-group">
            <button id="start-btn" class="btn btn-start">Iniciar Teste</button>
            <button id="stop-btn" class="btn btn-stop" disabled>Parar Teste</button>
        </div>
    </div>
    <div class="results">
        <h2>Resultados em Tempo Real</h2>
        <div id="status-bar" class="bar">Status: Ocioso</div>
        <div id="success-bar" class="bar">Sucessos: 0</div>
        <div id="error-bar" class="bar">Erros: 0</div>
    </div>
    <div id="summary-container" class="container">
        <h2>Resumo Final do Teste</h2>
        <table id="summary-table"></table>
    </div>
</div>
<script>
    const urlInput = document.getElementById('url');
    const startBtn = document.getElementById('start-btn');
    const stopBtn = document.getElementById('stop-btn');
    const statusBar = document.getElementById('status-bar');
    const successBar = document.getElementById('success-bar');
    const errorBar = document.getElementById('error-bar');
    const summaryContainer = document.getElementById('summary-container');
    const summaryTable = document.getElementById('summary-table');
    let statusInterval;

    // Salva a URL no localStorage para persistir entre recargas
    urlInput.addEventListener('change', (e) => localStorage.setItem('lastUrl', e.target.value));
    
    // Carrega a última URL usada ou um padrão
    document.addEventListener('DOMContentLoaded', () => {
        urlInput.value = localStorage.getItem('lastUrl') || 'https://google.com';
        updateStatus();
    });

    startBtn.addEventListener('click', () => {
        const formData = new FormData(document.getElementById('start-form'));
        fetch('/start_test', { method: 'POST', body: formData })
            .then(res => {
                if(res.ok) {
                    startMonitoring();
                } else {
                    alert('Não foi possível iniciar o teste. Verifique se outro já está em execução.');
                }
            });
    });

    stopBtn.addEventListener('click', () => {
        fetch('/stop_test', { method: 'POST' });
    });

    function startMonitoring() {
        startBtn.disabled = true;
        stopBtn.disabled = false;
        summaryContainer.style.display = 'none';
        statusInterval = setInterval(updateStatus, 1000);
    }
    
    function stopMonitoring() {
        clearInterval(statusInterval);
        startBtn.disabled = false;
        stopBtn.disabled = true;
    }

    function updateStatus() {
        fetch('/status')
            .then(response => response.json())
            .then(data => {
                statusBar.textContent = 'Status: ' + data.status_message;
                successBar.textContent = 'Sucessos: ' + data.stats.success;
                errorBar.textContent = 'Erros: ' + data.stats.error;

                if (data.status_message === 'Finalizado' || data.status_message === 'Parado') {
                    stopMonitoring();
                    if (data.summary && Object.keys(data.summary).length > 0) {
                        displaySummary(data.summary);
                    }
                } else if (data.status_message === 'Ocioso' && statusInterval) {
                     stopMonitoring();
                }
            })
            .catch(error => {
                console.error('Erro ao buscar status:', error);
                statusBar.textContent = 'Status: Erro de comunicação com o servidor.';
                stopMonitoring();
            });
    }

    function displaySummary(summary) {
        summaryContainer.style.display = 'block';
        let html = '<tbody>';
        const friendlyNames = {
            total_duration: 'Duração Total (s)', total_requests: 'Total de Requisições', rps: 'RPS (Média)',
            success_count: 'Sucessos', error_count: 'Erros', avg_time: 'Tempo Médio (s)',
            min_time: 'Tempo Mínimo (s)', max_time: 'Tempo Máximo (s)', p95_time: 'Percentil 95 (s)'
        };
        for (const key in summary) {
            html += `<tr><td>${friendlyNames[key] || key}</td><td>${summary[key]}</td></tr>`;
        }
        html += '</tbody>';
        summaryTable.innerHTML = html;
    }
</script>
</body>
</html>
"""

# --- 3. Classe Gerenciadora de Teste ---
class TestManager:
    def __init__(self):
        self._lock = threading.Lock()
        self._test_thread = None
        self._is_running = False
        self._start_time = 0
        self._stats = {}
        self._summary = {}
        self.reset()

    def reset(self):
        self._is_running = False
        self._test_thread = None
        self._start_time = 0
        self._stats = {"success": 0, "error": 0, "latencies": []}
        self._summary = {}

    def start_test(self, params):
        with self._lock:
            if self._is_running:
                logging.warning("Tentativa de iniciar um teste enquanto outro já está em execução.")
                return False
            self.reset()
            self._is_running = True
            self._start_time = time.time()
            self._test_thread = threading.Thread(target=self._worker, args=(params,), name="LoadTestWorker", daemon=True)
            self._test_thread.start()
            logging.info(f"Thread de teste '{self._test_thread.name}' iniciada com os parâmetros: {params}")
            return True

    def stop_test(self):
        with self._lock:
            if not self._is_running:
                logging.warning("Tentativa de parar um teste que não está em execução.")
                return
            logging.info("Sinal de parada enviado para o teste.")
            self._is_running = False
        
        if self._test_thread:
            self._test_thread.join(timeout=10.0)
            if self._test_thread.is_alive():
                logging.error("A THREAD DE TESTE NÃO PAROU A TEMPO!")
            else:
                logging.info("Thread de teste finalizada com sucesso após comando de parada.")
        
        self._calculate_summary("Parado")
        self._test_thread = None

    def get_status(self):
        with self._lock:
            status_message = "Ocioso"
            if self._is_running:
                progress = self._stats['success'] + self._stats['error']
                status_message = f"Em andamento... ({progress})"
            elif self._summary:
                status_message = self._summary.get("final_status", "Finalizado")
            
            return {
                "status_message": status_message,
                "stats": {"success": self._stats["success"], "error": self._stats["error"]},
                "summary": self._summary
            }

    def _calculate_summary(self, final_status="Finalizado"):
        with self._lock:
            duration = time.time() - self._start_time
            total_reqs = self._stats["success"] + self._stats["error"]
            latencies = self._stats["latencies"]
            
            summary = {
                "final_status": final_status,
                "total_duration": f"{duration:.2f}",
                "total_requests": total_reqs,
                "rps": f"{total_reqs / duration:.2f}" if duration > 0 else "0.00",
                "success_count": self._stats["success"],
                "error_count": self._stats["error"]
            }

            if latencies:
                latencies.sort()
                summary.update({
                    "avg_time": f"{statistics.mean(latencies):.4f}",
                    "min_time": f"{latencies[0]:.4f}",
                    "max_time": f"{latencies[-1]:.4f}",
                    "p95_time": f"{latencies[int(len(latencies) * 0.95)]:.4f}",
                })
            
            self._summary = summary
            logging.info(f"Resumo do teste calculado: {self._summary}")

    def _worker(self, params):
        try:
            target_url, v_users, req_per_user, ramp_up = \
                params['target_url'], params['virtual_users'], params['requests_per_user'], params['ramp_up']
            sleep_between = ramp_up / (v_users - 1) if ramp_up > 0 and v_users > 1 else 0

            for i in range(v_users):
                if not self._is_running: break
                logging.info(f"Iniciando usuário virtual {i + 1}/{v_users}")
                
                for j in range(req_per_user):
                    if not self._is_running: break
                    
                    start_req_time = time.time()
                    try:
                        requests.get(target_url, timeout=10)
                        duration = time.time() - start_req_time
                        with self._lock:
                            self._stats["success"] += 1
                            self._stats["latencies"].append(duration)
                    except requests.RequestException as e:
                        logging.warning(f"Erro na requisição para {target_url}: {e}")
                        with self._lock:
                            self._stats["error"] += 1
                
                if i < v_users - 1 and self._is_running: time.sleep(sleep_between)
        
        except Exception as e:
            logging.error(f"Erro inesperado no worker do teste: {e}", exc_info=True)
        
        finally:
            with self._lock:
                if self._is_running: # Se terminou naturalmente
                    self._is_running = False
                    self._calculate_summary()
            logging.info("Worker de teste finalizado.")

# --- 4. Configuração do Flask e Rotas ---
app = Flask(__name__)
test_manager = TestManager()

@app.route('/')
def index():
    return HTML_TEMPLATE

@app.route('/start_test', methods=['POST'])
def start_test():
    if not test_manager.start_test({
        'target_url': request.form.get('url'),
        'virtual_users': int(request.form.get('users', 10)),
        'requests_per_user': int(request.form.get('requests', 5)),
        'ramp_up': int(request.form.get('rampup', 5))
    }):
        return "Teste já em execução", 409
    return "OK", 200

@app.route('/stop_test', methods=['POST'])
def stop_test():
    test_manager.stop_test()
    return redirect(url_for('index'))

@app.route('/status')
def status():
    return jsonify(test_manager.get_status())

@app.route('/health')
def health_check():
    return "OK", 200

if __name__ == '__main__':
    logging.info("Aplicação Flask iniciando em modo de desenvolvimento.")
    app.run(host='0.0.0.0', port=5000, debug=False)
