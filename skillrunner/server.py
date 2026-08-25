from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, signal, sys

HOST = "0.0.0.0"
PORT = 8080
INFRA_DIR = os.environ.get("INFRA_DIR", "/infra")
PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/projects")


class RunHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _json(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {
                "status": "ok",
                "infra_dir": INFRA_DIR,
                "projects_dir": PROJECTS_DIR,
                "tools": {"docker": True, "kind": True, "kubectl": True, "just": True},
            })
        self._json(404, {"error": "not found. Use POST /run or GET /health"})

    def do_POST(self):
        if self.path != "/run":
            return self._json(404, {"error": "not found. Use POST /run"})

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            return self._json(400, {"error": f"bad request: {e}"})

        cwd = body.get("cwd", PROJECTS_DIR)
        timeout = body.get("timeout", 120)

        # ── recipe mode: just <recipe> [args...] ──
        if "recipe" in body:
            recipe = body["recipe"]
            recipe_args = body.get("args", [])
            cmd = ["just", "--justfile", f"{INFRA_DIR}/justfile", "--working-directory", INFRA_DIR, recipe] + recipe_args

        # ── script mode: /path/to/script <args...> ──
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
    print(f"  Recipes: POST /run  {{\"recipe\": \"...\", \"args\": [...]}}", flush=True)
    print(f"  Scripts: POST /run  {{\"script\": \"/infra/scripts/...\", \"args\": [...]}}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()