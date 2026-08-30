from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, signal, sys

# Ensure we import projects.py from the mounted volume, not the baked-in /projects.py
sys.path.insert(0, "/infra/skillrunner")
from projects import get_parsed_projects, resolve_status, action_project

HOST = "0.0.0.0"
PORT = 8080
INFRA_DIR = os.environ.get("INFRA_DIR", "/infra")
PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/projects")


# ── HTML dashboard ──────────────────────────────────────────

HTML_DASHBOARD = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Loco Infra Dashboard</title>
<style>
  :root { --bg: #0d1117; --surface: #161b22; --border: #30363d; --text: #c9d1d9;
          --dim: #8b949e; --green: #3fb950; --red: #f85149; --amber: #d29922;
          --blue: #58a6ff; --radius: 8px; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Oxygen,
                Ubuntu,Cantarell,sans-serif; background: var(--bg); color: var(--text); }
  .container { max-width: 1100px; margin: 0 auto; padding: 24px 16px; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 24px; }
  header h1 { font-size: 22px; font-weight: 600; }
  header .badge { font-size: 12px; background: var(--surface); border: 1px solid var(--border);
                   padding: 3px 10px; border-radius: 20px; color: var(--dim); }
  #refresh-info { font-size: 12px; color: var(--dim); margin-left: auto; }
  .table-wrap { background: var(--surface); border: 1px solid var(--border);
                 border-radius: var(--radius); overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; padding: 12px 14px; font-size: 12px; font-weight: 600;
        text-transform: uppercase; letter-spacing: 0.5px; color: var(--dim);
        border-bottom: 1px solid var(--border); background: var(--surface); }
  td { padding: 10px 14px; font-size: 14px; border-bottom: 1px solid var(--border); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(88,166,255,0.04); }
  .status-dot { display: inline-flex; align-items: center; gap: 6px; }
  .status-dot::before { content: ''; width: 8px; height: 8px; border-radius: 50%;
                         flex-shrink: 0; }
  .status-running::before { background: var(--green); box-shadow: 0 0 6px var(--green); }
  .status-stopped::before { background: var(--red); }
  .status-unknown::before { background: var(--amber); }
  .badge-type { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 12px;
                 text-transform: uppercase; letter-spacing: 0.3px; }
  .type-compose { background: rgba(88,166,255,0.12); color: var(--blue); }
  .type-kind { background: rgba(210,153,34,0.12); color: var(--amber); }
  .ssl-label { font-size: 11px; padding: 2px 8px; border-radius: 12px; }
  .ssl-terminate { background: rgba(63,185,80,0.12); color: var(--green); }
  .ssl-passthrough { background: rgba(210,153,34,0.12); color: var(--amber); }
  .ssl-none { background: rgba(139,148,158,0.12); color: var(--dim); }
  .actions { display: flex; gap: 6px; }
  .btn { font-size: 12px; font-weight: 500; padding: 5px 12px; border-radius: 6px;
          border: 1px solid var(--border); cursor: pointer; background: var(--surface);
          color: var(--text); transition: all 0.15s; }
  .btn:hover { background: #21262d; }
  .btn:disabled { opacity: 0.35; cursor: not-allowed; }
  .btn-start { border-color: #238636; color: var(--green); }
  .btn-start:hover:not(:disabled) { background: #238636; color: #fff; }
  .btn-stop { border-color: #da3633; color: var(--red); }
  .btn-stop:hover:not(:disabled) { background: #da3633; color: #fff; }
  .btn-restart { border-color: var(--border); }
  .btn-restart:hover:not(:disabled) { background: #21262d; }
  .btn-build { border-color: var(--blue); color: var(--blue); }
  .btn-build:hover:not(:disabled) { background: var(--blue); color: #fff; }
  .empty { text-align: center; padding: 40px 14px; color: var(--dim); }
  .empty p { font-size: 15px; }
  .toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
            background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
            padding: 12px 20px; font-size: 14px; z-index: 100; display: none;
            box-shadow: 0 4px 12px rgba(0,0,0,0.4); max-width: 90vw; }
  .toast.show { display: block; animation: fadeIn 0.2s; }
  .toast.error { border-color: var(--red); }
  .toast.success { border-color: var(--green); }
  @keyframes fadeIn { from { opacity: 0; transform: translateX(-50%) translateY(10px); }
                       to { opacity: 1; transform: translateX(-50%) translateY(0); } }
  @media (max-width: 700px) {
    th, td { padding: 8px 10px; }
    td:nth-child(3), th:nth-child(3) { display: none; }
  }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>⚡ Loco Infra</h1>
    <span class="badge">Dashboard</span>
    <span id="refresh-info">loading...</span>
  </header>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Project</th>
          <th>Type</th>
          <th>URL</th>
          <th>Port</th>
          <th>TLS</th>
          <th>Status</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody id="projects-body">
        <tr><td colspan="7" class="empty"><p>⏳ Loading projects...</p></td></tr>
      </tbody>
    </table>
  </div>
</div>
<div id="toast" class="toast"></div>
<script>
const TBODY = document.getElementById("projects-body");
const TOAST = document.getElementById("toast");
const REFRESH = document.getElementById("refresh-info");
let toastTimer = null;
let busy = new Set();

function showToast(msg, type) {
  TOAST.textContent = msg;
  TOAST.className = "toast show " + (type || "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => TOAST.classList.remove("show"), 4000);
}

function esc(s) { const d = document.createElement("div"); d.appendChild(document.createTextNode(s)); return d.innerHTML; }

async function fetchJSON(url) {
  const r = await fetch(url);
  if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error(e.error || r.statusText); }
  return r.json();
}

async function postJSON(url) {
  const r = await fetch(url, { method: "POST" });
  if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error(e.error || r.statusText); }
  return r.json();
}

async function loadProjects() {
  try {
    const data = await fetchJSON("/api/projects");
    renderProjects(data);
    REFRESH.textContent = new Date().toLocaleTimeString();
  } catch (e) {
    TBODY.innerHTML = `<tr><td colspan="7" class="empty"><p>✗ Failed to load: ${esc(e.message)}</p></td></tr>`;
  }
}

function renderProjects(projects) {
  if (!projects || projects.length === 0) {
    TBODY.innerHTML = `<tr><td colspan="7" class="empty"><p>No registered projects. Scaffold one with &rlm;<code>just scaffold-http-only</code> or <code>just scaffold-terminate</code>.</p></td></tr>`;
    return;
  }
  TBODY.innerHTML = projects.map(p => {
    const isRunning = p.status === "running";
    const isStopped = p.status === "stopped";
    const portLabel = p.type === "kind" 
      ? esc(p.http_port + (p.tls_port ? "/" + p.tls_port : ""))
      : esc(p.http_port);
    const sslClass = p.ssl_mode === "terminate" ? "ssl-terminate" 
                     : p.ssl_mode === "passthrough" ? "ssl-passthrough" : "ssl-none";
    const sslLabel = p.ssl_mode === "passthrough" ? "passthrough"
                     : p.ssl_mode === "terminate" ? "HTTPS" : "HTTP";
    const statusClass = isRunning ? "status-running" : isStopped ? "status-stopped" : "status-unknown";
    const statusLabel = isRunning ? "Running" : isStopped ? "Stopped" : "Unknown";
    const nameEnc = esc(p.name);
    return `<tr>
      <td><strong>${nameEnc}</strong></td>
      <td><span class="badge-type type-${esc(p.type)}">${esc(p.type)}</span></td>
      <td><a href="${esc(p.url)}" target="_blank" style="color:var(--blue);text-decoration:none">${esc(p.url)}</a></td>
      <td>${portLabel}</td>
      <td><span class="ssl-label ${sslClass}">${sslLabel}</span></td>
      <td><span class="status-dot ${statusClass}">${statusLabel}</span></td>
      <td class="actions">
        <button class="btn btn-start"  data-name="${nameEnc}" data-action="start"  ${isRunning ? "disabled" : ""}>Start</button>
        <button class="btn btn-stop"   data-name="${nameEnc}" data-action="stop"  ${isStopped ? "disabled" : ""}>Stop</button>
        <button class="btn btn-restart" data-name="${nameEnc}" data-action="restart">Restart</button>
        <button class="btn btn-build" data-name="${nameEnc}" data-action="build">Build</button>
      </td>
    </tr>`;
  }).join("");
}

TBODY.addEventListener("click", async function(e) {
  const btn = e.target.closest("button[data-name]");
  if (!btn) return;
  const name = btn.dataset.name;
  const action = btn.dataset.action;
  const orig = btn.textContent;
  btn.disabled = true;
  btn.textContent = (action === "start" ? "Starting..." : action === "stop" ? "Stopping..." : "Restarting...");
  try {
    const result = await postJSON(`/api/projects/${encodeURIComponent(name)}/${action}`);
    showToast(result.message || result.output || "OK", "success");
  } catch (e) {
    showToast(`Action failed: ${e.message}`, "error");
  }
  btn.textContent = orig;
  btn.disabled = false;
  // Reload after short delay
  setTimeout(loadProjects, 1200);
});

loadProjects();
setInterval(loadProjects, 5000);
</script>
</body>
</html>"""


# ── HTTP handler ────────────────────────────────────────────

class RunHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _json(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def _html(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        # ── Dashboard UI ──
        if self.path == "/ui" or self.path == "/" or self.path == "":
            return self._html(200, HTML_DASHBOARD)

        # ── API list projects ──
        if self.path == "/api/projects":
            projects = get_parsed_projects()
            resolve_status(projects)
            return self._json(200, list(projects.values()))

        # ── Health ──
        if self.path == "/health":
            return self._json(200, {
                "status": "ok",
                "infra_dir": INFRA_DIR,
                "projects_dir": PROJECTS_DIR,
                "tools": {"docker": True, "kind": True, "kubectl": True, "just": True},
            })

        self._json(404, {"error": "not found. Use GET /ui, GET /api/projects, or POST /run"})

    def do_POST(self):
        # ── Project actions ──
        m = __import__("re").match(r"^/api/projects/([^/]+)/(start|stop|restart|build)$", self.path)
        if m:
            name, action = m.group(1), m.group(2)
            ok, msg = action_project(name, action)
            if ok:
                self._json(200, {"ok": True, "message": msg})
            else:
                self._json(200, {"ok": False, "message": msg})
            return

        # ── Run recipe/script (existing) ──
        if self.path == "/run":
            return self._handle_run()

        self._json(404, {"error": "not found. Use POST /run or POST /api/projects/<name>/<action>"})

    def _handle_run(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            return self._json(400, {"error": f"bad request: {e}"})

        cwd = body.get("cwd", PROJECTS_DIR)
        timeout = body.get("timeout", 120)

        if "recipe" in body:
            recipe = body["recipe"]
            recipe_args = body.get("args", [])
            cmd = ["just", "--justfile", f"{INFRA_DIR}/justfile", "--working-directory", INFRA_DIR, recipe] + recipe_args
        elif "script" in body:
            script = body["script"]
            script_args = body.get("args", [])
            if not script.startswith("/"):
                return self._json(400, {"error": "script must be an absolute path"})
            if not os.path.isfile(script):
                return self._json(404, {"error": f"script not found: {script}"})
            cmd = [script] + script_args
        else:
            return self._json(400, {"error": "provide either 'recipe' or 'script'"})

        try:
            result = subprocess.run(
                cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
            )
            self._json(200, {
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            })
        except subprocess.TimeoutExpired:
            self._json(408, {"error": f"timeout after {timeout}s", "cmd": cmd})
        except Exception as e:
            self._json(500, {"error": str(e), "cmd": cmd})


def main():
    server = HTTPServer((HOST, PORT), RunHandler)
    print(f"loco-skillrunner API ready — http://{HOST}:{PORT}", flush=True)
    print(f"  INFRA_DIR={INFRA_DIR}  PROJECTS_DIR={PROJECTS_DIR}", flush=True)
    print(f"  Dashboard: GET  /ui", flush=True)
    print(f"  Projects:  GET  /api/projects", flush=True)
    print(f"  Actions:   POST /api/projects/<name>/{'{start|stop|restart|build}'}", flush=True)
    print(f"  Recipes:   POST /run  {{\"recipe\": \"...\", \"args\": [...]}}", flush=True)
    print(f"  Scripts:   POST /run  {{\"script\": \"/infra/scripts/...\", \"args\": [...]}}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()