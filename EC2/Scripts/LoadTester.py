import flask
import requests
import threading
import time
import json
import random
from collections import Counter
from argparse import ArgumentParser  # Para ler argumentos da linha de comando

# --- 1. LÓGICA DA APLICAÇÃO ---
app = flask.Flask(__name__)

# Estado global compartilhado entre threads para controlar e monitorar o teste
test_state = {
    "status": "idle",  # idle, ramping, running, stopping, finished
    "params": {},
    "live_stats": {"total": 0},
    "results": [],
    "summary": {},
}
state_lock = threading.Lock()


def user_simulation(params, headers):
    """Simula o ciclo de vida de um usuário: N requisições com um intervalo entre elas."""
    for _ in range(params.get("reqs_per_user", 1)):
        with state_lock:
            # Verifica se o teste foi interrompido antes de fazer uma nova requisição
            if test_state["status"] not in ["ramping", "running"]:
                break

        # Executa a requisição
        result = worker(params["url"], params["method"],
                        headers, params["body"])

        # Adiciona o resultado à lista global de forma segura
        with state_lock:
            if test_state["status"] in ["ramping", "running"]:
                test_state["results"].append(result)

        # Calcula e aplica o intervalo (delay)
        try:
            if params.get('delay_type') == 'variable':
                delay = random.uniform(params.get(
                    'delay_min', 0.5), params.get('delay_max', 2.0))
            else:  # 'constant'
                delay = params.get('delay_constant', 1.0)
            time.sleep(delay)
        except (ValueError, KeyError):
            time.sleep(0)  # Em caso de erro, não espera


def worker(url, method, headers, body):
    """Executa uma única requisição HTTP e cronometra o tempo de resposta."""
    start_time = time.time()
    result = {"status_code": None, "duration": 0, "error": None}
    try:
        req_body = json.loads(body) if body else None
        response = requests.request(
            method, url, headers=headers, json=req_body, timeout=30)
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
        headers = {k.strip(): v.strip() for line in params.get("headers", "").strip(
        ).split("\n") if ":" in line for k, v in [line.split(":", 1)]}
    except Exception:
        headers = {}

    with state_lock:
        test_state["status"] = "ramping"
    users_to_start = params.get("users", 1)
    ramp_up_duration = params.get("ramp_up", 0)
    ramp_up_interval = ramp_up_duration / \
        users_to_start if ramp_up_duration > 0 and users_to_start > 0 else 0

    for _ in range(users_to_start):
        with state_lock:
            if test_state["status"] not in ["ramping", "running"]:
                break
        thread = threading.Thread(
            target=user_simulation, args=(params, headers))
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
        test_state["summary"] = calculate_summary(
            test_state["results"], duration)
        test_state["status"] = "finished"


