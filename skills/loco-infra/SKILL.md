---
name: loco-infra
description: "Manage the local development infrastructure stack. Starts/stops the always-on Traefik + Registry network backbone, manages wildcard DNS (*.jorpo.loco / *.loco), handles the Docker registry, and reports on what's running. Use whenever the user asks about 'the infra', 'the registry', 'traefik', network routing, local DNS, or the skillrunner container."
---

# Loco Infra

The user runs a self-contained local development stack at `~/Projects/_infra/` that provides
the always-on networking backbone for **all** their Docker Compose, Docker, and kind (K8s)
projects. A **skillrunner container** (`loco-skillrunner`) runs inside the stack and serves an
HTTP API at `http://localhost:9999` for executing management scripts.

## How commands are run

Send a POST to `http://localhost:9999/run` with JSON body:

```json
{"script": "/infra/scripts/<script>.sh", "args": ["<arg1>", "<arg2>", ...]}
```

The container has:
- `/infra` → `~/Projects/_infra` (scripts, templates, state)
- `/projects` → `~/Projects` (all project directories)
- Docker socket (can control host Docker)

## API reference

```
POST /run
  Body: {"script": "/infra/scripts/...", "args": [...], "cwd": "/projects", "timeout": 60}
  Returns: {"exit_code": 0, "stdout": "...", "stderr": "..."}

GET /health
  Returns: {"status": "ok", "infra_dir": "/infra", "projects_dir": "/projects"}
```

## Common Operations

### Start / stop the stack

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/infra.sh","args":["up"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/infra.sh","args":["down"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/infra.sh","args":["status"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/infra.sh","args":["restart"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/infra.sh","args":["logs"]}'
```

### DNS (host-only, run directly)

DNS manages macOS system state (dnsmasq, loopback alias, resolver files).
Run these directly on the host (not via the container):

```bash
cd ~/Projects/_infra && just dns-install
just dns-status
just dns-uninstall
```

### Registry

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/registry.sh","args":["list"]}'
```

### Doctor / system info

```bash
# List containers on loco-net:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/bin/docker","args":["ps","--filter","network=loco"]}'

# List kind clusters:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/local/bin/kind","args":["get","clusters"]}'
```

### Traefik dashboard

The dashboard is at http://traefik.jorpo.loco (browser — no API call needed).

## Key Paths (inside the container)

| What | Container path | Host path |
|---|---|---|
| Infra root | `/infra` | `~/Projects/_infra` |
| Compose file | `/infra/compose.yml` | `~/Projects/_infra/compose.yml` |
| Traefik config | `/infra/etc/traefik/traefik.yml` | `~/Projects/_infra/etc/traefik/traefik.yml` |
| Traefik providers | `/infra/etc/traefik/services/` | `~/Projects/_infra/etc/traefik/services/` |
| Templates | `/infra/templates/` | `~/Projects/_infra/templates/` |
| State | `/infra/var/` | `~/Projects/_infra/var/` |
| All projects | `/projects/` | `~/Projects/` |

## What NOT to do

- **Do NOT** edit `/etc/hosts` for `.loco` domains — DNS is handled by dnsmasq.
- **Do NOT** hand-edit `traefik/services/*.yml` for kind clusters —
  use the `loco-kind` skill.
- **Do NOT** hand-write compose files for new projects — use the `loco-project` skill.
- **Do NOT** change port allocations by hand — tracked in `/infra/var/port-allocations.json`.

## Diagnosing issues

1. Check the skillrunner is alive: `curl -s http://localhost:9999/health`.
2. Check containers: `curl -s -X POST ... -d '{"script":"/usr/bin/docker","args":["ps"]}'`.
3. Traefik dashboard at http://traefik.jorpo.loco.
4. DNS problems: `cd ~/Projects/_infra && just dns-status`.
5. Compose project not routing: verify it's on `loco` network with `traefik.enable=true`.
6. Kind cluster not routing: use `loco-kind` skill, check for file provider config.