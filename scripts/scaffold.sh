#!/usr/bin/env bash
# scripts/scaffold.sh — Register projects with the infra Traefik router
#
# All project types use the same Traefik file provider template.
# SSL mode determines whether Traefik terminates HTTPS or passthroughs to the backend.
#
# Usage:
#   scripts/scaffold.sh register --name <name> --domain <suffix> [options]
#
# Required:
#   --name <name>        Project/service name (also used as container name for compose/site)
#   --domain <suffix>    Domain suffix, e.g. .loco
#
# Options:
#   --path <path>        Project filesystem path (creates directory if not exists)
#   --host <host>        Backend hostname (default: same as --name)
#   --http-port <port>   HTTP backend port (default: 80)
#   --tls-port <port>    TLS backend port (default: same as --http-port)
#   --ssl <mode>         SSL mode (off by default): 'terminate' (Traefik terminates HTTPS)
#                        or 'passthrough' (TLS forwarded directly to backend)

set -euo pipefail

# ── Optional flags (before subcommand) ──
infra_dir=""
while [[ $# -gt 0 && "$1" == --* && "$1" != --name && "$1" != --domain && "$1" != --path && "$1" != --host && "$1" != --http-port && "$1" != --tls-port && "$1" != --ssl ]]; do
  case "$1" in
    --infra-dir) shift; infra_dir="$1"; shift ;;
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
TRAEFIK_CONFIG_DIR="${PROJECT_DIR}/${TRAEFIK_CONFIG_SUBDIR:-etc/traefik/configs}"

# ──────────────────────────────────────────────
# Register
# ──────────────────────────────────────────────

cmd_register() {
  local name="" domain="" project_path="" host="" http_port="80" tls_port="" ssl_mode=""

  # Parse named arguments (after the subcommand)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)       shift; name="$1" ;;
      --domain)     shift; domain="$1" ;;
      --path)       shift; project_path="$1" ;;
      --host)       shift; host="$1" ;;
      --http-port)  shift; http_port="$1" ;;
      --tls-port)   shift; tls_port="$1" ;;
      --ssl)        shift; ssl_mode="$1" ;;
      *)            echo "  ✗ Unknown option: $1"; exit 1 ;;
    esac
    shift
  done

  # Validate
  if [ -z "$name" ]; then echo "  ✗ --name is required"; exit 1; fi
  if [ -z "$domain" ]; then echo "  ✗ --domain is required"; exit 1; fi

  # Defaults
  host="${host:-$name}"
  tls_port="${tls_port:-$http_port}"

  local traefik_file="${TRAEFIK_CONFIG_DIR}/${name}.yml"

  echo "═══ Registering ${name} ═══"
  echo "  Domain:     *${name}${domain} → ${name}${domain}"
  echo "  Host:       ${host}"
  echo "  HTTP port:  ${http_port}"
  echo "  TLS port:   ${tls_port}"
  echo "  SSL mode:   ${ssl_mode:-none}"

  # Create project directory if path provided
  if [ -n "$project_path" ]; then
    mkdir -p "$project_path"
    echo "  Path:       ${project_path}"
  fi

  echo ""

  if [ -f "$traefik_file" ]; then
    echo "  ✗ Traefik config already exists at ${traefik_file}"
    exit 1
  fi

  mkdir -p "$TRAEFIK_CONFIG_DIR"

  local template_name=""
  case "${ssl_mode}" in
    "")          template_name="traefik-http-only.yml" ;;
    terminate)   template_name="traefik-terminate.yml" ;;
    passthrough) template_name="traefik-passthrough.yml" ;;
    *)
      echo "  ✗ Unknown SSL mode: ${ssl_mode} (use 'terminate' or 'passthrough')"
      exit 1
      ;;
  esac

  local template_file="${TEMPLATE_DIR}/${template_name}"
  if [ ! -f "$template_file" ]; then
    echo "  ✗ Template not found: ${template_file}"
    exit 1
  fi

  cat "$template_file" \
    | sed "s/{{name}}/${name}/g" \
    | sed "s/{{domain}}/${domain}/g" \
    | sed "s/{{host}}/${host}/g" \
    | sed "s/{{http_port}}/${http_port}/g" \
    | sed "s/{{tls_port}}/${tls_port}/g" \
    | sed "s|{{project_path}}|${project_path}|g" \
    > "$traefik_file"

  case "${ssl_mode}" in
    "")          echo "  ✓ No SSL (HTTP only)" ;;
    terminate)
      echo "  ✓ SSL terminate (Traefik handles HTTPS, forwards HTTP to backend)"

      # ── Generate TLS certs with mkcert ──
      CERTS_DIR="${PROJECT_DIR}/${CERTS_RELPATH:-etc/certs}"
      mkdir -p "$CERTS_DIR"

      mkcert -cert-file "${CERTS_DIR}/${name}.crt" \
             -key-file "${CERTS_DIR}/${name}.key" \
             "${name}${domain}" "*.${name}${domain}"

      echo "  ✓ TLS certs: ${CERTS_DIR}/${name}.{crt,key}"

      # ── Write TLS cert registration (auto-matched by Traefik) ──
      local cert_tpl="${TEMPLATE_DIR}/tls-cert.yml"
      if [ -f "$cert_tpl" ]; then
        cat "$cert_tpl" \
          | sed "s/{{name}}/${name}/g" \
          > "${TRAEFIK_CONFIG_DIR}/_certs-${name}.yml"
        echo "  ✓ Cert reg:  ${TRAEFIK_CONFIG_DIR}/_certs-${name}.yml"
      fi
      ;;
    passthrough) echo "  ✓ SSL passthrough (Traefik forwards TLS directly to backend)" ;;
  esac

  echo "  ✓ Created: ${traefik_file}"
  echo ""
  echo "═══ ${name} registered ═══"
  echo "  Domain:   http://${name}${domain}"
  echo "  Traefik:  ${traefik_file}"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") register [options]"
  echo ""
  echo "Required:"
  echo "  --name <name>      Project/service name"
  echo "  --domain <suffix>  Domain suffix (e.g. .loco)"
  echo ""
  echo "Options:"
  echo "  --path <path>       Project filesystem path (creates directory if not exists)"
  echo "  --host <host>       Backend hostname (default: same as --name)"
  echo "  --http-port <port>  HTTP backend port (default: 80)"
  echo "  --tls-port <port>   TLS backend port (default: same as --http-port)"
  echo "  --ssl <mode>        SSL mode: terminate or passthrough (default: no SSL)"
  echo ""
  echo "  --infra-dir <path>  Explicit infra root path (before subcommand)"
  echo ""
  echo "Examples:"
  echo "  scaffold.sh register --name myapp --domain .loco --http-port 3000                      # HTTP only"
  echo "  scaffold.sh register --name myapp --domain .loco --http-port 3000 --ssl terminate          # HTTP + HTTPS"
  echo "  scaffold.sh register --name blog --domain .loco --http-port 80"
  echo "  scaffold.sh register --name mycluster --domain .loco --host host.docker.internal --http-port 30080 --tls-port 30443 --ssl passthrough"
  echo "  scaffold.sh register --name myapp --domain .loco --path /projects/myapp --http-port 3000"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    register) cmd_register "$@" ;;
    *)        usage ;;
  esac
}

main "$@"