def calculate_summary(results, duration):
    """Calcula as estatísticas finais do teste a partir da lista de resultados."""
    total_reqs = len(results)
    if total_reqs == 0:
        return {}

    success_times = [r["duration"]
                     for r in results if r["status_code"] and 200 <= r["status_code"] < 300]
    error_codes = [r["status_code"] for r in results if not (
        r["status_code"] and 200 <= r["status_code"] < 300)]
    error_distribution = Counter(error_codes)

    summary = {
        "total_duration": f"{duration:.2f}", "total_requests": total_reqs,
        "rps": f"{total_reqs / duration:.2f}" if duration > 0 else "0.00",
        "success_count": len(success_times), "error_count": len(error_codes),
        "error_distribution": dict(error_distribution)
    }

    if success_times:
        success_times.sort()
        summary.update({
            "avg_response_time": f"{sum(success_times) / len(success_times):.4f}",
            "min_response_time": f"{min(success_times):.4f}",
            "max_response_time": f"{max(success_times):.4f}",
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
    """Endpoint para verificação de saúde do Load Balancer."""
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
                if '.' in value:
                    params[key] = float(value)
                else:
                    params[key] = int(value)
            except (ValueError, TypeError):
                params[key] = value

        test_state["params"] = params
        test_state.update({"status": "idle", "results": [],
                          "summary": {}, "live_stats": {"total": 0}})
        threading.Thread(target=run_load_test, args=(
            test_state["params"],)).start()
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
            success_count = sum(
                1 for r in test_state["results"] if r["status_code"] and 200 <= r["status_code"] < 300)
            live_stats = {"success": success_count,
                          "errors": total_reqs - success_count, "total": total_reqs}
        test_state["live_stats"] = live_stats
        return flask.jsonify(test_state)


# --- 3. TEMPLATE HTML (INTERFACE) ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <title>Ferramenta de Teste de Carga</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 900px; margin: auto; padding: 20px; background-color: #f8f9fa; color: #343a40; }
        .container { background: white; padding: 25px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); }
        h1, h2 { color: #003049; }
        label { display: block; margin-bottom: 5px; font-weight: 600; }
        input, select, textarea { width: 100%; padding: 10px; margin-bottom: 15px; border: 1px solid #ced4da; border-radius: 4px; box-sizing: border-box; }
        textarea { font-family: monospace; height: 100px; }
        .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
        .btn { padding: 12px 20px; border: none; border-radius: 5px; cursor: pointer; color: white; font-size: 16px; font-weight: bold; }
        .btn-start { background-color: #007bff; } .btn-stop { background-color: #dc3545; }
        .btn:disabled { background-color: #6c757d; cursor: not-allowed; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #dee2e6; }
        .live-stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; margin-bottom: 20px; }
        .stat-box { padding: 15px; border-radius: 5px; text-align: center; }
        .stat-success { background-color: #d4edda; color: #155724; }
        .stat-error { background-color: #f8d7da; color: #721c24; }
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
            <div id="variable-delay-div" style="display:none;"><div class="grid-3" style="gap:10px;"><div><label>Min (s)</label><input type="number" name="delay_min" value="0.5"></div><div><label>Max (s)</label><input type="number" name="delay_max" value="2.0"></div></div></div>
            <label for="method">Método HTTP</label><select id="method" name="method"><option value="GET">GET</option><option value="POST">POST</option><option value="PUT">PUT</option></select>
            <div id="post-put-options" style="display:none;"><label>Cabeçalhos</label><textarea name="headers" placeholder="Content-Type: application/json"></textarea><label>Corpo (JSON)</label><textarea name="body" placeholder='{"key": "value"}'></textarea></div>
            <button id="start-btn" type="submit" class="btn btn-start">Iniciar Teste</button>
            <button id="stop-btn" type="button" class="btn btn-stop" style="display:none;">Parar Teste</button>
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
    <div id="summary-container" class="container" style="display:none;">
        <h2>Resumo Final do Teste</h2>
        <table id="summary-table"></table>
    </div>
<script>
    const startBtn = document.getElementById('start-btn'), stopBtn = document.getElementById('stop-btn'), testForm = document.getElementById('test-form');
    const resultsContainer = document.getElementById('results-container'), summaryContainer = document.getElementById('summary-container');
    const statusText = document.getElementById('status-text'), progressText = document.getElementById('progress-text');
    const liveSuccessCount = document.getElementById('live-success-count'), liveErrorCount = document.getElementById('live-error-count');
    const summaryTable = document.getElementById('summary-table');
    let statusInterval;
    document.getElementById('delay_type').addEventListener('change', e => {
        document.getElementById('constant-delay-div').style.display = e.target.value === 'constant' ? 'block' : 'none';
        document.getElementById('variable-delay-div').style.display = e.target.value === 'variable' ? 'block' : 'none';
    });
    document.getElementById('method').addEventListener('change', e => {
        document.getElementById('post-put-options').style.display = ['POST', 'PUT'].includes(e.target.value) ? 'block' : 'none';
    });
    document.getElementById('delay_type').dispatchEvent(new Event('change'));
    stopBtn.addEventListener('click', () => fetch('/stop_test', { method: 'POST' }));
    testForm.addEventListener('submit', (e) => {
        e.preventDefault();
        fetch('/start_test', { method: 'POST', body: new FormData(testForm) }).then(res => res.ok && startMonitoring());
    });
    function startMonitoring() {
        startBtn.disabled = true; stopBtn.style.display = 'inline-block';
        resultsContainer.style.display = 'block'; summaryContainer.style.display = 'none';
        summaryTable.innerHTML = '';
        statusInterval = setInterval(updateStatus, 1000);
    }
    function updateStatus() {
        fetch('/get_status').then(res => res.json()).then(data => {
            statusText.textContent = data.status.charAt(0).toUpperCase() + data.status.slice(1);
            const target = (data.params.users || 0) * (data.params.reqs_per_user || 0);
            progressText.textContent = `${data.live_stats.total || 0} / ${target}`;
            liveSuccessCount.textContent = data.live_stats.success || 0;
            liveErrorCount.textContent = data.live_stats.errors || 0;
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
        let html = `
            <tr><td>Duração Total</td><td>${summary.total_duration}s</td></tr>
            <tr><td>Total de Requisições</td><td>${summary.total_requests}</td></tr>
            <tr><td>RPS (Média)</td><td>${summary.rps}</td></tr>
            <tr><td style="color:green;">Sucessos</td><td style="color:green;">${summary.success_count}</td></tr>
            <tr><td style="color:red;">Erros</td><td style="color:red;">${summary.error_count}</td></tr>
            <tr><td colspan="2" style="background-color:#f2f2f2;"><strong>Estatísticas de Resposta (sucessos)</strong></td></tr>
            <tr><td>Tempo Médio</td><td>${summary.avg_response_time || 'N/A'}s</td></tr>
            <tr><td>Tempo Mínimo</td><td>${summary.min_response_time || 'N/A'}s</td></tr>
            <tr><td>Tempo Máximo</td><td>${summary.max_response_time || 'N/A'}s</td></tr>
            <tr><td>Mediana (p50)</td><td>${summary.p50_median || 'N/A'}s</td></tr>
            <tr><td>Percentil 95 (p95)</td><td>${summary.p95 || 'N/A'}s</td></tr>
        `;
        summaryTable.innerHTML = html;
    }
</script>
</body>
</html>
"""

# --- 4. BLOCO DE EXECUÇÃO PRINCIPAL ---
if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1',
                        help='Host a ser vinculado (ex: 0.0.0.0)')
    parser.add_argument('--port', default=5000, type=int,
                        help='Porta para escutar')
    args = parser.parse_args()

    # Inicia a aplicação Flask com os argumentos da linha de comando
    # debug=False é recomendado para ambientes de produção/automatizados
    app.run(host=args.host, port=args.port, debug=False)
