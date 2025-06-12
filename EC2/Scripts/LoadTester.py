#version 2.o.o
import flask
import requests
import threading
import time
import json
import random
from collections import Counter
from argparse import ArgumentParser

# --- 1. LÓGICA DA APLICAÇÃO ---
app = flask.Flask(__name__)

# ### MODIFICADO ### - Estado global estendido para incluir dados para os gráficos
test_state = {
    "status": "idle",  # idle, ramping, running, stopping, finished
    "params": {},
    "live_stats": {"total": 0},
    "results": [],
    "summary": {},
    "time_series_data": [],  # NOVO: Para dados de gráficos ao longo do tempo
}
state_lock = threading.Lock()


# ### NOVO ### - Função para agregar dados em tempo real para os gráficos
def data_aggregator():
    """
    Thread em background que agrega os resultados a cada 10 segundos
    enquanto um teste está em execução.
    """
    last_processed_index = 0
    while True:
        time.sleep(10)  # Agrega a cada 10 segundos
        with state_lock:
            # Só executa se o teste estiver ativo
            if test_state["status"] not in ["ramping", "running"]:
                last_processed_index = 0  # Reseta para o próximo teste
                test_state["time_series_data"] = []
                continue

            current_results_count = len(test_state["results"])
            # Pega apenas os resultados novos desde a última agregação
            new_results = test_state["results"][last_processed_index:]
            last_processed_index = current_results_count

            if not new_results:
                continue

            # Calcula estatísticas para este intervalo de 10 segundos
            interval_duration = 10  # Aproximadamente
            rps = len(new_results) / interval_duration
            success_times = [r["duration"] for r in new_results if r["status_code"] and 200 <= r["status_code"] < 300]
            
            avg_response_time = sum(success_times) / len(success_times) if success_times else 0

            # Adiciona os dados agregados à série temporal
            interval_data = {
                "timestamp": time.strftime('%H:%M:%S'),
                "rps": f"{rps:.2f}",
                "avg_response_time": f"{avg_response_time:.4f}",
            }
            test_state["time_series_data"].append(interval_data)


def user_simulation(params, headers):
    """Simula o ciclo de vida de um usuário: N requisições com um intervalo entre elas."""
    for _ in range(params.get("reqs_per_user", 1)):
        with state_lock:
            if test_state["status"] not in ["ramping", "running"]:
                break
        result = worker(params["url"], params["method"], headers, params["body"])
        with state_lock:
            if test_state["status"] in ["ramping", "running"]:
                test_state["results"].append(result)
        try:
            if params.get('delay_type') == 'variable':
                delay = random.uniform(params.get('delay_min', 0.5), params.get('delay_max', 2.0))
            else:
                delay = params.get('delay_constant', 1.0)
            time.sleep(delay)
        except (ValueError, KeyError):
            time.sleep(0)


def worker(url, method, headers, body):
    """Executa uma única requisição HTTP e cronometra o tempo de resposta."""
    start_time = time.time()
    result = {"status_code": None, "duration": 0, "error": None}
    try:
        req_body = json.loads(body) if body else None
        response = requests.request(method, url, headers=headers, json=req_body, timeout=30)
        result["status_code"] = response.status_code
    except requests.exceptions.RequestException as e:
        result["error"] = str(e)
    except json.JSONDecodeError as e:
        result["error"] = f"JSON Body Error: {e}"
    result["duration"] = time.time() - start_time
    return result


def run_load_test(params):
    """Orquestra o teste de carga: gerencia o ramp-up e inicia as threads dos usuários."""
    threads = []
    start_time = time.time()
    with state_lock:
        test_state['start_time'] = start_time
    try:
        headers = {k.strip(): v.strip() for line in params.get("headers", "").strip().split("\n") if ":" in line for k, v in [line.split(":", 1)]}
    except Exception:
        headers = {}

    with state_lock:
        test_state["status"] = "ramping"
    users_to_start = params.get("users", 1)
    ramp_up_duration = params.get("ramp_up", 0)
    ramp_up_interval = ramp_up_duration / users_to_start if ramp_up_duration > 0 and users_to_start > 0 else 0

    for _ in range(users_to_start):
        with state_lock:
            if test_state["status"] not in ["ramping", "running"]:
                break
        thread = threading.Thread(target=user_simulation, args=(params, headers))
        threads.append(thread)
        thread.start()
        time.sleep(ramp_up_interval)

    with state_lock:
        if test_state["status"] == "ramping":
            test_state["status"] = "running"

    for thread in threads:
        thread.join()

    duration = time.time() - start_time
    with state_lock:
        test_state["summary"] = calculate_summary(test_state["results"], duration)
        test_state["status"] = "finished"


