---
name: loco-kind
description: "Create, delete, import, and manage kind (Kubernetes-in-Docker) clusters integrated with the user's local Traefik router at *.<cluster>.loco. Handles deterministic port allocation (30080+ / 30443+), writes the Traefik file-provider config, configures the containerd registry mirror, and validates each step. The import command registers an existing cluster without creating it. Runs via the skillrunner HTTP API at localhost:9999."
---

# Loco Kind

Kind clusters use the **Traefik file provider** for routing, routing via `host.docker.internal`
(since they run on a separate bridge network, not `loco`). The **skillrunner API** at
`http://localhost:9999` provides kind, kubectl, and all management commands.

## How commands are run

```bash
# Create a cluster (allocates ports, creates cluster, registers Traefik route, configures mirror)
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-create","args":["<name>"]}'

# Import an existing cluster (ports, mirror, Traefik route — no cluster creation)
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-import","args":["<name>"]}'

# Delete a cluster (frees ports, removes Traefik config)
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-delete","args":["<name>"]}'

# Info
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-list"}'
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-ports"}'

# Scaffold kind-config.yaml for a new project
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-kind","args":["<name>"]}'
```

## Cluster lifecycle

### 1. Scaffold (optional)
Generates `kind-config.yaml` at the inferred project path with placeholder ports:
```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"scaffold-kind","args":["mycluster"]}'
```

### 2. Create (one-step: cluster + routing)
```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-create","args":["mycluster"]}'
```
This single command:
- Allocates HTTP/TLS ports
- Creates the kind cluster
- Writes the Traefik file provider config to `/infra/etc/traefik/configs/mycluster.yml`
- Configures the containerd registry mirror

### Import (for existing clusters)
```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-import","args":["mycluster"]}'
```
Same as create but does **not** create the cluster — registers an existing one.

### Delete
```bash
curl -s -X POST http://localhost:9999/run -d '{"recipe":"kind-delete","args":["mycluster"]}'
```
Deletes cluster, removes Traefik config, frees ports.

## Port allocation

HTTP: 30080+N, TLS: 30443+N. Ports freed on delete. Never assign manually.

| Cluster | HTTP | TLS | Domain |
|---|---|---|---|
| orc | 30080 | 30443 | `*.orc.loco` |
| next | 30081 | 30444 | `*.next.loco` |

## After creating or importing

```bash
# Get kubeconfig:
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/local/bin/kind","args":["get","kubeconfig","--name","mycluster"]}'

# Test routing (needs in-cluster ingress):
curl -H "Host: myservice.mycluster.loco" http://10.254.254.254/
```

## Important notes

- **External Traefik owns host ports 80/443** — kind clusters must NOT bind them.
- **Inside the cluster** needs its own ingress controller (Traefik or nginx-ingress) with `NodePort: 30080/30443` (the containerPort, NOT hostPort).
- **Do NOT** hand-edit `/infra/etc/traefik/configs/*.yml` — use `kind-create`/`kind-import`.
- **Do NOT** manually reserve ports — allocation is automatic and tracked.
- **Do NOT** mount `loco` network into the cluster — kind uses its own bridge.