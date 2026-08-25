#!/usr/bin/env bash
# scripts/skills.sh — Install, verify, and remove agent skill symlinks
#
# Symlinks skills/loco-{infra,project,kind} → ~/.pi/skills/
# All operations are idempotent — safe to re-run.
#
# Usage:
#   scripts/skills.sh install     Symlink skills → ~/.pi/skills/
#   scripts/skills.sh status      Show current skill symlinks
#   scripts/skills.sh uninstall   Remove skill symlinks

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

SKILLS_SRC="${PROJECT_DIR}/skills"
SKILLS_TARGET="${HOME}/.pi/skills"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

_skill_list() {
  for dir in "${SKILLS_SRC}"/*/; do
    basename "$dir"
  done
}

_skill_symlink_path() {
  echo "${SKILLS_TARGET}/$1"
}

_symlink_valid() {
  local name="$1"
  local target
  target="$(_skill_symlink_path "$name")"
  [ -L "$target" ] && [ "$(readlink "$target")" = "${SKILLS_SRC}/${name}" ]
}

# ──────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────

cmd_install() {
  echo "═══ Installing Agent Skills ═══"
  echo ""

  mkdir -p "$SKILLS_TARGET"

  local count=0
  for dir in "${SKILLS_SRC}"/*/; do
    local name
    name="$(basename "$dir")"
    local target
    target="$(_skill_symlink_path "$name")"

    if _symlink_valid "$name"; then
      echo "  ✓ ${name} already linked"
    elif [ -L "$target" ]; then
      # Wrong symlink target — replace
      rm "$target"
      ln -s "${SKILLS_SRC}/${name}" "$target"
      echo "  ✓ ${name} relinked"
    elif [ -d "$target" ]; then
      echo "  ⚠ ${name} exists as directory at ${target} — skipping"
    else
      ln -s "${SKILLS_SRC}/${name}" "$target"
      echo "  ✓ Linked: ~/.pi/skills/${name} → ${SKILLS_SRC}/${name}"
    fi
    count=$((count + 1))
  done

  echo ""
  echo "═══ ${count} skills installed ═══"
}

# ──────────────────────────────────────────────
# Status
# ──────────────────────────────────────────────

cmd_status() {
  echo "═══ Agent Skills Status ═══"
  echo ""

  echo "  Source: ${SKILLS_SRC}"
  echo "  Target: ${SKILLS_TARGET}"
  echo ""

  local all_ok=true
  for dir in "${SKILLS_SRC}"/*/; do
    local name
    name="$(basename "$dir")"
    local target
    target="$(_skill_symlink_path "$name")"

    if _symlink_valid "$name"; then
      echo "  ✓ ${name} → ~/.pi/skills/${name}"
    elif [ -L "$target" ]; then
      local current
      current="$(readlink "$target")"
      echo "  ⚠ ${name}: symlinks to ${current}, expected ${SKILLS_SRC}/${name}"
      all_ok=false
    elif [ -d "$target" ]; then
      echo "  ⚠ ${name}: exists as directory at ${target}"
      all_ok=false
    elif [ -e "$target" ]; then
      echo "  ⚠ ${name}: exists as file at ${target}"
      all_ok=false
    else
      echo "  ✗ ${name}: no symlink found at ${target}"
      all_ok=false
    fi
  done

  echo ""
  if $all_ok; then
    echo "  All skills properly linked."
  else
    echo "  Run 'just skills-install' to fix."
  fi
  echo "═══ Skills status complete ═══"
}

# ──────────────────────────────────────────────
# Uninstall
# ──────────────────────────────────────────────

cmd_uninstall() {
  echo "═══ Uninstalling Agent Skills ═══"
  echo "  Only symlinks are removed. Source files in _infra/skills/ are kept."
  echo ""

  local count=0
  for dir in "${SKILLS_SRC}"/*/; do
    local name
    name="$(basename "$dir")"
    local target
    target="$(_skill_symlink_path "$name")"

    if [ -L "$target" ]; then
      rm "$target"
      echo "  ✓ Removed ~/.pi/skills/${name}"
      count=$((count + 1))
    elif [ -d "$target" ]; then
      echo "  ⚠ ~/.pi/skills/${name} is a directory — not removed"
    else
      echo "  - ~/.pi/skills/${name} not found"
    fi
  done

  echo ""
  echo "═══ ${count} symlinks removed ═══"
  echo "  Reinstall anytime with: just skills-install"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command>"
  echo ""
  echo "Commands:"
  echo "  install     Symlink skills → ~/.pi/skills/ (idempotent)"
  echo "  status      Show current skill symlinks"
  echo "  uninstall   Remove skill symlinks (keeps source files)"
  exit 1
}

main() {
  if [ $# -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    install)   cmd_install "$@" ;;
    status)    cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    *)         usage ;;
  esac
}

main "$@"