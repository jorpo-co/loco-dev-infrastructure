#!/usr/bin/env bash
# scripts/kind.sh — Manage kind clusters with automatic port allocation + Traefik routing
#
# All operations are idempotent. Both create and import automatically register the
# Traefik file provider route via scaffold.sh — no separate step needed.
#
# Usage:
#   scripts/kind.sh create <name>    Create kind cluster + allocate ports + register Traefik route
#   scripts/kind.sh delete <name>    Delete cluster + free ports + remove Traefik config
#   scripts/kind.sh import <name>    Register existing cluster with infra (ports, mirror, Traefik config)
#   scripts/kind.sh list             List clusters with port mappings
#   scripts/kind.sh ports            Show port allocations
#   scripts/kind.sh scaffold <name>  Generate kind-config.yaml for a new cluster project

set -euo pipefail

# ── Optional named flags (for agent/container use) ──
project_dir=""
infra_dir=""
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --project-dir) shift; project_dir="$1"; shift ;;
    --infra-dir)   shift; infra_dir="$1";   shift ;;
    *) break ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine _infra root
if [ -n "$infra_dir" ]; then
  PROJECT_DIR="$infra_dir"
elif [[ "$SCRIPT_DIR" == */infra/scripts* ]] || [[ "$SCRIPT_DIR" == */_infra/scripts* ]]; then
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ── Load environment ──
if [ -f "${PROJECT_DIR}/.env.defaults" ]; then
  set -a
  source "${PROJECT_DIR}/.env.defaults"
  [ -f "${PROJECT_DIR}/.env" ] && source "${PROJECT_DIR}/.env"
  set +a
fi

# ── Config (env defaults, computed paths) ──
PORT_ALLOCATIONS="${PROJECT_DIR}/${PORT_ALLOCATIONS_RELPATH:-var/port-allocations.json}"
TRAEFIK_CONFIG_DIR="${PROJECT_DIR}/${TRAEFIK_CONFIG_SUBDIR:-etc/traefik/services}"
TEMPLATE_DIR="${PROJECT_DIR}/${TEMPLATES_RELPATH:-templates}"
KIND_CONFIG_TEMPLATE="${TEMPLATE_DIR}/kind-config.yaml"
HTTP_PORT_START="${KIND_HTTP_PORT_START:-30080}"
TLS_PORT_START="${KIND_TLS_PORT_START:-30443}"
PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/Projects}"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

_init_port_allocations() {
  if [ ! -f "$PORT_ALLOCATIONS" ]; then
    mkdir -p "$(dirname "$PORT_ALLOCATIONS")"
    echo "{}" > "$PORT_ALLOCATIONS"
  fi
}

_get_allocations() {
  _init_port_allocations
  cat "$PORT_ALLOCATIONS"
}

_save_allocations() {
  local data="$1"
  echo "$data" > "$PORT_ALLOCATIONS"
}

_next_http_port() {
  _init_port_allocations
  local allocs
  allocs=$(cat "$PORT_ALLOCATIONS")
  local used_ports
  used_ports=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
ports = [v["http"] for v in data.values()] if data else []
if not ports:
    print(30080)
else:
    print(max(ports) + 1)
PYEOF
)" <<< "$allocs" 2>/dev/null)

  if [ -z "$used_ports" ]; then
    echo "$HTTP_PORT_START"
  else
    echo "$used_ports"
  fi
}

_next_tls_port() {
  _init_port_allocations
  local allocs
  allocs=$(cat "$PORT_ALLOCATIONS")
  local used_ports
  used_ports=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
ports = [v["tls"] for v in data.values()] if data else []
if not ports:
    print(30443)
else:
    print(max(ports) + 1)
PYEOF
)" <<< "$allocs" 2>/dev/null)

  if [ -z "$used_ports" ]; then
    echo "$TLS_PORT_START"
  else
    echo "$used_ports"
  fi
}

_cluster_exists() {
  local name="$1"
  kind get clusters 2>/dev/null | grep -q "^${name}$"
}

# ──────────────────────────────────────────────
# Traefik route registration
# ──────────────────────────────────────────────

_register_traefik_route() {
  local name="$1"
  local http_port="$2"
  local tls_port="$3"

  echo ""
  echo "═══ Registering Traefik route for ${name} ═══"

  local scaffold="${SCRIPT_DIR}/scaffold.sh"
  if [ ! -f "$scaffold" ]; then
    echo "  ✗ scaffold.sh not found at ${scaffold}"
    echo "  Register manually: scaffold-passthrough ${name} .jorpo.loco ${http_port} ${tls_port}"
    return 1
  fi

  "$scaffold" --infra-dir "$PROJECT_DIR" register \
    --name "$name" \
    --domain ".jorpo.loco" \
    --host "host.docker.internal" \
    --http-port "$http_port" \
    --tls-port "$tls_port" \
    --ssl "passthrough"
}

