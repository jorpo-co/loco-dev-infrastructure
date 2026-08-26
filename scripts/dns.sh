#!/usr/bin/env bash
# scripts/dns.sh — Install, verify, and remove local wildcard DNS for *.loco
#
# Uses Homebrew dnsmasq + macOS resolver files + a dedicated loopback alias (10.254.254.254).
# Config files live in _infra/etc/dns/ and are symlinked to system locations.
# All operations are idempotent — safe to re-run.
#
# Usage:
#   scripts/dns.sh install     Install dnsmasq, configure, create resolver
#   scripts/dns.sh status      Show current DNS configuration
#   scripts/dns.sh uninstall   Remove DNS configuration

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

# ── Config (env defaults, computed paths) ──
LOOPBACK_IP="${LOOPBACK_IP:-10.254.254.254}"
LOOPBACK_INTERFACE="${LOOPBACK_INTERFACE:-lo0}"
PLIST_LABEL="${DNS_PLIST_LABEL:-com.loco.infra}"

# Source files (in etc/dns/)
DNS_DIR="${PROJECT_DIR}/etc/dns"
DNSMASQ_CONF_SRC="${DNS_DIR}/dnsmasq.conf"
RESOLVER_DIR_SRC="${DNS_DIR}/resolver"
PLIST_SRC="${DNS_DIR}/com.loco.infra.plist"

# System target locations — detect Homebrew prefix for ARM/Intel compat
if [ -x /opt/homebrew/bin/brew ]; then
  BREW_PREFIX="/opt/homebrew"
elif [ -x /usr/local/bin/brew ]; then
  BREW_PREFIX="/usr/local"
else
  echo "  ⚠ Homebrew not found at /opt/homebrew or /usr/local" >&2
  BREW_PREFIX="/usr/local"
fi
DNSMASQ_CONF_DIR="${BREW_PREFIX}/etc/dnsmasq.d"
DNSMASQ_CONF_LINK="${DNSMASQ_CONF_DIR}/loco.conf"
RESOLVER_DIR="/etc/resolver"
PLIST_TARGET="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
read -ra TLDS <<< "${DNS_TLDS:-loco}"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

_has_loopback_alias() {
  ifconfig "$LOOPBACK_INTERFACE" 2>/dev/null | grep -q "$LOOPBACK_IP"
}

_has_brew_dnsmasq() {
  # Check the dnsmasq binary directly — avoids calling `brew` which
  # always runs `sudo --reset-timestamp` (Homebrew/brew.sh) and kills
  # the cached sudo credential mid-install.
  [ -x "${BREW_PREFIX}/opt/dnsmasq/sbin/dnsmasq" ]
}

_resolver_symlink_valid() {
  local tld="$1"
  [ -L "${RESOLVER_DIR}/${tld}" ] && \
    [ "$(readlink "${RESOLVER_DIR}/${tld}")" = "${RESOLVER_DIR_SRC}/${tld}" ]
}

_dnsmasq_symlink_valid() {
  [ -L "$DNSMASQ_CONF_LINK" ] && \
    [ "$(readlink "$DNSMASQ_CONF_LINK")" = "$DNSMASQ_CONF_SRC" ]
}

_plist_installed() {
  [ -f "$PLIST_TARGET" ] && [ "$(stat -f%u "$PLIST_TARGET")" = "0" ] && \
    diff -q "$PLIST_SRC" "$PLIST_TARGET" &>/dev/null
}

# ──────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────

