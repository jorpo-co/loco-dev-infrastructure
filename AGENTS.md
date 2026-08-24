# Agents & Skills

AI agents (pi) interact with the Loco Infra stack via **three installable skills** and the
**skillrunner API server** (`loco-skillrunner`, port 9999), which runs inside the stack and
provides all tooling (docker CLI, kind, kubectl).

## Installation

```bash
cd ~/Projects/_infra && just install-skills
```

Symlinks `skills/loco-{infra,project,kind}` → `~/.pi/skills/`.

## The skillrunner API

All management commands go through a single HTTP endpoint:

```
POST http://localhost:9999/run
Content-Type: application/json

{"script": "/infra/scripts/<script>.sh", "args": ["<arg1>", ...]}

→ {"exit_code": 0, "stdout": "...", "stderr": "..."}
```

The container mounts:

| Mount | Inside container | Purpose |
|---|---|---|
| `~/Projects/_infra` → | `/infra` | Scripts, templates, Traefik configs, port state |
| `~/Projects/` → | `/projects` | All user projects (read/write) |
| Docker socket → | `/var/run/docker.sock` | Control host Docker |

## Skills

### loco-infra — Infrastructure lifecycle

```bash
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/infra.sh","args":["up"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/infra.sh","args":["status"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/infra.sh","args":["down"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/infra.sh","args":["logs"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/registry.sh","args":["list"]}'
```

DNS is host-only (needs sudo + brew): use `just dns-install` from `_infra/`.

### loco-project — Scaffold projects

Agent resolves project directory from user prompt, then:

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/jorpo/myapp","compose","3000"]}'

curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/sites/blog","site","80"]}'

curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/jorpo/mycluster","kind"]}'
```

### loco-kind — Kind cluster management

```bash
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/kind.sh","args":["create","mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/kind.sh","args":["delete","mycluster"]}'
curl -s -X POST http://localhost:9999/run -d '{"script":"/infra/scripts/kind.sh","args":["list"]}'
```

Ports auto-allocated (30080+N), Traefik config written to `/infra/etc/traefik/services/`.

## Troubleshooting

| Problem | First action |
|---|---|
| Skillrunner not responding | `curl -s http://localhost:9999/health` |
| DNS not resolving | `cd ~/Projects/_infra && just dns-status` |
| Traefik not routing | Check http://traefik.jorpo.loco dashboard |
| Kind cluster issues | `curl ... -d '{"script":"/usr/local/bin/kind","args":["get","clusters"]}'` |
| General health | `curl ... -d '{"script":"/usr/bin/docker","args":["ps","--filter","network=loco"]}'` |

## Full reference

`README.md` in this directory for architecture, templates, registry, and bootstrap.
