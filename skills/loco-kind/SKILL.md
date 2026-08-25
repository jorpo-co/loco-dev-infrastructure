---
name: loco-kind
description: "Create, delete, import, and manage kind (Kubernetes-in-Docker) clusters integrated with the user's local Traefik router at *.<cluster>.jorpo.loco. Handles deterministic port allocation (30080+ / 30443+), writes the Traefik file-provider config, configures the containerd registry mirror, and validates each step. The import command registers an existing cluster without creating it. Runs via the skillrunner HTTP API at localhost:9999."
---

# Loco Kind

The user runs kind clusters alongside Docker Compose projects. All types (compose, kind, site)
use the **Traefik file provider** for routing — no Docker labels. Compose projects use Docker DNS
on the `loco` network, while kind clusters use `host.docker.internal` because they run on a
separate bridge network.

The **skillrunner API** at `http://localhost:9999` provides kind, kubectl, and all
management commands via the `recipe` API.

## How commands are run

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"kind-create","args":["<name>"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"kind-delete","args":["<name>"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"kind-import","args":["<name>"]}'
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"kind-list"}'
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"kind-ports"}'
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"scaffold-kind","args":["<name>"]}'
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

- External Traefik owns host ports 80/443. Kind clusters must NOT bind 80/443.
- Each cluster publishes a unique high port (HTTP + TLS).
- Routing is via **file provider** (not Docker labels).

## Port allocation (deterministic)

| Cluster | HTTP | TLS | Domain |
|---|---|---|---|
| orc | 30080 | 30443 | `*.orc.jorpo.loco` |
| next | 30081 | 30444 | `*.next.jorpo.loco` |

HTTP: 30080+N, TLS: 30443+N. Ports freed on delete. Never assign manually.

## Scaffolding a kind cluster project

Before creating a cluster, scaffold the project config:

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-kind","args":["mycluster"]}'
```

Creates `kind-config.yaml` at the inferred project path with domain `*.mycluster.jorpo.loco`.
Ports are placeholders — allocated at creation time.

## Creating a kind cluster

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-create","args":["mycluster"]}'
```

Allocates ports, creates the cluster, writes Traefik config, configures containerd mirror.
Idempotent — rerun safely if cluster already exists.

## Importing an existing kind cluster

Use when the cluster already exists (created manually or by another tool):

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-import","args":["mycluster"]}'
```

This:
1. Verifies the cluster exists via `kind get clusters`
2. Allocates or reuses ports
3. Writes Traefik file provider config to `/infra/etc/traefik/services/mycluster.yml`
4. Configures containerd mirror on all nodes
5. Does **not** create the cluster

## Deleting a kind cluster

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-delete","args":["mycluster"]}'
```

Deletes cluster, removes Traefik config, frees ports.

## Listing / ports

```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-list"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-ports"}'
```

## After creating or importing

```bash
# Get kubeconfig:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/local/bin/kind","args":["get","kubeconfig","--name","mycluster"]}'

# Test routing (needs in-cluster ingress):
curl -H "Host: myservice.mycluster.jorpo.loco" http://10.254.254.254/
```

## What happens inside the cluster (cluster's own concern)

- Needs its own ingress controller (Traefik or nginx-ingress).
- Must expose `NodePort: 30080/30443` (the containerPort, NOT hostPort).
- We route to the node — the cluster's ingress handles pod routing.

## Files managed

| File | Container path | Host path |
|---|---|---|
| Port allocations | `/infra/var/port-allocations.json` | `_infra/var/port-allocations.json` |
| Traefik config | `/infra/etc/traefik/services/<cluster>.yml` | `_infra/etc/traefik/services/<cluster>.yml` |

## Golden Rules

- **Do NOT** hand-edit `/infra/etc/traefik/services/*.yml` — use `kind.sh`.
- **Do NOT** manually reserve ports — allocation is automatic and tracked.
- **Do NOT** bind host ports 80/443 from kind nodes — conflicts with Traefik.
- **Do NOT** mount `loco` network into the cluster — kind uses its own bridge.