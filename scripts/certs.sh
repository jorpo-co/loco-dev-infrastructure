#!/usr/bin/env bash
# scripts/certs.sh — mkcert root CA lifecycle (runs on host)
#
# Creates the local dev root CA in etc/certs/ca/ and installs it into the
# host trust store (Chrome/Safari via security, Firefox via certutil/nss).
# Idempotent — safe to re-run.

set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/certs/ca"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="${INFRA_DIR}/etc/certs"
CONFIG_DIR="${INFRA_DIR}/etc/traefik/configs"

# ──────────────────────────────────────────────
# Install CA
# ──────────────────────────────────────────────

cmd_install() {
  mkdir -p "${CERT_DIR}"

  # certutil (from nss) is needed for Firefox trust — install if missing
  if ! command -v certutil &>/dev/null; then
    if command -v brew &>/dev/null; then
      echo "  Installing nss (certutil for Firefox trust)..."
      brew install nss >/dev/null 2>&1 || echo "  ⚠ nss install failed — Firefox won't trust the CA automatically"
    else
      echo "  ⚠ brew not found — Firefox won't trust the CA automatically"
    fi
  fi

  CAROOT="${CERT_DIR}" mkcert -install
  echo "  ✓ mkcert CA ready in ${CERT_DIR}"
  echo "  ✓ CA installed in host trust store"
}

# ──────────────────────────────────────────────
# Remove CA
# ──────────────────────────────────────────────

cmd_uninstall() {
  CAROOT="${CERT_DIR}" mkcert -uninstall
  rm -rf "${CERT_DIR}"
  echo "  ✓ mkcert CA removed from host trust store and ${CERT_DIR}"
}

# ──────────────────────────────────────────────
# Status
# ──────────────────────────────────────────────

cmd_status() {
  if [ -f "${CERT_DIR}/rootCA.pem" ] && [ -f "${CERT_DIR}/rootCA-key.pem" ]; then
    echo "  ✓ mkcert CA present: ${CERT_DIR}"
  else
    echo "  ✗ mkcert CA missing — run: just certs-init"
    exit 1
  fi
}

# ──────────────────────────────────────────────
# Infra service certs (registry.loco, traefik.loco)
# ──────────────────────────────────────────────

cmd_infra() {
  mkdir -p "${CERTS_DIR}"

  CAROOT="${CERT_DIR}" mkcert \
    -cert-file "${CERTS_DIR}/loco-infra.crt" \
    -key-file "${CERTS_DIR}/loco-infra.key" \
    registry.loco traefik.loco infra.loco

  cat > "${CONFIG_DIR}/_certs-loco-infra.yml" <<'EOF'
tls:
  certificates:
    - certFile: /certs/loco-infra.crt
      keyFile: /certs/loco-infra.key
EOF

  echo "  ✓ Infra certs: ${CERTS_DIR}/loco-infra.{crt,key}"
  echo "  ✓ Cert reg:    ${CONFIG_DIR}/_certs-loco-infra.yml"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") {install|uninstall|status|infra}"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  case "$1" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    infra)     cmd_infra ;;
    *)         usage ;;
  esac
}

main "$@"
