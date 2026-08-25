---
name: loco-infra
description: "Manage the local development infrastructure stack. Starts/stops the always-on Traefik + Registry + skillrunner network backbone, manages wildcard DNS (*.jorpo.loco / *.loco), handles the Docker registry, and reports on what's running. Use whenever the user asks about 'the infra', 'the registry', 'traefik', network routing, local DNS, or the skillrunner container at localhost:9999."
---

# Loco Infra

The user runs a self-contained local development stack at `~/Projects/_infra/` that provides
the always-on networking backbone for **all** their Docker Compose, Docker, and kind (K8s)
projects. A **skillrunner API server** at `http://localhost:9999` provides all tooling.

## How commands are run

Use the `recipe` API to invoke just recipes:

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"<recipe-name>","args":["<arg1>", ...]}'
```

Recipes run via `just --justfile /infra/justfile` inside the container.

Or use the `script` API for arbitrary commands:

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/<script>.sh","args":["<arg1>", ...]}'
```

## Recipe reference

| Task | Recipe | Notes |
|---|---|---|
| Start stack | `{"recipe":"up"}` | Traefik + Registry + Registry UI + skillrunner |
| Stop stack | `{"recipe":"down"}` | |
| Restart | `{"recipe":"restart"}` | |
| Status | `{"recipe":"status"}` | Container + network status |
| Logs | `{"recipe":"logs"}` | Tails compose logs |
| Registry list | `{"recipe":"registry-list"}` | |
| Registry push | `{"recipe":"registry-push","args":["myimage","latest"]}` | Tags + pushes to registry.loco |
| Registry clean | `{"recipe":"registry-clean"}` | GC info |
| Doctor | `{"recipe":"doctor"}` | Full health check |
| PS | `{"recipe":"ps"}` | All running containers + clusters |
| Environment | `{"recipe":"env"}` | Shows infra paths and config |

### DNS (host-only)

DNS manages macOS system state (dnsmasq, loopback alias, resolver files).
Run these directly on the host:

```bash
cd ~/Projects/_infra && just install   # full install: DNS + skills + images
just dns-status                        # check DNS state
```

## Key Paths (inside the container)

| What | Container path | Host path |
|---|---|---|
| Infra root | `/infra` | `~/Projects/_infra` |
| Compose file | `/infra/compose.yml` | `~/Projects/_infra/compose.yml` |
| Traefik static config | `/infra/etc/traefik/traefik.yml` | `~/Projects/_infra/etc/traefik/traefik.yml` |
| Traefik providers | `/infra/etc/traefik/services/` | `~/Projects/_infra/etc/traefik/services/` |
| Templates | `/infra/templates/` | `~/Projects/_infra/templates/` |
| Port allocations | `/infra/var/port-allocations.json` | `~/Projects/_infra/var/port-allocations.json` |
| All projects | `/projects/` | `~/Projects/` |

## Diagnosing issues

1. Check skillrunner: `curl -s http://localhost:9999/health`
2. Check infra: `curl -s -X POST http://localhost:9999/run -d '{"recipe":"doctor"}'`
3. Traefik dashboard: http://traefik.jorpo.loco
4. DNS problems: `cd ~/Projects/_infra && just dns-status`

## What NOT to do

- **Do NOT** edit `/etc/hosts` for `.loco` domains — DNS is handled by dnsmasq.
- **Do NOT** hand-edit `/infra/etc/traefik/services/*.yml` for kind clusters — use `loco-kind`.
- **Do NOT** hand-write compose networking files — use `loco-project`.
- **Do NOT** change port allocations by hand.