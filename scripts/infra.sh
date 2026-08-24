#!/usr/bin/env bash
# scripts/infra.sh — Manage the _infra/ Docker Compose stack
#
# All operations are idempotent.
#
# Usage:
#   scripts/infra.sh up       Start the stack
#   scripts/infra.sh down     Stop the stack
#   scripts/infra.sh status   Show stack status
#   scripts/infra.sh logs     Tail logs
#   scripts/infra.sh restart  Restart the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load environment ──
if [ -f "${PROJECT_DIR}/.env.defaults" ]; then
  set -a
  source "${PROJECT_DIR}/.env.defaults"
  [ -f "${PROJECT_DIR}/.env" ] && source "${PROJECT_DIR}/.env"
  set +a
fi

COMPOSE_FILE="${PROJECT_DIR}/compose.yml"

# ──────────────────────────────────────────────
# Commands
# ──────────────────────────────────────────────

cmd_up() {
  echo "═══ Starting Loco Infra Stack ═══"
  echo ""

  # Check prerequisites
  if ! docker info &>/dev/null; then
    echo "✗ Docker is not running. Please start Docker Desktop."
    exit 1
  fi

  # Check if compose file exists
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "✗ Compose file not found at ${COMPOSE_FILE}"
    exit 1
  fi

  echo "  Starting stack..."
  (cd "$PROJECT_DIR" && docker compose up -d)

  echo ""
  echo "  Waiting for services to be healthy..."
  sleep 3

  # Verify
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "loco-traefik"; then
    echo "  ✓ Traefik is running"
  else
    echo "  ✗ Traefik failed to start — check 'just logs'"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "loco-registry"; then
    echo "  ✓ Registry is running"
  else
    echo "  ✗ Registry failed to start — check 'just logs'"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "loco-registry-ui"; then
    echo "  ✓ Registry UI is running"
  else
    echo "  ✗ Registry UI failed to start — check 'just logs'"
  fi

  echo ""
  echo "═══ Stack is up ═══"
  echo "  Traefik dashboard: http://traefik.jorpo.loco"
  echo "  Registry:          http://registry.loco"
  echo "  Registry UI:       http://registry.loco (web interface)"
  echo "  Registry direct:   http://localhost:5001"
  echo "  Registry API:      http://registry.loco/v2/_catalog"
}

cmd_down() {
  echo "═══ Stopping Loco Infra Stack ═══"
  (cd "$PROJECT_DIR" && docker compose down)
  echo "  ✓ Stack stopped"
}

cmd_status() {
  echo "═══ Infra Stack Status ═══"
  echo ""
  (cd "$PROJECT_DIR" && docker compose ps)
  echo ""

  # Network check
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^loco$"; then
    echo "  Network: ✓ loco exists"
    echo "  Containers on loco:"
    docker network inspect loco --format '{{range .Containers}}{{.Name}} ({{.IPv4Address}}) {{end}}' 2>/dev/null || echo "    (none)"
  else
    echo "  Network: ✗ loco does not exist"
  fi
}

cmd_logs() {
  (cd "$PROJECT_DIR" && docker compose logs -f)
}

cmd_restart() {
  cmd_down
  echo ""
  cmd_up
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command>"
  echo ""
  echo "Commands:"
  echo "  up        Start the stack (idempotent)"
  echo "  down      Stop the stack"
  echo "  status    Show stack status"
  echo "  logs      Tail logs"
  echo "  restart   Restart the stack"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    status)  cmd_status "$@" ;;
    logs)    cmd_logs "$@" ;;
    restart) cmd_restart "$@" ;;
    *)       usage ;;
  esac
}

main "$@"
