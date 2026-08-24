# Loco Infra — Local Development Infrastructure

> A self-contained, deterministic local development environment for Docker Compose and kind
> (Kubernetes-in-Docker) projects. One stack to route, register, and orchestrate everything
> running on `*.jorpo.loco` and `*.loco`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Design Principles](#2-design-principles)
3. [DNS: Wildcard Resolution for *.jorpo.loco](#3-dns-wildcard-resolution-for-jorpoloco)
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
│  │  *.jorpo.loco → 10.254.254.254                                 │       │
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
│  │        ├── Docker provider ──→ loco-net containers (labels)     │       │
│  │        └── File provider  ──→ traefik/config/*.yml (kind)       │       │
│  └────────┼─────────────────────────────────────────────────────────┘       │
│           │                                                                  │
│           ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │  loco-net (Docker bridge network)                         │               │
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
| `traefik.jorpo.loco` | `10.254.254.254` | Traefik :80 | Traefik dashboard (internal) |

### Domain Scheme

| Domain | Purpose |
|---|---|
| `jorpo.loco` | Root site (Docker Compose project at `~/Projects/sites/jorpo-website/`) |
| `*.jorpo.loco` | Per-project domains (`concerto.jorpo.loco`, `tasqo.jorpo.loco`, etc.) |
| `registry.loco` | Docker registry hostname |
| `traefik.jorpo.loco` | Traefik dashboard |
| `status.jorpo.loco` | (optional) Overview page |

---

## 2. Design Principles

1. **Deterministic** — Every script is idempotent. Running it twice produces the same result.
2. **Self-contained** — Everything lives in `~/Projects/_infra/`. Skills are symlinked to pi.
3. **No /etc/hosts editing** — dnsmasq handles wildcard DNS. No manual entries.
4. **Per-project sovereignty** — Folder structure is purely organisational. Networking config lives in each project's `compose.yaml` or in `_infra/traefik/config/` (for kind).
5. **Validation at every step** — Scripts check preconditions, validate outputs, and fail early.
6. **Portable across projects** — Same template, same labels, same pattern for everything.

---

## 3. DNS: Wildcard Resolution for *.jorpo.loco

### Why

No `/etc/hosts` entries. Any `*.jorpo.loco` domain resolves to `10.254.254.254` — a dedicated loopback alias that Traefik binds to.

### How It Works

```
Browser → DNS lookup for "concerto.jorpo.loco"
  → macOS resolver (/etc/resolver/jorpo.loco) → dnsmasq (port 53)
    → dnsmasq config: address=/.jorpo.loco/10.254.254.254
      → returns 10.254.254.254
        → Browser connects to 10.254.254.254:80 → Traefik
```

### What Gets Installed

| Component | Location | Purpose |
|---|---|---|
| Loopback alias | `lo0` alias `10.254.254.254` | Dedicated IP for DNS traffic |
| dnsmasq config | `/usr/local/etc/dnsmasq.d/loco.conf` | `address=/.jorpo.loco/10.254.254.254` and `address=/.loco/10.254.254.254` |
| macOS resolver | `/etc/resolver/jorpo.loco` | `nameserver 10.254.254.254` |
| macOS resolver | `/etc/resolver/loco` | `nameserver 10.254.254.254` |
| Launch daemon | `/Library/LaunchDaemons/com.loco.infra.plist` | Persists loopback alias across reboots |

### Script

```bash
# scripts/dns.sh install
# Step 1: Create loopback alias (via launchd plist)
# Step 2: brew install dnsmasq (if not installed)
# Step 3: Write dnsmasq config for .jorpo.loco and .loco
# Step 4: Create macOS resolver files
# Step 5: Restart dnsmasq
# Step 6: Verify resolution
```

Run once: `just dns-install`

---

## 4. The _infra/ Stack

### Files

```
_infra/
├── compose.yml              ← Traefik + Registry (always on)
├── justfile                 ← All commands
├── README.md                ← This document
├── traefik/
│   ├── traefik.yml          ← Static config
│   └── config/              ← File provider (kind clusters)
│       ├── orc.yml          ← Example: routes *.orc.jorpo.loco → kind
│       └── templates/
│           └── kind-cluster.yml  ← Template for new kind clusters
├── templates/
│   ├── compose.yml          ← Template for Docker Compose projects
│   └── kind-config.yaml     ← Template for kind cluster config
├── dns/                     ← DNS config files (source of truth, symlinked to system)
│   ├── dnsmasq.conf
│   ├── com.loco.infra.plist
│   └── resolver/
│       ├── jorpo.loco
│       └── loco
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

```yaml
services:
  traefik:
    image: traefik:v3
    container_name: loco-traefik
    restart: unless-stopped
    ports:
      - "10.254.254.254:80:80"
      - "10.254.254.254:443:443"
      - "127.0.0.1:8080:8080"
    command:
      - "--configFile=/etc/traefik/traefik.yml"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml
      - ./traefik/config/:/config/
      - ./var/logs/:/var/log/traefik/
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.jorpo.loco`)"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.entrypoints=web"
      - "traefik.docker.network=loco-net"

  registry:
    image: registry:2
    container_name: loco-registry
    restart: unless-stopped
    ports:
      - "127.0.0.1:5001:5000"
    environment:
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
    volumes:
      - ./var/registry:/var/lib/registry
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(`registry.loco`)"
      - "traefik.http.services.registry.loadbalancer.server.port=5000"
      - "traefik.docker.network=loco-net"

networks:
  loco-net:
    name: loco-net
```

### traefik.yml (static config)

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    network: loco-net
    exposedByDefault: false
  file:
    directory: /config/
    watch: true

log:
  level: INFO
  filePath: /var/log/traefik/access.log

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

Every project that needs networking gets a `compose.yaml` that:

1. Joins the external `loco-net` network
2. Adds Traefik labels to each service that needs to be reachable
3. Sets `traefik.docker.network=loco-net` so Traefik knows which network to route through

### Template

```yaml
# ~/Projects/<category>/<project>/compose.yaml
services:
  app:
    build: .
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.{{project_name}}.rule=Host(`{{project_name}}.jorpo.loco`)"
      - "traefik.http.routers.{{project_name}}.entrypoints=web"
      - "traefik.http.services.{{project_name}}.loadbalancer.server.port={{port}}"
      - "traefik.docker.network=loco-net"

networks:
  loco-net:
    external: true
```

### Example: concerto

```yaml
# ~/Projects/jorpo/concerto/compose.yaml
services:
  app:
    build: .
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.concerto.rule=Host(`concerto.jorpo.loco`)"
      - "traefik.http.routers.concerto.entrypoints=web"
      - "traefik.http.services.concerto.loadbalancer.server.port=3000"
      - "traefik.docker.network=loco-net"

  db:
    image: postgres:16
    networks:
      - loco-net
    # no Traefik labels — db is internal only

networks:
  loco-net:
    external: true
```

### Example: jorpo website (root domain)

```yaml
# ~/Projects/sites/jorpo-website/compose.yaml
services:
  web:
    build: .
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.jorpo.rule=Host(`jorpo.loco`)"
      - "traefik.http.routers.jorpo.entrypoints=web"
      - "traefik.http.services.jorpo.loadbalancer.server.port=80"
      - "traefik.docker.network=loco-net"

networks:
  loco-net:
    external: true
```

### How Discovery Works

1. Traefik watches the Docker socket for containers on `loco-net`
2. When a container with `traefik.enable=true` appears, Traefik reads its labels
3. Traefik creates a route for the `Host()` rule pointing to the container's port
4. No Traefik config file needed — it's fully automatic

---

## 6. How Kind Clusters Connect

### Why File Provider

Kind clusters run on the `kind` Docker bridge network, not `loco-net`. They can't use Docker labels. Instead, each kind cluster gets a config file in `traefik/config/` that tells Traefik how to route to it.

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
| `orc` | 30080 | 30443 | `traefik/config/orc.yml` |
| `next-cluster` | 30081 | 30444 | `traefik/config/next-cluster.yml` |
| `another` | 30082 | 30445 | `traefik/config/another.yml` |

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

### File Provider Config Template

```yaml
# traefik/config/templates/kind-cluster.yml
http:
  routers:
    {{cluster_name}}:
      rule: "HostRegexp(`{subdomain:.+}.{{cluster_name}}.jorpo.loco`) || Host(`{{cluster_name}}.jorpo.loco`)"
      entryPoints: ["web"]
      service: {{cluster_name}}
    {{cluster_name}}-secure:
      rule: "HostRegexp(`{subdomain:.+}.{{cluster_name}}.jorpo.loco`) || Host(`{{cluster_name}}.jorpo.loco`)"
      entryPoints: ["websecure"]
      service: {{cluster_name}}
      tls: {}

  services:
    {{cluster_name}}:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:{{http_port}}"
```

### Example: orc Cluster

```yaml
# traefik/config/orc.yml
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
| Hostname (Traefik) | `registry.loco` | Docker Compose projects on loco-net |
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

### compose.yml Template

Used by `just scaffold compose <name>`:

```
Location: templates/compose.yml
Variables: {{project_name}}, {{port}}, {{category}}
```

### kind-config.yaml Template

Used by `just scaffold kind <name>`:

```
Location: templates/kind-config.yaml
Variables: {{cluster_name}}, {{http_port}}, {{tls_port}}
```

### kind-cluster.yml Template

Used by `just kind-create <name>`:

```
Location: traefik/config/templates/kind-cluster.yml
Variables: {{cluster_name}}, {{http_port}}
```

---

## 9. The justfile: All Commands

### DNS

| Command | Description |
|---|---|
| `just dns-install` | Install dnsmasq, configure *.jorpo.loco, create resolver |
| `just dns-status` | Show DNS configuration status |
| `just dns-uninstall` | Remove DNS configuration |

### Infra Stack

| Command | Description |
|---|---|
| `just up` | Start _infra/ stack (Traefik + Registry) |
| `just down` | Stop _infra/ stack |
| `just status` | Show stack status |
| `just logs` | Tail logs |
| `just restart` | Restart stack |

### Registry

| Command | Description |
|---|---|
| `just registry-push IMAGE` | Tag and push image to registry.loco |
| `just registry-list` | List repositories |
| `just registry-clean` | Garbage collect |

### Scaffolding

| Command | Description |
|---|---|
| `just scaffold compose NAME [PORT]` | Create new Docker Compose project |
| `just scaffold kind NAME` | Create new kind cluster project |
| `just scaffold site NAME` | Create new site project |

### Kind Management

| Command | Description |
|---|---|
| `just kind-create NAME` | Allocate ports, create cluster, write file config |
| `just kind-delete NAME` | Delete cluster, free ports, remove file config |
| `just kind-list` | List clusters with port mappings |

### Skills

| Command | Description |
|---|---|
| `just install-skills` | Symlink _infra/skills/* → ~/.pi/skills/ |

### System

| Command | Description |
|---|---|
| `just ps` | Show all running containers on loco-net + kind clusters |
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
Purpose: Scaffold new projects with compose.yaml + Traefik labels
Triggers: "create a new project called X", "add networking to Y"
```

### loco-kind

```
Location: skills/loco-kind/SKILL.md
Purpose: Create/delete kind clusters with port allocation + file config
Triggers: "create a kind cluster for X", "delete cluster Y"
```

### Skill Installation

```bash
just install-skills
# Creates symlinks:
#   ~/.pi/skills/loco-infra → ~/Projects/_infra/skills/loco-infra
#   ~/.pi/skills/loco-project → ~/Projects/_infra/skills/loco-project
#   ~/.pi/skills/loco-kind → ~/Projects/_infra/skills/loco-kind
```

---

## 11. Bootstrapping from Scratch

### Step 1: Install DNS

```bash
cd ~/Projects/_infra
just dns-install
```

This installs dnsmasq, creates the loopback alias, and configures macOS resolvers.

### Step 2: Start the Infra Stack

```bash
just up
```

Starts Traefik (port 80/443 on `10.254.254.254`) and Registry (port 5001).

### Step 3: Verify

```bash
just status
# Should show: loco-traefik (running), loco-registry (running)

just doctor
# Should show all checks green

# Test DNS
ping -c 1 concerto.jorpo.loco
# Should resolve to 10.254.254.254

# Test Traefik dashboard
open http://traefik.jorpo.loco
```

### Step 4: Install Agent Skills

```bash
just install-skills
```

### Step 5: Create Projects

```bash
# Docker Compose project
just scaffold compose myapp 3000

# Kind cluster
just scaffold kind mycluster
just kind-create mycluster
```

---

## 12. Troubleshooting

### DNS not resolving

```bash
# Check dnsmasq is running
brew services list | grep dnsmasq

# Check resolver files exist
cat /etc/resolver/jorpo.loco
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
open http://traefik.jorpo.loco

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
ls -la traefik/config/

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
| orc | 30080 | 30443 | traefik/config/orc.yml |
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
│   ├── dns/
│   ├── traefik/
│   ├── templates/
│   ├── scripts/
│   ├── skills/
│   └── var/
│
├── jorpo/                     ← Personal projects
│   ├── concerto/
│   │   └── compose.yaml       ← Joins loco-net, has Traefik labels
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