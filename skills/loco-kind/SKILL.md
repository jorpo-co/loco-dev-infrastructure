---
name: loco-kind
description: "Create, delete, and manage kind (Kubernetes-in-Docker) clusters integrated with the user's local Traefik router at *.<cluster>.jorpo.loco. Handles deterministic port allocation (30080+ / 30443+), writes the Traefik file-provider config, configures the containerd registry mirror, and validates each step. Runs via the skillrunner HTTP API."
---

# Loco Kind

The user runs kind clusters alongside Docker Compose projects. External Traefik
(`~/Projects/_infra`) routes `*.<cluster>.jorpo.loco` traffic to the kind node's
exposed port, and the cluster's own internal ingress controller routes to pods.

The **skillrunner API** at `http://localhost:9999` provides kind, kubectl, and all
management scripts.

## How commands are run

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/kind.sh","args":["<command>","<name>"]}'
```

The container has:
- `/infra` → `~/Projects/_infra` (port allocations, Traefik configs, templates)
- `/projects` → `~/Projects` (all project directories)
- Docker socket (kind creates containers on the host)

## Architecture

```
*.<cluster>.jorpo.loco:80 → Traefik (Docker, _infra/)
  → file provider config (/infra/etc/traefik/services/<cluster>.yml)
    → http://host.docker.internal:<http_port>
      → kind node (Docker container, hostPort: <http_port>)
        → cluster's internal ingress controller (NodePort: 30080)
          → pods
```

Key points:
- External Traefik owns host ports 80/443. Kind clusters must NOT bind 80/443.
- Each kind cluster publishes a unique high port to the host (HTTP + TLS).
- Routing is via **file provider** (not Docker labels — kind runs on its own bridge network).
- The kind cluster's internal ingress controller must expose `NodePort: 30080/30443`
  (the `containerPort` in the kind config, NOT the host port).

## Port allocation (deterministic)

Ports are allocated automatically and tracked in `/infra/var/port-allocations.json`:

| Cluster | HTTP host port | TLS host port |
|---|---|---|
| orc | 30080 | 30443 |
| next (first free) | 30081 | 30444 |
| next | 30082 | 30445 |

- HTTP: start at 30080, +1 per cluster.
- TLS: start at 30443, +1 per cluster.
- Ports are **freed** on delete.
- Never assign ports manually — `kind.sh` computes them.

## Creating a kind cluster

```bash
# First, scaffold the project config:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/jorpo/mycluster","kind"]}'

# Then create the cluster:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/kind.sh","args":["create","mycluster"]}'
```

The `create` command:
1. Allocates HTTP + TLS ports (stored in `/infra/var/port-allocations.json`).
2. Generates a kind config from template and creates the cluster via `kind create cluster`.
3. Writes the Traefik file provider config to `/infra/etc/traefik/services/mycluster.yml`.
4. Configures containerd mirror on all nodes for the local registry.
5. Verifies the cluster is running.

> Idempotent — if the cluster already exists, it reuses the existing port allocation.

## Deleting a kind cluster

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/kind.sh","args":["delete","mycluster"]}'
```

1. Deletes the cluster via `kind delete cluster`.
2. Removes `/infra/etc/traefik/services/mycluster.yml`.
3. Frees the ports in `/infra/var/port-allocations.json`.

## Listing clusters

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/kind.sh","args":["list"]}'

curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/kind.sh","args":["ports"]}'  # raw JSON
```

## After creating a cluster

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/local/bin/kind","args":["get","kubeconfig","--name","mycluster"]}'
```

## What happens inside the cluster (cluster's own concern, not ours)

- The kind cluster needs its own ingress controller (e.g. Traefik or nginx-ingress).
- It must expose `NodePort: 30080/30443` so host traffic can reach it.
- We route to the node, not the pods directly — the cluster's ingress handles the rest.

## Files managed by this skill

| File | Container path | Host path |
|---|---|---|
| Port allocations | `/infra/var/port-allocations.json` | `_infra/var/port-allocations.json` |
| Traefik config | `/infra/etc/traefik/services/<cluster>.yml` | `_infra/etc/traefik/services/<cluster>.yml` |
| Kind config template | `/infra/templates/kind-config.yaml` | `_infra/templates/kind-config.yaml` |
| Traefik template | `/infra/templates/kind-traefik.yml` | `_infra/templates/kind-traefik.yml` |

## Validating

```bash
# Check cluster exists:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/local/bin/kind","args":["get","clusters"]}'

# Check Traefik config:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/bin/ls","args":["/infra/etc/traefik/services/"]}'

# Check port allocation:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/bin/cat","args":["/infra/var/port-allocations.json"]}'

# Test routing (replace <cluster> and <service>):
curl -H "Host: <service>.<cluster>.jorpo.loco" http://10.254.254.254/
```

## Golden Rules

- **Do NOT** hand-edit `/infra/etc/traefik/services/*.yml` — use `kind.sh`.
- **Do NOT** manually reserve ports — allocation is automatic and tracked.
- **Do NOT** have the kind node bind host ports 80/443 — conflicts with external Traefik.
- **Do NOT** mount `loco` network config into the cluster — kind uses its own bridge network.