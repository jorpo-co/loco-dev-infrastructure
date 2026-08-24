
# Full setup: install DNS + install skills + pull all images
install:
  @echo "═══ Installing Loco Infra ═══"
  @echo ""
  @echo "── DNS ──"
  @{{ SCRIPTS_DIR }}/dns.sh install
  @echo ""
  @echo "── Skills ──"
  @mkdir -p {{ env("HOME") }}/.pi/skills
  @for skill in {{ PROJECT_DIR }}/skills/*/; do \
    name=$$(basename "$$skill"); \
    target={{ env("HOME") }}/.pi/skills/$$name; \
    if [ -L "$$target" ]; then \
      echo "  ✓ $$name already linked"; \
    elif [ -d "$$target" ]; then \
      echo "  ⚠ $$name exists as directory — skipping"; \
    else \
      ln -s "$$skill" "$$target"; \
      echo "  ✓ Linked: ~/.pi/skills/$$name → $$skill"; \
    fi; \
  done
  @echo ""
  @echo "── Images ──"
  @docker compose pull 2>&1 | sed 's/^/  /'
  @echo ""
  @echo "═══ Install complete ═══"
  @echo "  Run 'just up' to start the stack."


# Full uninstall: remove DNS + unlink skills + stop stack
uninstall:
  @echo "═══ Uninstalling Loco Infra ═══"
  @echo ""
  @echo "── DNS ──"
  @{{ SCRIPTS_DIR }}/dns.sh uninstall
  @echo ""
  @echo "── Stop stack ──"
  @{{ SCRIPTS_DIR }}/infra.sh down 2>/dev/null || echo "  (nothing running)"
  @echo ""
  @echo "── Unlink skills ──"
  @for skill in {{ PROJECT_DIR }}/skills/*/; do \
    name=$$(basename "$$skill"); \
    target={{ env("HOME") }}/.pi/skills/$$name; \
    if [ -L "$$target" ]; then \
      rm "$$target"; \
      echo "  ✓ Unlinked ~/.pi/skills/$$name"; \
    else \
      echo "  - ~/.pi/skills/$$name not a symlink — skipped"; \
    fi; \
  done
  @echo ""
  @echo "═══ Uninstall complete ═══"
  @echo "  Run 'just install' to reinstall."

# ──────────────────────────────────────────────
# Infra Stack
# ──────────────────────────────────────────────

# Start everything (Traefik + Registry + Registry UI + Dockge)
up:
  @{{ SCRIPTS_DIR }}/infra.sh up

# Stop everything
down:
  @{{ SCRIPTS_DIR }}/infra.sh down

# Show stack status
status:
  @{{ SCRIPTS_DIR }}/infra.sh status

# Tail logs
logs:
  @{{ SCRIPTS_DIR }}/infra.sh logs

# Restart everything
restart:
  @{{ SCRIPTS_DIR }}/infra.sh restart

# ──────────────────────────────────────────────
# Registry
# ──────────────────────────────────────────────

# Tag and push an image to registry.loco, then open the UI
registry-push image tag="latest":
  @{{ SCRIPTS_DIR }}/registry.sh push "{{ image }}" "{{ tag }}"
  @echo "  Opening registry UI..."
  @open http://registry.loco

# List repositories in the registry
registry-list:
  @{{ SCRIPTS_DIR }}/registry.sh list

# Show registry garbage collection info
registry-clean:
  @{{ SCRIPTS_DIR }}/registry.sh clean

# ──────────────────────────────────────────────
# Web UIs
# ──────────────────────────────────────────────

# Open the registry UI in your browser
registry-ui:
  @echo "Opening http://registry.loco..."
  @open http://registry.loco

# Open Dockge in your browser
dockge:
  @echo "Opening http://dockge.jorpo.loco..."
  @open http://dockge.jorpo.loco

# Open Traefik dashboard in your browser
traefik:
  @echo "Opening http://traefik.jorpo.loco..."
  @open http://traefik.jorpo.loco

# ──────────────────────────────────────────────
# Scaffolding
# ──────────────────────────────────────────────

# Scaffold a new Docker Compose project and open it
scaffold-compose name port="3000":
  @{{ SCRIPTS_DIR }}/scaffold.sh compose "{{ name }}" "{{ port }}"
  @echo "  ✓ Created project at ~/Projects/{{ name }}/"
  @echo "  Run 'just up' to start it."