# ──────────────────────────────────────────────
# Create
# ──────────────────────────────────────────────

cmd_create() {
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") create <cluster-name>"
    exit 1
  fi

  local name="$1"
  local http_port
  local tls_port

  echo "═══ Creating kind cluster '${name}' ═══"
  echo ""

  # Check if cluster already exists
  if _cluster_exists "$name"; then
    echo "  ✓ Cluster '${name}' already exists"
    # Get existing ports from allocations
    local allocs
    allocs=$(cat "$PORT_ALLOCATIONS")
    http_port=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
if name in data:
    print(data[name]["http"])
else:
    print("")
PYEOF
)" "$name" <<< "$allocs" 2>/dev/null)
    tls_port=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
if name in data:
    print(data[name]["tls"])
else:
    print("")
PYEOF
)" "$name" <<< "$allocs" 2>/dev/null)
  else
    # Allocate ports
    http_port=$(_next_http_port)
    tls_port=$(_next_tls_port)
    echo "  Allocating ports: HTTP=${http_port}, TLS=${tls_port}"
  fi

  # Check kind is available
  if ! command -v kind &>/dev/null; then
    echo "✗ 'kind' not found. Install with: brew install kind"
    exit 1
  fi

  # Create cluster (if not exists)
  if ! _cluster_exists "$name"; then
    echo ""
    echo "  Creating kind cluster '${name}'..."
    local config_file
    config_file=$(mktemp)
    cat "$KIND_CONFIG_TEMPLATE" \
      | sed "s/{{cluster_name}}/${name}/g" \
      | sed "s/{{http_port}}/${http_port}/g" \
      | sed "s/{{tls_port}}/${tls_port}/g" \
      > "$config_file"

    kind create cluster --config "$config_file"
    rm -f "$config_file"
    echo "  ✓ Cluster created"
  fi

  # Save port allocations
  local current
  current=$(cat "$PORT_ALLOCATIONS")
  local updated
  updated=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
http = int(sys.argv[2])
tls = int(sys.argv[3])
data[name] = {"http": http, "tls": tls}
json.dump(data, sys.stdout)
PYEOF
)" "$name" "$http_port" "$tls_port" <<< "$current" 2>/dev/null)
  _save_allocations "$updated"
  echo "  ✓ Ports allocated"

  # Configure containerd mirror for registry
  echo ""
  echo "  Configuring containerd mirror for registry..."
  local reg_name="kind-registry"
  local reg_port="5001"
  local dir="/etc/containerd/certs.d/localhost:${reg_port}"

  for node in $(kind get nodes --name "$name" 2>/dev/null); do
    docker exec "$node" mkdir -p "$dir" 2>/dev/null || true
    cat <<CONFIG | docker exec -i "$node" tee "$dir/hosts.toml" > /dev/null 2>/dev/null || true
[host."http://${reg_name}:5000"]
  capabilities = ["pull", "resolve"]
CONFIG
  done
  echo "  ✓ Containerd mirror configured"

  # Restart containerd on nodes
  for node in $(kind get nodes --name "$name" 2>/dev/null); do
    docker exec "$node" systemctl restart containerd 2>/dev/null || \
      docker exec "$node" pkill -HUP containerd 2>/dev/null || true
  done

  # Verify
  echo ""
  echo "── Verification ──"
  if _cluster_exists "$name"; then
    echo "  ✓ Cluster '${name}' is running"
    kubectl cluster-info --context "kind-${name}" 2>/dev/null | head -3 || echo "  (kubectl context not set)"
  else
    echo "  ✗ Cluster '${name}' failed to start"
    exit 1
  fi

  echo ""
  echo "═══ Kind cluster '${name}' created ═══"
  echo "  HTTP:  host.docker.internal:${http_port}"
  echo "  TLS:   host.docker.internal:${tls_port}"
  echo "  Domain: *.${name}.jorpo.loco → ${name}.jorpo.loco"

  _register_traefik_route "$name" "$http_port" "$tls_port"

  echo ""
  echo "  To switch: kubectl config use-context kind-${name}"
}

# ──────────────────────────────────────────────
# Import (register existing cluster without creating it)
# ──────────────────────────────────────────────