# ### NOVO ### - Função para categorizar os resultados
def categorize_result(status_code):
    """Categoriza um status_code na nossa classificação para os gráficos."""
    if status_code is None:
        return 'network_error'
    if 200 <= status_code < 300:
        return 'success'
    if status_code == 429:
        return 'rate_limit'
    if 400 <= status_code < 500:
        return 'client_error'
    if 500 <= status_code < 600:
        return 'server_error'
    return 'other_error'


def calculate_summary(results, duration):
    """Calcula as estatísticas finais do teste a partir da lista de resultados."""
    total_reqs = len(results)
    if total_reqs == 0:
        return {}

    # ### MODIFICADO ### - Usa a nova função de categorização
    categorized_counts = Counter(categorize_result(r['status_code']) for r in results)

    success_times = [r["duration"] for r in results if categorize_result(r['status_code']) == 'success']
    
    summary = {
        "total_duration": f"{duration:.2f}",
        "total_requests": total_reqs,
        "rps": f"{total_reqs / duration:.2f}" if duration > 0 else "0.00",
        # ### MODIFICADO ### - Adiciona a distribuição categorizada para o gráfico
        "categorized_distribution": {
            "success": categorized_counts.get('success', 0),
            "rate_limit": categorized_counts.get('rate_limit', 0),
            "client_error": categorized_counts.get('client_error', 0),
            "server_error": categorized_counts.get('server_error', 0),
            "network_error": categorized_counts.get('network_error', 0),
        }
    }

    if success_times:
        success_times.sort()
        summary.update({
            "avg_response_time": f"{sum(success_times) / len(success_times):.4f}",
            "min_response_time": f"{min(success_times):.4f}", "max_response_time": f"{max(success_times):.4f}",
            "p50_median": f"{success_times[int(len(success_times) * 0.50)]:.4f}",
            "p95": f"{success_times[int(len(success_times) * 0.95)]:.4f}",
            "p99": f"{success_times[int(len(success_times) * 0.99)]:.4f}",
        })
    return summary

# --- 2. ROTAS FLASK (ENDPOINTS DA API) ---

@app.route('/')
def index():
    return flask.render_template_string(HTML_TEMPLATE)

@app.route('/healthcheck')
def health_check():
    return flask.jsonify({"status": "ok"}), 200

@app.route('/start_test', methods=['POST'])
def start_test():
    with state_lock:
        if test_state["status"] in ["ramping", "running"]:
            return flask.jsonify({"error": "Test already running"}), 409
        form_data = flask.request.form.to_dict()
        params = {}
        for key, value in form_data.items():
            try:
                if '.' in value: params[key] = float(value)
                else: params[key] = int(value)
            except (ValueError, TypeError):
                params[key] = value
        
        # ### MODIFICADO ### - Reseta o estado completamente
        test_state.update({
            "params": params, "status": "idle", "results": [], "summary": {}, 
            "live_stats": {"total": 0}, "time_series_data": []
        })
        threading.Thread(target=run_load_test, args=(test_state["params"],)).start()
    return flask.redirect(flask.url_for('index'))

@app.route('/stop_test', methods=['POST'])
def stop_test():
    with state_lock:
        if test_state["status"] in ["ramping", "running"]:
            test_state["status"] = "stopping"
    return flask.redirect(flask.url_for('index'))

@app.route('/get_status')
def get_status():
    with state_lock:
        total_reqs = len(test_state["results"])
        live_stats = {}
        if total_reqs > 0 and 'start_time' in test_state:
            categorized_counts = Counter(categorize_result(r['status_code']) for r in test_state["results"])
            live_stats = {
                "success": categorized_counts.get('success', 0),
                "errors": total_reqs - categorized_counts.get('success', 0),
                "total": total_reqs
            }
        test_state["live_stats"] = live_stats
        return flask.jsonify(test_state)


