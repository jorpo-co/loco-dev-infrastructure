#!/usr/bin/env bash
# scripts/registry.sh — Registry helpers
#
# Usage:
#   scripts/registry.sh push <image> [tag]    Tag and push image to registry.loco
#   scripts/registry.sh list                   List repositories
#   scripts/registry.sh clean                  Garbage collect

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

REGISTRY_HOST="${REGISTRY_HOST:-registry.loco}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_DIRECT="localhost:${REGISTRY_PORT}"

# ──────────────────────────────────────────────
# Push
# ──────────────────────────────────────────────

cmd_push() {
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") push <image> [tag]"
    echo "  image  Local image name or Dockerfile path"
    echo "  tag    Tag to use (default: latest)"
    exit 1
  fi

  local image="$1"
  local tag="${2:-latest}"
  local remote="${REGISTRY_HOST}/${image}:${tag}"

  echo "═══ Pushing ${image}:${tag} → ${remote} ═══"
  echo ""

  # Check if it's a local image or needs building
  if docker image inspect "${image}:${tag}" &>/dev/null; then
    echo "  Using existing image: ${image}:${tag}"
  elif docker image inspect "${image}:latest" &>/dev/null; then
    echo "  Using existing image: ${image}:latest"
    tag="latest"
    remote="${REGISTRY_HOST}/${image}:latest"
  elif [ -f "Dockerfile" ] || [ -f "dockerfile" ]; then
    echo "  Building image from Dockerfile..."
    docker build -t "${image}:${tag}" .
  else
    echo "✗ Image '${image}:${tag}' not found and no Dockerfile in current directory"
    exit 1
  fi

  # Tag and push
  echo "  Tagging: ${remote}..."
  docker tag "${image}:${tag}" "${remote}"

  echo "  Pushing to ${REGISTRY_HOST}..."
  if docker push "${remote}"; then
    echo ""
    echo "  ✓ Pushed: ${remote}"
    echo "  Pull string: docker pull ${remote}"
    echo "  For kind: use localhost:${REGISTRY_PORT}/${image}:${tag}"
  else
    echo "✗ Push failed. Is the registry running?"
    exit 1
  fi
}

# ──────────────────────────────────────────────
# List
# ──────────────────────────────────────────────

cmd_list() {
  echo "═══ Registry Repositories ═══"
  echo ""

  local catalog
  catalog=$(curl -s "http://${REGISTRY_DIRECT}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')

  local repos
  repos=$(echo "$catalog" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('repositories', []):
    print(r)
" 2>/dev/null)

  if [ -z "$repos" ]; then
    echo "  (empty)"
  else
    echo "$repos" | while IFS= read -r repo; do
      local tags
      tags=$(curl -s "http://${REGISTRY_DIRECT}/v2/${repo}/tags/list" 2>/dev/null || echo '{"tags":[]}')
      local tag_list
      tag_list=$(echo "$tags" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tags = data.get('tags', [])
if tags:
    print(', '.join(tags))
else:
    print('(no tags)')
" 2>/dev/null)
      echo "  ${repo}: [${tag_list}]"
    done
  fi
}

# ──────────────────────────────────────────────
# Clean
# ──────────────────────────────────────────────

cmd_clean() {
  echo "═══ Registry Garbage Collection ═══"
  echo ""
  echo "  Note: Registry v2 supports GC on restart with REGISTRY_STORAGE_DELETE_ENABLED=true"
  echo "  This is already set in the compose.yml."
  echo ""
  echo "  To trigger garbage collection:"
  echo "    docker compose -f ${PROJECT_DIR}/compose.yml exec registry /bin/registry garbage-collect /etc/docker/registry/config.yml"
  echo ""
  echo "  Or simply prune unused images from the host:"
  echo "    docker image prune -a"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command> [args]"
  echo ""
  echo "Commands:"
  echo "  push <image> [tag]    Tag and push image to registry.loco"
  echo "  list                  List repositories"
  echo "  clean                 Garbage collection info"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    push)  cmd_push "$@" ;;
    list)  cmd_list "$@" ;;
    clean) cmd_clean "$@" ;;
    *)     usage ;;
  esac
}

main "$@"