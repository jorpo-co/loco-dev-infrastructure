#!/usr/bin/env bash
# scripts/scaffold.sh — Register new projects with the infra Traefik router
#
# Uses the file provider (etc/traefik/services/*.yml) instead of Docker labels.
# All types — compose, kind, site — use Traefik config stored in infra.
#
# Usage:
#   scripts/scaffold.sh compose <name> [port] [category]
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

TEMPLATE_DIR="${PROJECT_DIR}/${TEMPLATES_RELPATH:-templates}"
PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/Projects}"
TRAEFIK_CONFIG_DIR="${PROJECT_DIR}/${TRAEFIK_CONFIG_SUBDIR:-etc/traefik/services}"

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
    if [[ "$current_dir" == "$PROJECTS_DIR"/* ]]; then
      category=$(echo "$current_dir" | sed "s|${PROJECTS_DIR}/||" | cut -d'/' -f1)
    else
      echo "  Could not determine category. Specify it or run from ~/Projects/<category>/"
      echo "  Usage: $(basename "$0") compose <name> [port] [category]"
      exit 1
    fi
  fi

  local traefik_file="${TRAEFIK_CONFIG_DIR}/${name}.yml"

  echo "═══ Registering Compose Project: ${name} ═══"
  echo ""

  # Check if already exists
  if [ -f "$traefik_file" ]; then
    echo "  ✗ Traefik config already exists at ${traefik_file}"
    exit 1
  fi

  mkdir -p "$TRAEFIK_CONFIG_DIR"

  # Generate Traefik file provider config from template
  if [ -f "${TEMPLATE_DIR}/compose-traefik.yml" ]; then
    cat "${TEMPLATE_DIR}/compose-traefik.yml" \
      | sed "s/{{name}}/${name}/g" \
      | sed "s/{{host}}/${name}/g" \
      | sed "s/{{port}}/${port}/g" \
      | sed "s/{{domain_suffix}}/.jorpo.loco/g" \
      > "$traefik_file"
    echo "  ✓ Created: ${traefik_file}"
  else
    echo "  ✗ Template not found at ${TEMPLATE_DIR}/compose-traefik.yml"
    cat > "$traefik_file" <<YAML
http:
  routers:
    ${name}:
      rule: "HostRegexp(\`{subdomain:.+}.${name}.jorpo.loco\`) || Host(\`${name}.jorpo.loco\`)"
      entryPoints: ["web"]
      service: ${name}
    ${name}-secure:
      rule: "HostRegexp(\`{subdomain:.+}.${name}.jorpo.loco\`) || Host(\`${name}.jorpo.loco\`)"
      entryPoints: ["websecure"]
      service: ${name}
      tls: {}
  services:
    ${name}:
      loadBalancer:
        servers:
          - url: "http://${name}:${port}"
YAML
    echo "  ✓ Created (minimal): ${traefik_file}"
  fi

  echo ""
  echo "═══ Project '${name}' registered ═══"
  echo "  Domain:   http://${name}.jorpo.loco"
  echo "  Traefik:  ${traefik_file}"
  echo ""
  echo "  ── Next steps ──"
  echo "  1. Add to your project's compose.yaml:"
  echo "       networks:"
  echo "         - loco"
  echo "  2. Add the external network:"
  echo "       networks:"
  echo "         loco:"
  echo "           external: true"
  echo "  3. Ensure your container is named '${name}' or use container_name: ${name}"
  echo "  4. Start: docker compose up -d"
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
  fi

  local traefik_file="${TRAEFIK_CONFIG_DIR}/${name}.yml"

  echo "═══ Registering Site: ${name} ═══"
  echo ""

  # Check if already exists
  if [ -f "$traefik_file" ]; then
    echo "  ✗ Traefik config already exists at ${traefik_file}"
    exit 1
  fi

  mkdir -p "$TRAEFIK_CONFIG_DIR"

  # Generate Traefik file provider config from template
  if [ -f "${TEMPLATE_DIR}/compose-traefik.yml" ]; then
    cat "${TEMPLATE_DIR}/compose-traefik.yml" \
      | sed "s/{{name}}/${name}/g" \
      | sed "s/{{host}}/${name}/g" \
      | sed "s/{{port}}/${port}/g" \
      | sed "s/{{domain_suffix}}/.loco/g" \
      > "$traefik_file"
    echo "  ✓ Created: ${traefik_file}"
  else
    cat > "$traefik_file" <<YAML
http:
  routers:
    ${name}:
      rule: "HostRegexp(\`{subdomain:.+}.${name}.loco\`) || Host(\`${name}.loco\`)"
      entryPoints: ["web"]
      service: ${name}
    ${name}-secure:
      rule: "HostRegexp(\`{subdomain:.+}.${name}.loco\`) || Host(\`${name}.loco\`)"
      entryPoints: ["websecure"]
      service: ${name}
      tls: {}
  services:
    ${name}:
      loadBalancer:
        servers:
          - url: "http://${name}:${port}"
YAML
    echo "  ✓ Created (minimal): ${traefik_file}"
  fi

  echo ""
  echo "═══ Site '${name}' registered ═══"
  echo "  Domain:   http://${name}.loco"
  echo "  Traefik:  ${traefik_file}"
  echo ""
  echo "  ── Next steps ──"
  echo "  1. Add to your site's compose.yaml:"
  echo "       networks:"
  echo "         - loco"
  echo "  2. Add the external network:"
  echo "       networks:"
  echo "         loco:"
  echo "           external: true"
  echo "  3. Ensure your container is named '${name}' or use container_name: ${name}"
  echo "  4. Start: docker compose up -d"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command> [args]"
  echo ""
  echo "Commands:"
  echo "  compose <name> [port] [category]    Register a Docker Compose project with Traefik"
  echo "  site <name> [port]                  Register a site project (uses .loco TLD) with Traefik"
  echo ""
  echo "All types use Traefik file provider config stored in etc/traefik/services/."
  echo "No Docker labels or loco.compose.yaml files are generated."
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
    site)    cmd_site "$@" ;;
    *)       usage ;;
  esac
}

main "$@"