cmd_install() {
  echo "═══ Installing Loco DNS ═══"
  echo ""

  # Establish sudo session once (cached for 5 min)
  echo "  Establishing sudo session..."
  sudo -v
  echo "  ✓ Sudo session ready"
  echo ""

  # ── Step 1: Loopback alias ──
  echo "── Step 1: Loopback alias ──"
  if _has_loopback_alias; then
    echo "  ✓ Loopback alias ${LOOPBACK_IP} already exists on ${LOOPBACK_INTERFACE}"
  else
    echo "  Creating loopback alias ${LOOPBACK_IP} on ${LOOPBACK_INTERFACE}..."
    sudo ifconfig "$LOOPBACK_INTERFACE" alias "$LOOPBACK_IP"
    echo "  ✓ Created"
  fi
  echo ""

  # ── Step 2: Install launch daemon plist ──
  # launchd requires a real root-owned file, NOT a symlink to a user file
  echo "── Step 2: Launch daemon (persistent across reboots) ──"
  if _plist_installed; then
    echo "  ✓ Plist already installed"
  else
    echo "  Installing plist as root-owned file..."
    sudo cp "$PLIST_SRC" "$PLIST_TARGET"
    sudo chown root:wheel "$PLIST_TARGET"
    sudo chmod 644 "$PLIST_TARGET"
    echo "  ✓ Installed"
  fi

  # Load the daemon — best-effort (alias is set in Step 1 regardless)
  echo "  Loading launch daemon..."
  if sudo launchctl print system/"${PLIST_LABEL}" &>/dev/null; then
    echo "  ✓ Already loaded"
  else
    sudo launchctl bootout system/"${PLIST_LABEL}" 2>/dev/null || true
    if sudo launchctl bootstrap system "$PLIST_TARGET" 2>/dev/null; then
      echo "  ✓ Loaded"
    elif sudo launchctl load "$PLIST_TARGET" 2>/dev/null; then
      echo "  ✓ Loaded (legacy)"
    else
      echo "  ⚠ Could not load launch daemon (loopback alias will not survive reboot)"
      echo "    Run 'sudo launchctl load ${PLIST_TARGET}' after reboot"
    fi
  fi
  echo ""

  # ── Step 3: macOS resolver files ──
  echo "── Step 3: macOS resolver files ──"
  sudo mkdir -p "$RESOLVER_DIR"
  for tld in "${TLDS[@]}"; do
    if ! _resolver_symlink_valid "$tld"; then
      if [ -f "${RESOLVER_DIR}/${tld}" ] || [ -L "${RESOLVER_DIR}/${tld}" ]; then
        sudo rm -f "${RESOLVER_DIR}/${tld}"
      fi
      echo "  Symlinking ${RESOLVER_DIR_SRC}/${tld} → ${RESOLVER_DIR}/${tld}..."
      sudo ln -s "${RESOLVER_DIR_SRC}/${tld}" "${RESOLVER_DIR}/${tld}"
      echo "  ✓ Created"
    else
      echo "  ✓ Resolver for .${tld} already linked"
    fi
  done
  echo ""

  # ── Step 4: dnsmasq ──
  echo "── Step 4: dnsmasq ──"
  if _has_brew_dnsmasq; then
    echo "  ✓ dnsmasq already installed"
  else
    echo "  Installing dnsmasq via Homebrew..."
    brew install dnsmasq
    echo "  ✓ Installed"
  fi
  echo ""

  # ── Step 5: dnsmasq config ──
  echo "── Step 5: dnsmasq configuration ──"
  mkdir -p "$DNSMASQ_CONF_DIR"
  if ! _dnsmasq_symlink_valid; then
    # Remove any stale file or symlink
    if [ -f "$DNSMASQ_CONF_LINK" ] || [ -L "$DNSMASQ_CONF_LINK" ]; then
      rm -f "$DNSMASQ_CONF_LINK"
    fi
    echo "  Symlinking ${DNSMASQ_CONF_SRC} → ${DNSMASQ_CONF_LINK}..."
    ln -s "$DNSMASQ_CONF_SRC" "$DNSMASQ_CONF_LINK"
    echo "  ✓ Created"
  else
    echo "  ✓ Symlink already exists"
  fi
  echo ""

  # ── Step 6: Restart dnsmasq to pick up config changes ──
  echo "── Step 6: Restart dnsmasq ──"
  sudo brew services restart dnsmasq
  echo "  ✓ Restarted"
  sleep 1
  echo ""

  # ── Step 7: Verify ──
  echo "── Verification ──"
  local all_ok=true
  for tld in "${TLDS[@]}"; do
    local test_domain="test.${tld}"
    # Test via system resolver (same path browsers and apps use)
    if dscacheutil -q host -a name "$test_domain" 2>/dev/null | grep -q "$LOOPBACK_IP"; then
      echo "  ✓ ${test_domain} → ${LOOPBACK_IP}"
    else
      echo "  ⚠ ${test_domain} did not resolve via system resolver"
      all_ok=false
    fi
  done
  echo ""

  if $all_ok; then
    echo "═══ DNS installation complete ═══"
    echo "  Any *.loco domain now resolves to ${LOOPBACK_IP}"
    echo "  Traefik (on port 80/443 at ${LOOPBACK_IP}) will route traffic."
  else
    echo "═══ DNS installation failed ═══"
    echo "  dnsmasq may not be running. Check: pgrep -x dnsmasq"
  fi
}

