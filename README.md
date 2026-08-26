# Loco Infra — Local Development Infrastructure

> A self-contained, deterministic local development environment for Docker Compose and kind
> (Kubernetes-in-Docker) projects. One stack to route, register, and orchestrate everything
> running on `*.loco`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Design Principles](#2-design-principles)
3. [DNS: Wildcard Resolution for *.loco](#3-dns-wildcard-resolution-for-loco)
4. [The _infra/ Stack](#4-the-infra-stack)
5. [How Docker Compose Projects Connect](#5-how-docker-compose-projects-connect)
6. [How Kind Clusters Connect](#6-how-kind-clusters-connect)
7. [The Registry](#7-the-registry)
8. [Project Templates](#8-project-templates)
9. [The justfile: All Commands](#9-the-justfile-all-commands)
10. [Agent Skills](#10-agent-skills)
11. [Bootstrapping from Scratch](#11-bootstrapping-from-scratch)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  macOS Host                                                             │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  Homebrew dnsmasq                                              │       │
│  │  *.loco → 10.254.254.254                                 │       │
│  │  *.loco       → 10.254.254.254                                 │       │
│  └──────────────────────┬───────────────────────────────────────┘       │
│                          │ DNS query                                     │
│                          ▼                                               │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  _infra/ (Docker Compose, always on)                          │       │
│  │                                                                │       │
│  │  ┌───────────┐    ┌──────────────┐    ┌──────────────────┐    │       │
│  │  │  Traefik   │    │   Registry   │    │  overview (opt)  │    │       │
│  │  │  :80, :443 │    │  :5001/5000  │    │  status.jorpo    │    │       │
│  │  │  dashboard │    │  registry.   │    │  .loco           │    │       │
│  │  │  traefik.  │    │  loco        │    │                  │    │       │
│  │  │  jorpo.loco│    │              │    │                  │    │       │
│  │  └─────┬───────┘    └──────────────┘    └──────────────────┘    │       │
│  │        │                                                        │       │
│  │        ├── Docker provider ──→ loco containers (labels)     │       │
│  │        └── File provider  ──→ etc/traefik/services/*.yml       │       │
│  └────────┼─────────────────────────────────────────────────────────┘       │
│           │                                                                  │
│           ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │  loco (Docker bridge network)                         │               │
│  │                                                            │               │
│  │  ┌──────────────────┐  ┌──────────────────┐               │               │
│  │  │  Compose Project  │  │  Kind Cluster    │               │               │
│  │  │  concerto.jorpo   │  │  orc.jorpo.loco  │               │               │
│  │  │  .loco            │  │  (via file       │               │               │
│  │  │                   │  │   provider +     │               │               │
│  │  │                   │  │   host.docker    │               │               │
│  │  │                   │  │   .internal:     │               │               │
│  │  │                   │  │   30080)         │               │               │
│  │  └──────────────────┘  └──────────────────┘               │               │
│  └──────────────────────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Traffic Flow

| Source | DNS resolves to | Hits | Routed to |
|---|---|---|---|
| `concerto.jorpo.loco` | `10.254.254.254` | Traefik :80 | Docker label → concerto container |
| `registry.loco` | `10.254.254.254` | Traefik :80 | Docker label → registry container |
| `dash.orc.jorpo.loco` | `10.254.254.254` | Traefik :80 | File provider → `host.docker.internal:30080` → kind node → kind-Traefik → pod |
| `traefik.loco` | `10.254.254.254` | Traefik :80 | Traefik dashboard (internal) |

### Domain Scheme

| Domain | Purpose |
|---|---|
| `jorpo.loco` | Root site (Docker Compose project at `~/Projects/sites/jorpo-website/`) |
| `*.jorpo.loco` | Per-project domains (`concerto.jorpo.loco`, `tasqo.jorpo.loco`, etc.) |
| `registry.loco` | Docker registry hostname |
| `traefik.loco` | Traefik dashboard |
| `status.jorpo.loco` | (optional) Overview page |

---

## 2. Design Principles

1. **Deterministic** — Every script is idempotent. Running it twice produces the same result.
2. **Self-contained** — Everything lives in `~/Projects/_infra/`. Skills are symlinked to pi.
3. **No /etc/hosts editing** — dnsmasq handles wildcard DNS. No manual entries.
4. **Per-project sovereignty** — Folder structure is purely organisational. Networking config lives in each project's `compose.yaml` or in `_infra/etc/traefik/services/` (for all types).
5. **Validation at every step** — Scripts check preconditions, validate outputs, and fail early.
6. **Portable across projects** — Same template, same labels, same pattern for everything.

---

## 3. DNS: Wildcard Resolution for *.loco

### Why

No `/etc/hosts` entries. Any `*.loco` domain resolves to `10.254.254.254` — a dedicated loopback alias that Traefik binds to.

### How It Works

```
Browser → DNS lookup for "concerto.jorpo.loco"
  → macOS resolver (/etc/resolver/loco) → dnsmasq (port 53)
    → dnsmasq config: address=/.loco/10.254.254.254
      → returns 10.254.254.254
        → Browser connects to 10.254.254.254:80 → Traefik
```

### What Gets Installed

| Component | Location | Purpose |
|---|---|---|
| Loopback alias | `lo0` alias `10.254.254.254` | Dedicated IP for DNS traffic |
| dnsmasq config | `/usr/local/etc/dnsmasq.d/loco.conf` | `address=/.loco/10.254.254.254` |
| macOS resolver | `/etc/resolver/loco` | `nameserver 10.254.254.254` |
| Launch daemon | `/Library/LaunchDaemons/com.loco.infra.plist` | Persists loopback alias across reboots |

### Script

```bash
# scripts/dns.sh install
# Step 1: Create loopback alias (via launchd plist)
# Step 2: brew install dnsmasq (if not installed)
# Step 3: Write dnsmasq config for .loco
# Step 4: Create macOS resolver files
# Step 5: Restart dnsmasq
# Step 6: Verify resolution
```

Run once: `just setup`

---

## 4. The _infra/ Stack

### Files

```
_infra/
├── compose.yml              ← Traefik + Registry + Registry UI + skillrunner (always on)
├── justfile                 ← All commands
├── README.md                ← This document
├── etc/
│   ├── dns/                 ← DNS config files (source of truth, symlinked to system)
│   │   ├── dnsmasq.conf
│   │   ├── com.loco.infra.plist
│   │   └── resolver/
│   │       └── loco
│   └── traefik/
│       ├── traefik.yml      ← Static config
│       └── services/        ← File provider (compose, site, kind)
│           ├── orc.yml      ← Example: routes *.orc.jorpo.loco → kind
│           └── templates/   ← (reserved)
├── templates/
│   ├── compose.yml          ← Template for Docker Compose projects
│   └── kind-config.yaml     ← Template for kind cluster config
├── scripts/
│   ├── dns.sh               ← DNS setup/teardown
│   ├── infra.sh             ← Compose lifecycle
│   ├── registry.sh          ← Registry helpers
│   ├── scaffold.sh          ← Project scaffolding
│   └── kind.sh              ← Kind management + port allocation
├── skills/
│   ├── loco-infra/
│   │   └── SKILL.md
│   ├── loco-project/
│   │   └── SKILL.md
│   └── loco-kind/
│       └── SKILL.md
└── var/
    ├── registry/            ← Image storage
    ├── logs/                ← Traefik logs
    └── port-allocations.json ← Tracked kind ports
```

### compose.yml

The full `compose.yml` runs four services: Traefik, Registry, Registry UI, and skillrunner.
See the actual file at `_infra/compose.yml` for the definitive version.

Key details:

| Service | Image | Container Name | Purpose |
|---|---|---|---|
| `traefik` | `traefik:v3` | `loco-traefik` | Reverse proxy (port 80/443 on `10.254.254.254`) |
| `registry` | `registry:2` | `loco-registry` | Docker image registry (port 5001 on localhost) |
| `registry-ui` | `joxit/docker-registry-ui` | `loco-registry-ui` | Web UI for registry at `registry.loco` |
| `skillrunner` | (built from `./skillrunner/`) | `loco-skillrunner` | HTTP API server (port 9999 on localhost) |

Volume mounts:
- Traefik static config: `./etc/traefik:/etc/traefik:ro`
- File provider configs: part of the `etc/traefik` mount (inside `/etc/traefik/services/`)
- Logs: `./var/logs/:/var/log/traefik/:rw`
- Registry storage: `./var/registry:/var/lib/registry:rw`
- Docker socket: `/var/run/docker.sock:/var/run/docker.sock`
- Project files: `${HOME}/Projects:/projects:rw` (for skillrunner)

### traefik.yml (static config)

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    network: loco
    exposedByDefault: false
  file:
    directory: /etc/traefik/services/
    watch: true

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log

api:
  dashboard: true
```

### Lifecycle

```bash
just up       # docker compose up -d
just down     # docker compose down
just status   # docker compose ps
just logs     # docker compose logs -f
just restart  # docker compose restart
```

---

## 5. How Docker Compose Projects Connect

### The Pattern

All project types — compose, kind, and site — use the **Traefik file provider** for routing.
Config files live in `etc/traefik/services/` inside the infra stack. No Docker labels needed.

Every project that needs networking:

1. Joins the external `loco` network (adds `networks: [loco]` to its own `compose.yaml`)
2. The scaffold step writes a Traefik file provider config to `etc/traefik/services/<name>.yml`
3. No `loco.compose.yaml` files, no Traefik labels

### Traefik File Provider Config

Written by `just scaffold-http-only <name> <port>`, `just scaffold-terminate <name> <port>`, or `just scaffold-passthrough <name> <domain> <http_port> <tls_port>`:

```yaml
# _infra/etc/traefik/services/myapp.yml
http:
  routers:
    myapp:
      rule: "HostRegexp(`{subdomain:.+}.myapp.jorpo.loco`) || Host(`myapp.jorpo.loco`)"
      entryPoints: ["web"]
      service: myapp
    myapp-secure:
      rule: "HostRegexp(`{subdomain:.+}.myapp.jorpo.loco`) || Host(`myapp.jorpo.loco`)"
      entryPoints: ["websecure"]
      service: myapp
      tls: {}
  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://myapp:3000"
```

This gives both `myapp.jorpo.loco` and `*.myapp.jorpo.loco` (e.g. `api.myapp.jorpo.loco`).

### Example: concerto (`compose.yaml`)

The project's own compose file only needs network attachment — no labels:

```yaml
# ~/Projects/jorpo/concerto/compose.yaml
services:
  app:
    build: .
    container_name: concerto
    networks:
      - loco

  db:
    image: postgres:16
    networks:
      - loco
    # db is internal only — no Traefik route needed

networks:
  loco:
    external: true
```

### Example: jorpo website (root domain, site project)

```yaml
# ~/Projects/sites/jorpo-website/compose.yaml
services:
  web:
    build: .
    container_name: jorpo-website
    networks:
      - loco

networks:
  loco:
    external: true
```

### How Discovery Works

1. `just scaffold-http-only <name> <port>` (or `scaffold-terminate`/`scaffold-passthrough`) writes a file provider config to `etc/traefik/services/<name>.yml`
2. Traefik watches this directory and loads the route dynamically
3. The project container joins the `loco` network via its own `compose.yaml`
4. Docker DNS resolves the container name on `loco` — no labels needed

---

## 6. How Kind Clusters Connect

### Why File Provider

Kind clusters run on the `kind` Docker bridge network, not `loco`. They can't reach Traefik
via Docker DNS. Instead, each kind cluster gets a config file in `etc/traefik/services/`
that routes to `host.docker.internal:<http_port>`. Composer projects use the same file
provider approach but route via Docker DNS on the `loco` network.

### Flow

```
Browser → orc.jorpo.loco:80 → Traefik (Docker, port 80)
  → File provider config (orc.yml)
    → http://host.docker.internal:30080
      → kind node (Docker container, hostPort:30080)
        → kind-Traefik (NodePort:30080)
          → pod
```

### Port Allocation

Ports are allocated deterministically. Each kind cluster gets a unique HTTP and TLS port.

| Cluster | HTTP Host Port | TLS Host Port | Config File |
|---|---|---|---|
| `orc` | 30080 | 30443 | `etc/traefik/services/orc.yml` |
| `next-cluster` | 30081 | 30444 | `etc/traefik/services/next-cluster.yml` |
| `another` | 30082 | 30445 | `etc/traefik/services/another.yml` |

Ports are tracked in `var/port-allocations.json`:

```json
{
  "orc": { "http": 30080, "tls": 30443 },
  "next-cluster": { "http": 30081, "tls": 30444 }
}
```

### Kind Config Template

```yaml
# templates/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: {{cluster_name}}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: {{http_port}}
        protocol: TCP
      - containerPort: 30443
        hostPort: {{tls_port}}
        protocol: TCP
  - role: worker
```

### Example: orc Cluster

```yaml
# etc/traefik/services/orc.yml
http:
  routers:
    orc:
      rule: "HostRegexp(`{subdomain:.+}.orc.jorpo.loco`) || Host(`orc.jorpo.loco`)"
      entryPoints: ["web"]
      service: orc
    orc-secure:
      rule: "HostRegexp(`{subdomain:.+}.orc.jorpo.loco`) || Host(`orc.jorpo.loco`)"
      entryPoints: ["websecure"]
      service: orc
      tls: {}

  services:
    orc:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:30080"
```

### Kind-Cluster-Specific Ingress

Inside the kind cluster, you still need an ingress controller (Traefik or nginx-ingress) to route to pods. That's the cluster's own concern — this stack only handles getting traffic from the host to the cluster node.

The kind cluster's ingress controller must be configured with `NodePort: 30080/30443` (the `containerPort` in the kind config, NOT the `hostPort`).

---

## 7. The Registry

### Access Methods

| Method | URL | Used By |
|---|---|---|
| Hostname (Traefik) | `registry.loco` | Docker Compose projects on loco |
| Direct (host) | `localhost:5001` | Host commands, manual pushes |
| Docker bridge | `kind-registry:5000` | Kind nodes (containerd mirror) |

### Kind Containerd Mirror

Kind nodes are configured to resolve `localhost:5001` → `kind-registry:5000` via containerd's `hosts.toml`:

```toml
# /etc/containerd/certs.d/localhost:5001/hosts.toml (on each kind node)
[host."http://kind-registry:5000"]
  capabilities = ["pull", "resolve"]
```

This is set up automatically by the kind creation script.

### Commands

```bash
just registry-push myimage:latest   # tag + push to registry.loco/myimage:latest
just registry-list                   # list all repositories
just registry-clean                  # garbage collect (if supported)
```

---

## 8. Project Templates

Traefik file provider templates live in `templates/`. Three variants are available
for different SSL modes:

| Template | SSL Mode | Used By |
|---|---|---|
| `templates/traefik-http-only.yml` | None (HTTP only) | `scaffold-http-only` |
| `templates/traefik-terminate.yml` | Terminate (Traefik handles HTTPS) | `scaffold-terminate` |
| `templates/traefik-passthrough.yml` | Passthrough (TLS → backend) | `scaffold-passthrough` |

All templates use the same variable set:

```
Variables: {{name}}, {{domain}}, {{host}}, {{http_port}}, {{tls_port}}
```

The difference between types is in the variables passed:

| Type | `{{host}}` | `{{domain}}` | Resolution |
|---|---|---|---|
| Compose (HTTP only) | `myapp` (container name) | `.jorpo.loco` | Docker DNS on `loco` network |
| Site (SSL terminate) | `blog` (container name) | `.loco` | Docker DNS on `loco` network |
| Kind (SSL passthrough) | `host.docker.internal` | `.jorpo.loco` | Host port (kind uses separate bridge) |

Produces a Traefik file provider config with both bare domain and wildcard subdomain.

---

## 9. The justfile: All Commands

### DNS

| Command | Description |
|---|---|
| `just setup` | Full install: DNS, pull images, install skills |
| `just teardown` | Full uninstall: remove skills, stack, DNS |
| `just status` | Show DNS + stack + skills status |

DNS is part of `just setup` (calls `scripts/dns.sh install`). Run `scripts/dns.sh status` for detailed DNS diagnostics.

### Infra Stack

| Command | Description |
|---|---|
| `just up` | Start _infra/ stack (Traefik + Registry + UI + skillrunner) |
| `just down` | Stop _infra/ stack |
| `just status` | Show stack status |
| `just logs` | Tail logs |
| `just restart` | Restart stack |
| `just registry` | Open registry UI in browser |
| `just traefik` | Open Traefik dashboard in browser |

### Registry

| Command | Description |
|---|---|
| `just registry-push IMAGE [TAG]` | Tag and push image to registry.loco |
| `just registry-list` | List repositories |
| `just registry-clean` | Garbage collect info |

### Scaffolding

| Command | Description |
|---|---|
| `just scaffold-http-only NAME [PORT]` | Register a project with Traefik (HTTP only) |
| `just scaffold-terminate NAME [PORT]` | Register a project with SSL termination |
| `just scaffold-passthrough NAME DOMAIN HTTP_PORT TLS_PORT` | Register a project with SSL passthrough |
| `just scaffold-kind NAME` | Generate kind-config.yaml for a new cluster project |

### Kind Management

| Command | Description |
|---|---|
| `just kind-create NAME` | Allocate ports, create cluster, register Traefik route, configure mirror |
| `just kind-delete NAME` | Delete cluster, free ports, remove file config |
| `just kind-import NAME` | Register existing cluster (ports, mirror, Traefik config) |
| `just kind-list` | List clusters with port mappings |
| `just kind-ports` | Show port allocations |

### System

| Command | Description |
|---|---|
| `just setup` | Full install: DNS + images + skills |
| `just teardown` | Full uninstall |
| `just ps` | Show all running containers + clusters + configs |
| `just doctor` | Check all components are healthy |
| `just env` | Show environment variables and paths |

---

## 10. Agent Skills

### loco-infra

```
Location: skills/loco-infra/SKILL.md
Purpose: Infrastructure lifecycle (stack up/down, DNS, registry)
Triggers: "start the infra", "what's running", "restart traefik"
```

### loco-project

```
Location: skills/loco-project/SKILL.md
Purpose: Scaffold new projects with Traefik file provider configs
Triggers: "create a new project called X", "add networking to Y"
```

### loco-kind

```
Location: skills/loco-kind/SKILL.md
Purpose: Create/delete kind clusters with port allocation + file config
Triggers: "create a kind cluster for X", "delete cluster Y"
```

### Skill Installation

Skills are installed as part of `just setup` (calls `scripts/skills.sh install`):

```bash
just setup
# Creates symlinks:
#   ~/.pi/skills/loco-infra → ~/Projects/_infra/skills/loco-infra
#   ~/.pi/skills/loco-project → ~/Projects/_infra/skills/loco-project
#   ~/.pi/skills/loco-kind → ~/Projects/_infra/skills/loco-kind
```

Or run just the skills step:

```bash
scripts/skills.sh install
```

---

## 11. Bootstrapping from Scratch

### Step 1: Full Install

```bash
cd ~/Projects/_infra
just setup
```

This installs dnsmasq, creates the loopback alias, configures macOS resolvers,
pulls Docker images, and installs agent skills — all in one step.

### Step 2: Start the Infra Stack

```bash
just up
```

Starts Traefik (port 80/443 on `10.254.254.254`), Registry (port 5001), Registry UI, and skillrunner.

### Step 3: Verify

```bash
just status
# Should show: loco-traefik (running), loco-registry (running), loco-registry-ui (running), loco-skillrunner (running)

just doctor
# Should show all checks green

# Test DNS
ping -c 1 concerto.jorpo.loco
# Should resolve to 10.254.254.254

# Test Traefik dashboard
open http://traefik.loco
```

### Step 4: (Already done — see Step 1)

Skills are installed as part of `just setup`.

### Step 5: Create Projects

```bash
# Docker Compose project (HTTP only)
just scaffold-http-only myapp 3000

# Kind cluster
just scaffold-kind mycluster
just kind-create mycluster
```

---

## 12. Troubleshooting

### DNS not resolving

```bash
# Check dnsmasq is running
brew services list | grep dnsmasq

# Check resolver files exist
cat /etc/resolver/loco

# Test resolution
dig concerto.jorpo.loco @10.254.254.254

# Check loopback alias
ifconfig lo0 | grep 10.254.254.254
```

### Traefik not routing

```bash
# Check Traefik is running
docker ps | grep loco-traefik

# Check Traefik logs
just logs

# Check Traefik dashboard
open http://traefik.loco

# Verify the container has labels
docker inspect <container> | jq '.[].Config.Labels'
```

### Registry not reachable

```bash
# Check registry is running
docker ps | grep loco-registry

# Test direct access
curl http://localhost:5001/v2/_catalog

# Test via Traefik
curl -H "Host: registry.loco" http://10.254.254.254/v2/_catalog
```

### Kind cluster not routing

```bash
# Check file provider config exists
ls -la etc/traefik/services/

# Check port allocation
cat var/port-allocations.json

# Check kind cluster is running
kind get clusters

# Test direct connection to kind node
curl http://host.docker.internal:<port>/
```

---

## Appendix: Port Allocation Scheme

| Cluster | HTTP | TLS | Config File |
|---|---|---|---|
| orc | 30080 | 30443 | etc/traefik/services/orc.yml |
| — | 30081 | 30444 | next available |
| — | 30082 | 30445 | next available |

Ports are allocated on create, freed on delete. The scheme is:
- HTTP: 30080 + N (where N is the allocation order, 0-based)
- TLS: 30443 + N

---

## Appendix: File Layout

```
~/Projects/
├── _infra/                    ← This stack (always on)
│   ├── compose.yml
│   ├── justfile
│   ├── README.md
│   ├── etc/
│   │   ├── dns/
│   │   └── traefik/
│   ├── templates/
│   ├── scripts/
│   ├── skills/
│   └── var/
│
├── jorpo/                     ← Personal projects
│   ├── concerto/
│   │   └── compose.yaml       ← Joins loco, has file provider config
│   ├── orchestration/
│   │   ├── compose.yaml       ← Kind project (or not needed)
│   │   ├── deploy/kind/       ← kind-config.yaml
│   │   └── ...                ← existing files
│   ├── tasqo/
│   │   └── compose.yaml
│   └── ...
│
├── sites/                     ← Website projects
│   └── jorpo-website/
│       └── compose.yaml       ← Host(jorpo.loco)
│
├── playground/
│   └── ...
│
├── community/
│   └── ...
│
└── downloaded/
    └── ...
```

---

> **One stack to rule them all. No /etc/hosts. No manual config. Just `just up` and go.**