cmd_import() {
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") import <cluster-name>"
    echo "  Registers an existing kind cluster with the infra Traefik router."
    echo "  Allocates ports, writes file provider config, configures containerd mirror."
    echo "  Does NOT create the cluster."
    exit 1
  fi

  local name="$1"

  echo "═══ Importing kind cluster '${name}' ═══"
  echo ""

  # Check cluster exists
  if ! _cluster_exists "$name"; then
    echo "  ✗ Cluster '${name}' not found in kind."
    echo "  Start it first with: kind create cluster --name ${name}"
    exit 1
  fi

  # Check if already registered
  local allocs
  allocs=$(cat "$PORT_ALLOCATIONS")
  local http_port
  local tls_port
  http_port=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
print(data.get(name, {}).get(\"http\", \"\"))
" "$name" <<< "$allocs" 2>/dev/null)

  if [ -n "$http_port" ]; then
    tls_port=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
print(data.get(name, {}).get(\"tls\", \"\"))
" "$name" <<< "$allocs" 2>/dev/null)
    echo "  ✓ Already registered — HTTP=${http_port} TLS=${tls_port}"
  else
    http_port=$(_next_http_port)
    tls_port=$(_next_tls_port)
    echo "  Allocating ports: HTTP=${http_port}, TLS=${tls_port}"

    local updated
    updated=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
http = int(sys.argv[2])
tls = int(sys.argv[3])
data[name] = {\"http\": http, \"tls\": tls}
json.dump(data, sys.stdout)
" "$name" "$http_port" "$tls_port" <<< "$allocs" 2>/dev/null)
    _save_allocations "$updated"
    echo "  ✓ Ports allocated"
  fi

  # Configure containerd mirror for registry
  echo ""
  echo "  Configuring containerd mirror for registry..."
  local reg_name="kind-registry"
  local reg_port="5001"
  local dir="/etc/containerd/certs.d/localhost:${reg_port}"

  for node in $(kind get nodes --name "$name" 2>/dev/null); do
    docker exec "$node" mkdir -p "$dir" 2>/dev/null || true
    cat <<CONFIG | docker exec -i "$node" tee "$dir/hosts.toml" > /dev/null 2>/dev/null || true
[host."http://${reg_name}:5000"]
  capabilities = ["pull", "resolve"]
CONFIG
  done
  echo "  ✓ Containerd mirror configured"

  for node in $(kind get nodes --name "$name" 2>/dev/null); do
    docker exec "$node" systemctl restart containerd 2>/dev/null || \
      docker exec "$node" pkill -HUP containerd 2>/dev/null || true
  done

  echo ""
  echo "═══ Kind cluster '${name}' imported ═══"
  echo "  HTTP:  host.docker.internal:${http_port}"
  echo "  TLS:   host.docker.internal:${tls_port}"
  echo "  Domain: *.${name}.jorpo.loco → ${name}.jorpo.loco"

  _register_traefik_route "$name" "$http_port" "$tls_port"
}

# ──────────────────────────────────────────────
# Delete
# ──────────────────────────────────────────────

cmd_delete() {
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") delete <cluster-name>"
    exit 1
  fi

  local name="$1"

  echo "═══ Deleting kind cluster '${name}' ═══"
  echo ""

  # Delete cluster
  if _cluster_exists "$name"; then
    echo "  Deleting cluster..."
    kind delete cluster --name "$name"
    echo "  ✓ Cluster deleted"
  else
    echo "  - Cluster '${name}' does not exist"
  fi

  # Remove Traefik config
  local config_file="${TRAEFIK_CONFIG_DIR}/${name}.yml"
  if [ -f "$config_file" ]; then
    rm -f "$config_file"
    echo "  ✓ Config removed: ${config_file}"
  else
    echo "  - No config file found"
  fi

  # Free port allocations
  local current
  current=$(cat "$PORT_ALLOCATIONS")
  local updated
  updated=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
if name in data:
    del data[name]
json.dump(data, sys.stdout)
PYEOF
)" "$name" <<< "$current" 2>/dev/null)
  _save_allocations "$updated"
  echo "  ✓ Ports freed"

  echo ""
  echo "═══ Kind cluster '${name}' deleted ═══"
}

# ──────────────────────────────────────────────
# List
# ──────────────────────────────────────────────

cmd_list() {
  echo "═══ Kind Clusters ═══"
  echo ""

  local clusters
  clusters=$(kind get clusters 2>/dev/null) || true

  if [ -z "$clusters" ]; then
    echo "  No clusters found."
  else
    echo "  Clusters:"
    echo "$clusters" | while IFS= read -r cluster; do
      local http_port
      local tls_port
      local allocs
      allocs=$(cat "$PORT_ALLOCATIONS")
      http_port=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
print(data.get(name, {}).get("http", "?"))
PYEOF
)" "$cluster" <<< "$allocs" 2>/dev/null)
      tls_port=$(python3 -c "$(cat << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
print(data.get(name, {}).get("tls", "?"))
PYEOF
)" "$cluster" <<< "$allocs" 2>/dev/null)
      echo "    ${cluster}: HTTP=${http_port} TLS=${tls_port} → *.${cluster}.jorpo.loco"
    done
  fi

  echo ""
  echo "── Port Allocations ──"
  if [ -f "$PORT_ALLOCATIONS" ]; then
    python3 -m json.tool "$PORT_ALLOCATIONS" 2>/dev/null || cat "$PORT_ALLOCATIONS"
  else
    echo "  (none)"
  fi
}

# ──────────────────────────────────────────────
# Ports
# ──────────────────────────────────────────────

cmd_ports() {
  _init_port_allocations
  echo "═══ Port Allocations ═══"
  python3 -m json.tool "$PORT_ALLOCATIONS" 2>/dev/null || echo "{}"
}

# ──────────────────────────────────────────────
# Scaffold (kind-config.yaml)
# ──────────────────────────────────────────────

cmd_scaffold() {
  local name="" category=""

  if [ -n "$project_dir" ]; then
    name="$(basename "$project_dir")"
    category="$(basename "$(dirname "$project_dir")")"
  else
    if [ $# -lt 1 ]; then
      echo "Usage: $(basename "$0") scaffold <name> [category]"
      echo "  name      Cluster name (also becomes the domain: *.name.jorpo.loco)"
      echo "  category  Subfolder under ~/Projects/ (default: inferred from PWD)"
      echo ""
      echo "Or with --project-dir (flags before subcommand):"
      echo "  $(basename "$0") --project-dir /projects/<category>/<name> scaffold"
      exit 1
    fi
    name="$1"
    category="${2:-}"

    if [ -z "$category" ]; then
      local current_dir
      current_dir=$(pwd)
      if [[ "$current_dir" == "$PROJECTS_DIR"/* ]]; then
        category=$(echo "$current_dir" | sed "s|${PROJECTS_DIR}/||" | cut -d'/' -f1)
      else
        echo "  Could not determine category. Specify it or run from ~/Projects/<category>/"
        echo "  Usage: $(basename "$0") scaffold <name> [category]"
        exit 1
      fi
    fi

    project_dir="${PROJECTS_DIR}/${category}/${name}"
  fi

  local kind_config="${project_dir}/kind-config.yaml"

  echo "═══ Scaffolding Kind Project: ${name} ═══"
  echo ""

  if [ -f "$kind_config" ]; then
    echo "  ✗ kind-config.yaml already exists at ${kind_config}"
    exit 1
  fi

  mkdir -p "$project_dir"

  if [ -f "${TEMPLATE_DIR}/kind-config.yaml" ]; then
    cat "${TEMPLATE_DIR}/kind-config.yaml" \
      | sed "s/{{cluster_name}}/${name}/g" \
      | sed "s/{{http_port}}/{{http_port}}/g" \
      | sed "s/{{tls_port}}/{{tls_port}}/g" \
      > "$kind_config"
    echo "  ✓ Created: ${kind_config}"
  else
    echo "  ✗ Template not found at ${TEMPLATE_DIR}/kind-config.yaml"
    exit 1
  fi

  echo ""
  echo "═══ Kind project '${name}' scaffolded ═══"
  echo "  Location: ${project_dir}"
  echo "  Domain:   *.${name}.jorpo.loco"
  echo "  Next:     kind-create ${name}"
}

usage() {
  echo "Usage: $(basename "$0") <command> [args]"
  echo ""
  echo "Commands:"
  echo "  create <name>    Create kind cluster + allocate ports + register Traefik route"
  echo "  delete <name>    Delete cluster + free ports + remove Traefik config"
  echo "  import <name>    Register existing cluster with infra (ports, mirror, Traefik config)"
  echo "  list             List clusters with port mappings"
  echo "  ports            Show port allocations"
  echo "  scaffold <name>  Generate kind-config.yaml for a new cluster project"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    create)   cmd_create "$@" ;;
    delete)   cmd_delete "$@" ;;
    import)   cmd_import "$@" ;;
    list)     cmd_list "$@" ;;
    ports)    cmd_ports "$@" ;;
    scaffold) cmd_scaffold "$@" ;;
    *)        usage ;;
  esac
}

main "$@"