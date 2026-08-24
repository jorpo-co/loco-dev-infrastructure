#!/usr/bin/env bash
# scripts/scaffold.sh — Scaffold new projects with proper compose.yaml + Traefik labels
#
# Usage:
#   scripts/scaffold.sh compose <name> [port] [category]
#   scripts/scaffold.sh kind <name> [category]
#   scripts/scaffold.sh site <name> [port]

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
  # Running from the skillrunner container (mounted at /infra) or from _infra on host
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  # Fallback: assume relative to script location
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ── Load environment ──
if [ -f "${PROJECT_DIR}/.env.defaults" ]; then
  set -a
  source "${PROJECT_DIR}/.env.defaults"
  [ -f "${PROJECT_DIR}/.env" ] && source "${PROJECT_DIR}/.env"
  set +a
fi

TEMPLATE_DIR="${PROJECT_DIR}/${TEMPLATES_RELPATH:-templates}"
PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/Projects}"

# ──────────────────────────────────────────────
# Compose project
# ──────────────────────────────────────────────

cmd_compose() {
  local name="" port="3000" category=""

  # When --project-dir is given, derive everything from the path
  if [ -n "$project_dir" ]; then
    name="$(basename "$project_dir")"
    category="$(basename "$(dirname "$project_dir")")"
    port="${1:-3000}"
  else
    if [ $# -lt 1 ]; then
      echo "Usage: $(basename "$0") compose <name> [port] [category]"
      echo "  name      Project name (also becomes the domain: name.jorpo.loco)"
      echo "  port      Container port to expose (default: 3000)"
      echo "  category  Subfolder under ~/Projects/ (default: inferred from PWD)"
      echo ""
      echo "Or with --project-dir (flags before subcommand):"
      echo "  $(basename "$0") --project-dir /projects/<category>/<name> compose [port]"
      exit 1
    fi
    name="$1"
    port="${2:-3000}"
    category="${3:-}"
  fi

  # Determine category
  if [ -z "$category" ]; then
    local current_dir
    current_dir=$(pwd)
    # Check if we're inside a category folder under ~/Projects/
    if [[ "$current_dir" == "$PROJECTS_DIR"/* ]]; then
      category=$(echo "$current_dir" | sed "s|${PROJECTS_DIR}/||" | cut -d'/' -f1)
    else
      echo "  Could not determine category. Specify it or run from ~/Projects/<category>/"
      echo "  Usage: $(basename "$0") compose <name> [port] [category]"
      exit 1
    fi
  fi

  # project_dir is the global var set by --project-dir flag.
  # If not already set, construct it from PROJECTS_DIR + category + name.
  if [ -z "$project_dir" ]; then
    project_dir="${PROJECTS_DIR}/${category}/${name}"
  fi
  local compose_file="${project_dir}/compose.yaml"

  echo "═══ Scaffolding Compose Project: ${name} ═══"
  echo ""

  # Check if already exists
  if [ -f "$compose_file" ]; then
    echo "  ✗ compose.yaml already exists at ${compose_file}"
    exit 1
  fi

  # Create project directory
  mkdir -p "$project_dir"

  # Generate compose.yaml from template
  if [ -f "${TEMPLATE_DIR}/compose.yml" ]; then
    cat "${TEMPLATE_DIR}/compose.yml" \
      | sed "s/{{project_name}}/${name}/g" \
      | sed "s/{{port}}/${port}/g" \
      > "$compose_file"
    echo "  ✓ Created: ${compose_file}"
  else
    echo "  ✗ Template not found at ${TEMPLATE_DIR}/compose.yml"
    echo "  Creating minimal compose.yaml..."
    cat > "$compose_file" <<YAML
services:
  ${name}:
    build: .
    networks:
      - loco-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${name}.rule=Host(\`${name}.jorpo.loco\`)"
      - "traefik.http.routers.${name}.entrypoints=web"
      - "traefik.http.services.${name}.loadbalancer.server.port=${port}"
      - "traefik.docker.network=loco-net"

networks:
  loco-net:
    external: true
YAML
    echo "  ✓ Created (minimal): ${compose_file}"
  fi

  # Create .gitignore
  if [ ! -f "${project_dir}/.gitignore" ]; then
    cat > "${project_dir}/.gitignore" <<EOF
.DS_Store
node_modules/
vendor/
.env
*.log
EOF
    echo "  ✓ Created: ${project_dir}/.gitignore"
  fi

  echo ""
  echo "═══ Project '${name}' scaffolded ═══"
  echo "  Location: ${project_dir}"
  echo "  Domain:   http://${name}.jorpo.loco"
  echo "  Start:    cd ${project_dir} && docker compose up -d"
}

# ──────────────────────────────────────────────
# Kind project
# ──────────────────────────────────────────────

cmd_kind() {
  local name="" category=""

  if [ -n "$project_dir" ]; then
    name="$(basename "$project_dir")"
    category="$(basename "$(dirname "$project_dir")")"
  else
    if [ $# -lt 1 ]; then
      echo "Usage: $(basename "$0") kind <name> [category]"
      echo "  name      Cluster name (also becomes the domain: *.name.jorpo.loco)"
      echo "  category  Subfolder under ~/Projects/ (default: inferred from PWD)"
      echo ""
      echo "Or with --project-dir (flags before subcommand):"
      echo "  $(basename "$0") --project-dir /projects/<category>/<name> kind"
      exit 1
    fi
    name="$1"
    category="${2:-}"

    # Determine category
    if [ -z "$category" ]; then
      local current_dir
      current_dir=$(pwd)
      if [[ "$current_dir" == "$PROJECTS_DIR"/* ]]; then
        category=$(echo "$current_dir" | sed "s|${PROJECTS_DIR}/||" | cut -d'/' -f1)
      else
        echo "  Could not determine category. Specify it or run from ~/Projects/<category>/"
        echo "  Usage: $(basename "$0") kind <name> [category]"
        exit 1
      fi
    fi

    project_dir="${PROJECTS_DIR}/${category}/${name}"
  fi

  local kind_config="${project_dir}/kind-config.yaml"

  echo "═══ Scaffolding Kind Project: ${name} ═══"
  echo ""

  # Check if already exists
  if [ -f "$kind_config" ]; then
    echo "  ✗ kind-config.yaml already exists at ${kind_config}"
    exit 1
  fi

  # Create project directory
  mkdir -p "$project_dir"

  # Generate kind-config.yaml from template
  if [ -f "${TEMPLATE_DIR}/kind-config.yaml" ]; then
    # We can't fill ports yet — those are allocated at creation time
    # Write a placeholder and let the user run 'just kind-create'
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
  echo "  Next:     cd ${project_dir} && just kind-create ${name}  (from _infra/)"
}

# ──────────────────────────────────────────────
# Site project
# ──────────────────────────────────────────────

cmd_site() {
  local name="" port="80"

  if [ -n "$project_dir" ]; then
    name="$(basename "$project_dir")"
    port="${1:-80}"
  else
    if [ $# -lt 1 ]; then
      echo "Usage: $(basename "$0") site <name> [port]"
      echo "  name      Site name (becomes the domain: name.loco)"
      echo "  port      Container port to expose (default: 80)"
      echo ""
      echo "Or with --project-dir (flags before subcommand):"
      echo "  $(basename "$0") --project-dir /projects/sites/<name> site [port]"
      exit 1
    fi
    name="$1"
    port="${2:-80}"
    project_dir="${PROJECTS_DIR}/sites/${name}"
  fi

  local compose_file="${project_dir}/compose.yaml"

  echo "═══ Scaffolding Site: ${name} ═══"
  echo ""

  # Check if already exists
  if [ -f "$compose_file" ]; then
    echo "  ✗ compose.yaml already exists at ${compose_file}"
    exit 1
  fi

  # Create project directory
  mkdir -p "$project_dir"

  # Generate compose.yaml
  cat > "$compose_file" <<YAML
services:
  ${name}:
    build: .
    networks:
      - ${LOCO_NETWORK_NAME:-loco}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${name}.rule=Host(\`${name}.loco\`)"
      - "traefik.http.routers.${name}.entrypoints=web"
      - "traefik.http.services.${name}.loadbalancer.server.port=${port}"
      - "traefik.docker.network=${LOCO_NETWORK_NAME:-loco}"

networks:
  ${LOCO_NETWORK_NAME:-loco}:
    external: true
YAML
  echo "  ✓ Created: ${compose_file}"

  echo ""
  echo "═══ Site '${name}' scaffolded ═══"
  echo "  Location: ${project_dir}"
  echo "  Domain:   http://${name}.loco"
  echo "  Start:    cd ${project_dir} && docker compose up -d"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command> [args]"
  echo ""
  echo "Commands:"
  echo "  compose <name> [port] [category]    Scaffold a Docker Compose project"
  echo "  kind <name> [category]              Scaffold a kind cluster project"
  echo "  site <name> [port]                  Scaffold a site project (uses .loco TLD)"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    compose) cmd_compose "$@" ;;
    kind)    cmd_kind "$@" ;;
    site)    cmd_site "$@" ;;
    *)       usage ;;
  esac
}

main "$@"