# --- 3. TEMPLATE HTML (INTERFACE) ---
# ### MODIFICADO ### - HTML_TEMPLATE atualizado com Chart.js e novos elementos
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <title>Ferramenta de Teste de Carga</title>
    <!-- ### NOVO ### - Inclusão da biblioteca Chart.js -->
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 900px; margin: auto; padding: 20px; background-color: #f8f9fa; color: #343a40; }
        .container { background: white; padding: 25px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); }
        h1, h2 { color: #003049; }
        label { display: block; margin-bottom: 5px; font-weight: 600; }
        input, select, textarea { width: 100%; padding: 10px; margin-bottom: 15px; border: 1px solid #ced4da; border-radius: 4px; box-sizing: border-box; }
        textarea { font-family: monospace; height: 100px; }
        .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
        .grid-2 { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
        .btn { padding: 12px 20px; border: none; border-radius: 5px; cursor: pointer; color: white; font-size: 16px; font-weight: bold; margin-right: 10px; }
        .btn-start { background-color: #007bff; } .btn-stop { background-color: #dc3545; }
        .btn-chart { background-color: #17a2b8; }
        .btn:disabled { background-color: #6c757d; cursor: not-allowed; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #dee2e6; }
        .live-stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; margin-bottom: 20px; }
        .stat-box { padding: 15px; border-radius: 5px; text-align: center; }
        .stat-success { background-color: #d4edda; color: #155724; }
        .stat-error { background-color: #f8d7da; color: #721c24; }
        #charts-container { padding-top: 20px; }
    </style>
</head>
<body>
    <h1>Ferramenta de Teste de Carga</h1>
    <div class="container">
        <h2>Configuração do Teste</h2>
        <form id="test-form" action="/start_test" method="post">
            <label for="url">URL de Destino</label>
            <input type="text" id="url" name="url" value="https://api.github.com/events" required>
            <div class="grid-3">
                <div><label for="users">Usuários Virtuais</label><input type="number" id="users" name="users" value="10" min="1" required></div>
                <div><label for="reqs_per_user">Requisições por Usuário</label><input type="number" id="reqs_per_user" name="reqs_per_user" value="5" min="1" required></div>
                <div><label for="ramp_up">Ramp-up (s)</label><input type="number" id="ramp_up" name="ramp_up" value="5" min="0" required></div>
            </div>
            <label for="delay_type">Tipo de Intervalo</label><select id="delay_type" name="delay_type"><option value="constant">Constante</option><option value="variable">Variável</option></select>
            <div id="constant-delay-div"><label for="delay_constant">Intervalo (s)</label><input type="number" id="delay_constant" name="delay_constant" value="1" min="0" step="0.1"></div>
            <div id="variable-delay-div" style="display:none;"><div class="grid-2" style="gap:10px;"><div><label>Min (s)</label><input type="number" name="delay_min" value="0.5"></div><div><label>Max (s)</label><input type="number" name="delay_max" value="2.0"></div></div></div>
            <label for="method">Método HTTP</label><select id="method" name="method"><option value="GET">GET</option><option value="POST">POST</option><option value="PUT">PUT</option></select>
            <div id="post-put-options" style="display:none;"><label>Cabeçalhos</label><textarea name="headers" placeholder="Content-Type: application/json"></textarea><label>Corpo (JSON)</label><textarea name="body" placeholder='{"key": "value"}'></textarea></div>
            <button id="start-btn" type="submit" class="btn btn-start">Iniciar Teste</button>
            <button id="stop-btn" type="button" class="btn btn-stop" style="display:none;">Parar Teste</button>
            <!-- ### NOVO ### - Botão para exibir/ocultar gráficos -->
            <button id="toggle-charts-btn" type="button" class="btn btn-chart" style="display:none;">Exibir Gráficos</button>
        </form>
    </div>
    <div id="results-container" class="container" style="display:none;">
        <h2>Resultados em Tempo Real</h2>
        <p><strong>Status:</strong> <span id="status-text"></span> | <strong>Progresso:</strong> <span id="progress-text">0 / 0</span></p>
        <div class="live-stats-grid">
            <div class="stat-box stat-success"><strong>Sucessos:</strong> <span id="live-success-count">0</span></div>
            <div class="stat-box stat-error"><strong>Erros:</strong> <span id="live-error-count">0</span></div>
        </div>
    </div>
    <!-- ### NOVO ### - Container para todos os gráficos -->
    <div id="charts-container" class="container" style="display:none;">
        <h2>Gráficos de Performance</h2>
        <div class="grid-2">
             <div><h3>Distribuição de Respostas (Final)</h3><canvas id="summary-chart"></canvas></div>
             <div><h3>Requisições por Segundo (RPS)</h3><canvas id="rps-chart"></canvas></div>
        </div>
         <h3 style="margin-top: 25px;">Tempo de Resposta Médio (Sucessos)</h3>
         <canvas id="response-time-chart"></canvas>
    </div>
    <div id="summary-container" class="container" style="display:none;">
        <h2>Resumo Final do Teste</h2>
        <table id="summary-table"></table>
    </div>
<script>
    // ### MODIFICADO ### - Script atualizado para gerenciar e renderizar os gráficos
    const startBtn = document.getElementById('start-btn'), stopBtn = document.getElementById('stop-btn'), toggleChartsBtn = document.getElementById('toggle-charts-btn'), testForm = document.getElementById('test-form');
    const resultsContainer = document.getElementById('results-container'), summaryContainer = document.getElementById('summary-container'), chartsContainer = document.getElementById('charts-container');
    const statusText = document.getElementById('status-text'), progressText = document.getElementById('progress-text');
    const liveSuccessCount = document.getElementById('live-success-count'), liveErrorCount = document.getElementById('live-error-count');
    const summaryTable = document.getElementById('summary-table');
    let statusInterval, summaryChart, rpsChart, responseTimeChart;
    
    // Configurações dos gráficos
    const chartConfigs = {
        colors: { success: 'rgba(40, 167, 69, 0.8)', rate_limit: 'rgba(108, 92, 231, 0.8)', client_error: 'rgba(255, 193, 7, 0.8)', server_error: 'rgba(220, 53, 69, 0.8)', network_error: 'rgba(108, 117, 125, 0.8)' },
        labels: { success: 'Sucesso (2xx)', rate_limit: 'Rate Limit (429)', client_error: 'Erro Cliente (4xx)', server_error: 'Erro Servidor (5xx)', network_error: 'Erro Rede/Timeout' }
    };

    document.getElementById('delay_type').addEventListener('change', e => {
        document.getElementById('constant-delay-div').style.display = e.target.value === 'constant' ? 'block' : 'none';
        document.getElementById('variable-delay-div').style.display = e.target.value === 'variable' ? 'block' : 'none';
    });
    document.getElementById('method').addEventListener('change', e => {
        document.getElementById('post-put-options').style.display = ['POST', 'PUT'].includes(e.target.value) ? 'block' : 'none';
    });
    document.getElementById('delay_type').dispatchEvent(new Event('change'));
    stopBtn.addEventListener('click', () => fetch('/stop_test', { method: 'POST' }));
    toggleChartsBtn.addEventListener('click', () => {
        const isHidden = chartsContainer.style.display === 'none';
        chartsContainer.style.display = isHidden ? 'block' : 'none';
        toggleChartsBtn.textContent = isHidden ? 'Ocultar Gráficos' : 'Exibir Gráficos';
    });
    testForm.addEventListener('submit', (e) => {
        e.preventDefault();
        fetch('/start_test', { method: 'POST', body: new FormData(testForm) }).then(res => res.ok && startMonitoring());
    });
    
    function startMonitoring() {
        startBtn.disabled = true; stopBtn.style.display = 'inline-block'; toggleChartsBtn.style.display = 'inline-block';
        resultsContainer.style.display = 'block'; summaryContainer.style.display = 'none';
        chartsContainer.style.display = 'none'; toggleChartsBtn.textContent = 'Exibir Gráficos';
        summaryTable.innerHTML = '';
        initializeCharts();
        statusInterval = setInterval(updateStatus, 5000); // Atualiza status e gráficos a cada 5s
    }

    function initializeCharts() {
        // Destrói gráficos antigos se existirem, para evitar bugs
        if(summaryChart) summaryChart.destroy();
        if(rpsChart) rpsChart.destroy();
        if(responseTimeChart) responseTimeChart.destroy();

        // Gráfico de Resumo Final (Pizza)
        summaryChart = new Chart(document.getElementById('summary-chart'), {
            type: 'doughnut',
            data: {
                labels: Object.values(chartConfigs.labels),
                datasets: [{
                    data: [0, 0, 0, 0, 0], // Inicia zerado
                    backgroundColor: Object.values(chartConfigs.colors),
                }]
            },
            options: { responsive: true, maintainAspectRatio: true }
        });

        // Gráfico de RPS (Linha)
        rpsChart = new Chart(document.getElementById('rps-chart'), {
            type: 'line',
            data: { labels: [], datasets: [{ label: 'RPS', data: [], borderColor: '#007bff', tension: 0.1 }] },
            options: { scales: { y: { beginAtZero: true, title: { display: true, text: 'Reqs/seg' } }, x: { title: { display: true, text: 'Tempo' } } }, animation: false }
        });

        // Gráfico de Tempo de Resposta (Linha)
        responseTimeChart = new Chart(document.getElementById('response-time-chart'), {
            type: 'line',
            data: { labels: [], datasets: [{ label: 'Tempo Médio (s)', data: [], borderColor: '#28a745', tension: 0.1 }] },
            options: { scales: { y: { beginAtZero: true, title: { display: true, text: 'Segundos' } }, x: { title: { display: true, text: 'Tempo' } } }, animation: false }
        });
    }

    function updateStatus() {
        fetch('/get_status').then(res => res.json()).then(data => {
            statusText.textContent = data.status.charAt(0).toUpperCase() + data.status.slice(1);
            const target = (data.params.users || 0) * (data.params.reqs_per_user || 0);
            progressText.textContent = `${data.live_stats.total || 0} / ${target}`;
            liveSuccessCount.textContent = data.live_stats.success || 0;
            liveErrorCount.textContent = data.live_stats.errors || 0;

            // Atualiza os gráficos em tempo real
            if (data.time_series_data) {
                const labels = data.time_series_data.map(d => d.timestamp);
                rpsChart.data.labels = labels;
                responseTimeChart.data.labels = labels;
                rpsChart.data.datasets[0].data = data.time_series_data.map(d => d.rps);
                responseTimeChart.data.datasets[0].data = data.time_series_data.map(d => d.avg_response_time);
                rpsChart.update();
                responseTimeChart.update();
            }

            if (data.status === 'finished') {
                clearInterval(statusInterval);
                startBtn.disabled = false; stopBtn.style.display = 'none';
                displaySummary(data.summary);
            }
        });
    }

    function displaySummary(summary) {
        resultsContainer.style.display = 'none';
        summaryContainer.style.display = 'block';
        if (!summary || Object.keys(summary).length === 0) {
            summaryTable.innerHTML = '<tr><td>Nenhum resultado para exibir.</td></tr>'; return;
        }

        // Preenche a tabela de resumo
        let html = `
            <tr><td>Duração Total</td><td>${summary.total_duration}s</td></tr>
            <tr><td>Total de Requisições</td><td>${summary.total_requests}</td></tr>
            <tr><td>RPS (Média)</td><td>${summary.rps}</td></tr>
            <tr><td colspan="2" style="background-color:#f2f2f2;"><strong>Estatísticas de Resposta (sucessos)</strong></td></tr>
            <tr><td>Tempo Médio</td><td>${summary.avg_response_time || 'N/A'}s</td></tr>
            <tr><td>Tempo Mínimo</td><td>${summary.min_response_time || 'N/A'}s</td></tr>
            <tr><td>Tempo Máximo</td><td>${summary.max_response_time || 'N/A'}s</td></tr>
            <tr><td>Mediana (p50)</td><td>${summary.p50_median || 'N/A'}s</td></tr>
            <tr><td>Percentil 95 (p95)</td><td>${summary.p95 || 'N/A'}s</td></tr>
        `;
        summaryTable.innerHTML = html;

        // Atualiza e exibe o gráfico final
        if (summary.categorized_distribution) {
            const dist = summary.categorized_distribution;
            summaryChart.data.datasets[0].data = [dist.success, dist.rate_limit, dist.client_error, dist.server_error, dist.network_error];
            summaryChart.update();
            chartsContainer.style.display = 'block';
            toggleChartsBtn.textContent = 'Ocultar Gráficos';
        }
    }
</script>
</body>
</html>
"""

# --- 4. BLOCO DE EXECUÇÃO PRINCIPAL ---
if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1', help='Host a ser vinculado (ex: 0.0.0.0)')
    parser.add_argument('--port', default=5000, type=int, help='Porta para escutar')
    args = parser.parse_args()

    # ### NOVO ### - Inicia a thread que agrega os dados para os gráficos
    aggregator_thread = threading.Thread(target=data_aggregator, daemon=True)
    aggregator_thread.start()

    app.run(host=args.host, port=args.port, debug=False)
