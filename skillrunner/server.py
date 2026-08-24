from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, shlex, signal, sys

HOST = "0.0.0.0"
PORT = 8080
INFRA_DIR = os.environ.get("INFRA_DIR", "/infra")
PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/projects")


class RunHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # quiet — logs go to script stdout/stderr

    def _json(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"status": "ok", "infra_dir": INFRA_DIR, "projects_dir": PROJECTS_DIR})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run":
            return self._json(404, {"error": "not found. Use POST /run"})

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            return self._json(400, {"error": f"bad request: {e}"})

        script = body.get("script", "")
        args = body.get("args", [])
        cwd = body.get("cwd", PROJECTS_DIR)
        timeout = body.get("timeout", 60)

        if not script or not script.startswith("/"):
            return self._json(400, {"error": "script must be an absolute path"})

        full_path = script
        if not os.path.isfile(full_path):
            return self._json(404, {"error": f"script not found: {full_path}"})

        cmd = [full_path] + args

        try:
            result = subprocess.run(
                cmd,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()