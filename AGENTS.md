# Agents & Skills

AI agents (pi) interact with the Loco Infra stack via **three installable skills** and the
**skillrunner API server** (`loco-skillrunner`, port 9999), which runs inside the stack.

## Installation

```bash
cd ~/Projects/_infra && just setup
```

Symlinks `skills/loco-{infra,project,kind}` → `~/.pi/skills/`, installs DNS, pulls images.

## The skillrunner API

```
POST http://localhost:9999/run
Content-Type: application/json

# Recipe mode (preferred — runs just recipes):
{"recipe": "<recipe-name>", "args": ["<arg1>", ...]}

# Script mode (for arbitrary commands):
{"script": "/infra/scripts/<script>.sh", "args": ["<arg1>", ...]}

→ {"exit_code": 0, "stdout": "...", "stderr": "..."}
```

Container mounts: `/infra` ← `~/Projects/_infra`, `/projects` ← `~/Projects/`.

## Skills

### loco-infra — Infrastructure lifecycle

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"up"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"down"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"status"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"doctor"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"registry-list"}'
```

DNS is host-only (needs sudo + brew): `cd ~/Projects/_infra && just status` (or `scripts/dns.sh status`).

### loco-project — Register projects with Traefik

Writes a Traefik file provider config to `etc/traefik/services/<name>.yml` (no loco.compose.yaml).
All types use the file provider — no Docker labels.

Three SSL modes are available:
- **HTTP only** (no SSL): `scaffold-http-only`
- **SSL terminate** (Traefik handles HTTPS, forwards HTTP to backend): `scaffold-terminate`
- **SSL passthrough** (TLS forwarded directly to backend, for kind clusters): `scaffold-passthrough`

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-http-only","args":["myapp","3000"]}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-terminate","args":["blog","80"]}'
```

The agent resolves the project directory from the user's prompt and ensures CWD is set
appropriately for category inference.

### loco-kind — Kind cluster management

Kind clusters also use the Traefik file provider, but route via `host.docker.internal`
(since they're on a separate bridge network, not `loco`).

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-kind","args":["mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-create","args":["mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-import","args":["mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-delete","args":["mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-list"}'
```

`scaffold-kind` generates `kind-config.yaml` for a new cluster project. Ports are placeholders — allocated at creation time.

`kind-import` registers an **existing** cluster (created manually or by other tools) with
the infra Traefik router — allocates ports, writes config, configures containerd mirror.

## Troubleshooting

| Problem | First action |
|---|---|
| Skillrunner not responding | `curl -s http://localhost:9999/health` |
| DNS not resolving | `cd ~/Projects/_infra && just status` (or `scripts/dns.sh status`) |
| Traefik not routing | Check http://traefik.loco dashboard |
| Kind cluster issues | `{"recipe":"kind-list"}` or `{"script":"/usr/local/bin/kind","args":["get","clusters"]}` |

## Full reference

`README.md` in _infra for architecture, templates, registry, and bootstrap.