# ──────────────────────────────────────────────
# Status
# ──────────────────────────────────────────────

cmd_status() {
  echo "═══ DNS Status ═══"
  echo ""

  echo "── Loopback alias ──"
  if _has_loopback_alias; then
    echo "  ✓ ${LOOPBACK_IP} on ${LOOPBACK_INTERFACE}"
  else
    echo "  ✗ No alias found"
  fi
  echo ""

  echo "── Launch daemon ──"
  if _plist_installed; then
    echo "  ✓ Plist installed as root-owned file"
    if sudo -n launchctl print system/"${PLIST_LABEL}" &>/dev/null; then
      echo "  ✓ Loaded"
    elif sudo -n true 2>/dev/null; then
      echo "  ⚠ Plist installed but not loaded"
    else
      echo "  ? Run 'just dns-install' to check and fix"
    fi
  elif [ -f "$PLIST_TARGET" ]; then
    echo "  ⚠ Plist exists but not owned by root — run 'just dns-install'"
  else
    echo "  ✗ Plist not installed"
  fi
  echo ""

  echo "── dnsmasq ──"
  if _has_brew_dnsmasq; then
    echo "  ✓ Installed"
    if pgrep -x dnsmasq &>/dev/null; then
      echo "  ✓ Running"
    else
      echo "  ⚠ Not running — run: just dns-install"
    fi
  else
    echo "  ✗ Not installed"
  fi
  echo ""

  echo "── dnsmasq config ──"
  if _dnsmasq_symlink_valid; then
    echo "  ✓ Symlink: ${DNSMASQ_CONF_SRC} → ${DNSMASQ_CONF_LINK}"
    cat "$DNSMASQ_CONF_LINK"
  elif [ -f "$DNSMASQ_CONF_LINK" ]; then
    echo "  ⚠ File exists at ${DNSMASQ_CONF_LINK} but is not a symlink to our source"
  else
    echo "  ✗ No config found"
  fi
  echo ""

  echo "── macOS resolvers ──"
  for tld in "${TLDS[@]}"; do
    if _resolver_symlink_valid "$tld"; then
      echo "  ✓ Symlink: ${RESOLVER_DIR_SRC}/${tld} → ${RESOLVER_DIR}/${tld}"
    elif [ -f "${RESOLVER_DIR}/${tld}" ]; then
      echo "  ⚠ File exists at ${RESOLVER_DIR}/${tld} but is not a symlink to our source"
    else
      echo "  ✗ /etc/resolver/${tld}: not found"
    fi
  done
  echo ""

  echo "── DNS resolution test ──"
  echo "  Direct (dnsmasq health):"
  for tld in "${TLDS[@]}"; do
    local test_domain="test.${tld}"
    if dig "$test_domain" @"${LOOPBACK_IP}" +short 2>/dev/null | grep -q "$LOOPBACK_IP"; then
      echo "    ✓ ${test_domain} @${LOOPBACK_IP} → ${LOOPBACK_IP}"
    else
      echo "    ⚠ ${test_domain} @${LOOPBACK_IP} → (no response)"
    fi
  done
  echo ""
  echo "  Via system resolver (what browsers/apps use):"
  for tld in "${TLDS[@]}"; do
    local test_domain="test.${tld}"
    if dscacheutil -q host -a name "$test_domain" 2>/dev/null | grep -q "$LOOPBACK_IP"; then
      echo "    ✓ ${test_domain} → ${LOOPBACK_IP}"
    else
      echo "    ⚠ ${test_domain} → (no response — run: sudo dscacheutil -flushcache)"
    fi
  done
  echo ""
  echo "  Note: 'dig' and 'host' bypass the system resolver and query the router."
  echo "        Use 'dscacheutil -q host -a name <domain>' to test what apps see."
}