# Scaffold a new kind cluster project
scaffold-kind name:
  @{{ SCRIPTS_DIR }}/scaffold.sh kind "{{ name }}"
  @echo "  ✓ Created kind project at ~/Projects/{{ name }}/"

# Scaffold a new site project (uses .loco TLD)
scaffold-site name port="80":
  @{{ SCRIPTS_DIR }}/scaffold.sh site "{{ name }}" "{{ port }}"
  @echo "  ✓ Created site project at ~/Projects/{{ name }}/"

# ──────────────────────────────────────────────
# Kind Management
# ──────────────────────────────────────────────

# Create a kind cluster with port allocation + Traefik config
kind-create name:
  @{{ SCRIPTS_DIR }}/kind.sh create "{{ name }}"

# Delete a kind cluster and free its ports
kind-delete name:
  @{{ SCRIPTS_DIR }}/kind.sh delete "{{ name }}"

# List all kind clusters with port mappings
kind-list:
  @{{ SCRIPTS_DIR }}/kind.sh list

# Show port allocations
kind-ports:
  @{{ SCRIPTS_DIR }}/kind.sh ports

# ──────────────────────────────────────────────
# System
# ──────────────────────────────────────────────

# Show all running projects on the infra network
ps:
  @echo "══════════════════════════════════════════════"
  @echo "  Docker Compose (loco-net)"
  @echo "══════════════════════════════════════════════"
  @FMT="table {{ "{{" }}.Names}}\t{{ "{{" }}.Image}}\t{{ "{{" }}.Status}}\t{{ "{{" }}.Ports}}" && \
    docker ps --filter "network=loco-net" --format "$$FMT" 2>/dev/null || echo "  (no containers)"
  @echo ""
  @echo "══════════════════════════════════════════════"
  @echo "  Kind Clusters"
  @echo "══════════════════════════════════════════════"
  @kind get clusters 2>/dev/null || echo "  (no clusters)"
  @echo ""
  @echo "══════════════════════════════════════════════"
  @echo "  Traefik File Provider Configs"
  @echo "══════════════════════════════════════════════"
  @ls -1 {{ PROJECT_DIR }}/etc/traefik/services/*.yml 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  @echo ""
  @echo "══════════════════════════════════════════════"
  @echo "  Port Allocations"
  @echo "══════════════════════════════════════════════"
  @{{ SCRIPTS_DIR }}/kind.sh ports 2>/dev/null || echo "  (none)"

# Check all components are healthy
doctor:
  @echo "═══ Loco Infra Doctor ═══"
  @echo ""

  # Check Docker
  @echo "── Docker ──"
  @if docker info &>/dev/null; then \
    echo "  ✓ Docker is running"; \
  else \
    echo "  ✗ Docker is not running"; \
  fi

  # Check DNS
  @echo ""
  @echo "── DNS ──"
  @if dscacheutil -q host -a name test.jorpo.loco 2>/dev/null | grep -q "10.254.254.254"; then \
    echo "  ✓ *.jorpo.loco → 10.254.254.254"; \
  else \
    echo "  ✗ *.jorpo.loco not resolving. Run: just install"; \
  fi
  @if dscacheutil -q host -a name test.loco 2>/dev/null | grep -q "10.254.254.254"; then \
    echo "  ✓ *.loco → 10.254.254.254"; \
  else \
    echo "  ✗ *.loco not resolving. Run: just install"; \
  fi

  # Check Infrastructure
  @echo ""
  @echo "── Infrastructure ──"
  @if docker ps --format '{{ "{{" }}.Names}}' 2>/dev/null | grep -q "loco-traefik"; then \
    echo "  ✓ Traefik is running"; \
  else \
    echo "  ✗ Traefik is not running. Run: just up"; \
  fi
  @if docker ps --format '{{ "{{" }}.Names}}' 2>/dev/null | grep -q "loco-registry"; then \
    echo "  ✓ Registry is running"; \
  else \
    echo "  ✗ Registry is not running. Run: just up"; \
  fi
  @if docker ps --format '{{ "{{" }}.Names}}' 2>/dev/null | grep -q "loco-registry-ui"; then \
    echo "  ✓ Registry UI is running"; \
  else \
    echo "  ✗ Registry UI is not running. Run: just up"; \
  fi
  @if docker ps --format '{{ "{{" }}.Names}}' 2>/dev/null | grep -q "loco-dockge"; then \
    echo "  ✓ Dockge is running"; \
  else \
    echo "  ✗ Dockge is not running. Run: just up"; \
  fi
  @if docker network ls --format '{{ "{{" }}.Name}}' 2>/dev/null | grep -q "^loco-net$"; then \
    echo "  ✓ loco-net network exists"; \
  else \
    echo "  ✗ loco-net network missing. Run: just up"; \
  fi

  # Check Traefik routing
  @echo ""
  @echo "── Traefik Routing ──"
  @if curl -s -o /dev/null -w "%{http_code}" http://traefik.jorpo.loco 2>/dev/null | grep -q "200"; then \
    echo "  ✓ Traefik dashboard reachable at http://traefik.jorpo.loco"; \
  else \
    echo "  ⚠ Traefik dashboard not reachable (may need DNS setup)"; \
  fi
  @if curl -s -o /dev/null -w "%{http_code}" http://registry.loco/v2/_catalog 2>/dev/null | grep -q "200"; then \
    echo "  ✓ Registry API reachable at http://registry.loco/v2/_catalog"; \
  else \
    echo "  ⚠ Registry API not reachable via Traefik"; \
  fi
  @if curl -s -o /dev/null -w "%{http_code}" http://registry.loco 2>/dev/null | grep -q "200"; then \
    echo "  ✓ Registry UI reachable at http://registry.loco"; \
  else \
    echo "  ⚠ Registry UI not reachable (may still be starting) — check 'just logs'"; \
  fi
  @if curl -s -o /dev/null -w "%{http_code}" http://dockge.jorpo.loco 2>/dev/null | grep -q "200"; then \
    echo "  ✓ Dockge reachable at http://dockge.jorpo.loco"; \
  else \
    echo "  ⚠ Dockge not reachable (may still be starting) — check 'just logs'"; \
  fi

  # Check DNS vs /etc/hosts
  @echo ""
  @echo "── /etc/hosts conflicts ──"
  @if grep -q "jorpo.loco" /etc/hosts 2>/dev/null; then \
    echo "  ⚠ /etc/hosts contains jorpo.loco entries — these may conflict with dnsmasq"; \
    grep "jorpo.loco" /etc/hosts 2>/dev/null | sed 's/^/    /'; \
  else \
    echo "  ✓ No jorpo.loco entries in /etc/hosts"; \
  fi

  @echo ""
  @echo "═══ Doctor complete ═══"

# Show environment
env:
  @echo "═══ Loco Infra Environment ═══"
  @echo ""
  @echo "  Project dir:  {{ PROJECT_DIR }}"
  @echo "  Scripts dir:  {{ SCRIPTS_DIR }}"
  @echo "  Compose file: {{ PROJECT_DIR }}/compose.yml"
  @echo "  Traefik cfg:  {{ PROJECT_DIR }}/etc/traefik/traefik.yml"
  @echo "  Traefik con:  {{ PROJECT_DIR }}/etc/traefik/services/"
  @echo "  Templates:    {{ PROJECT_DIR }}/templates/"
  @echo "  Registry:     {{ PROJECT_DIR }}/var/registry/"
  @echo "  Port allocs:  {{ PROJECT_DIR }}/var/port-allocations.json"
  @echo "  Skills:       {{ PROJECT_DIR }}/skills/"
  @echo ""
  @echo "  DNS loopback: {{ env("LOOPBACK_IP") }}"
  @echo "  DNS TLDs:     *.jorpo.loco, *.loco"
  @echo "  Traefik port: 80 ({{ env("LOOPBACK_IP") }})"
  @echo "  Registry port: {{ env("REGISTRY_PORT") }} (localhost)"
  @echo "  Registry UI:   http://{{ env("REGISTRY_HOST") }} (web browser)"
  @echo "  Registry API:  http://{{ env("REGISTRY_HOST") }}/v2/_catalog"
  @echo "  Dockge:        http://dockge.jorpo.loco (stack manager)"
  @echo "  Traefik:       http://traefik.jorpo.loco (dashboard)"
  @echo ""
  @echo "  Kind HTTP start:  {{ env("KIND_HTTP_PORT_START") }}"
  @echo "  Kind TLS start:   {{ env("KIND_TLS_PORT_START") }}"

# default: show help
default:
  @just --list --justfile {{ justfile() }}