# ──────────────────────────────────────────────
# Uninstall
# ──────────────────────────────────────────────

cmd_uninstall() {
  echo "═══ Uninstalling Loco DNS ═══"
  echo "  Note: Source files in _infra/etc/dns/ are kept. Only installed files are removed."
  echo ""

  # Establish sudo session once
  echo "  Establishing sudo session..."
  sudo -v
  echo ""

  # Remove macOS resolver symlinks
  echo "── Removing macOS resolver symlinks ──"
  for tld in "${TLDS[@]}"; do
    if [ -L "${RESOLVER_DIR}/${tld}" ]; then
      sudo rm -f "${RESOLVER_DIR}/${tld}"
      echo "  ✓ Removed symlink: /etc/resolver/${tld}"
    elif [ -f "${RESOLVER_DIR}/${tld}" ]; then
      echo "  ⚠ File at /etc/resolver/${tld} is not a symlink — not removing"
    else
      echo "  - Not found: /etc/resolver/${tld}"
    fi
  done
  echo ""

  # Remove dnsmasq config symlink
  echo "── Removing dnsmasq config symlink ──"
  if [ -L "$DNSMASQ_CONF_LINK" ]; then
    rm -f "$DNSMASQ_CONF_LINK"
    echo "  ✓ Removed symlink: ${DNSMASQ_CONF_LINK}"
  elif [ -f "$DNSMASQ_CONF_LINK" ]; then
    echo "  ⚠ File at ${DNSMASQ_CONF_LINK} is not a symlink — not removing"
  else
    echo "  - Not found"
  fi
  echo ""

  # Stop dnsmasq
  echo "── Stopping dnsmasq ──"
  sudo brew services stop dnsmasq 2>/dev/null
  echo "  ✓ Stopped"
  echo ""

  # Remove loopback alias
  echo "── Removing loopback alias ──"
  if _has_loopback_alias; then
    sudo ifconfig "$LOOPBACK_INTERFACE" -alias "$LOOPBACK_IP"
    echo "  ✓ Removed ${LOOPBACK_IP} from ${LOOPBACK_INTERFACE}"
  else
    echo "  - Not found"
  fi
  echo ""

  # Remove launch daemon plist
  echo "── Removing launch daemon ──"
  if [ -f "$PLIST_TARGET" ]; then
    sudo launchctl bootout system/"${PLIST_LABEL}" 2>/dev/null || \
      sudo launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    sudo rm -f "$PLIST_TARGET"
    echo "  ✓ Removed: ${PLIST_TARGET}"
  else
    echo "  - Not found"
  fi
  echo ""

  echo "═══ DNS uninstall complete ═══"
  echo "  Source files preserved at:"
  echo "    ${DNSMASQ_CONF_SRC}"
  echo "    ${RESOLVER_DIR_SRC}/"
  echo "    ${PLIST_SRC}"
  echo "  Reinstall anytime with: just dns-install"
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <command>"
  echo ""
  echo "Commands:"
  echo "  install     Install dnsmasq, symlink configs, create resolver (idempotent)"
  echo "  status      Show current DNS configuration"
  echo "  uninstall   Remove symlinks and DNS config (keeps source files)"
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