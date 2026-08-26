set unstable
set lists

set dotenv-load
set dotenv-path := [".env.defaults", ".env"]

PROJECT_DIR := justfile_directory()
SCRIPTS_DIR := PROJECT_DIR + "/scripts"

default:
    @just -l -u

# install requirements
setup:
    @{{ SCRIPTS_DIR }}/dns.sh install
    @just certs-init
    @docker compose -f compose.yml pull \
      --ignore-pull-failures \
      --include-deps \
      --policy missing
    @{{ SCRIPTS_DIR }}/skills.sh install

# remove installed components
teardown:
    @{{ SCRIPTS_DIR }}/skills.sh uninstall
    @docker compose -f compose.yml down \
      --rmi all
    @{{ SCRIPTS_DIR }}/dns.sh uninstall

# start the infrastructure
up:
    @{{ SCRIPTS_DIR }}/infra.sh up

# bring the infrastructure down
down:
    @{{ SCRIPTS_DIR }}/infra.sh down

# status of system
status:
    @{{ SCRIPTS_DIR }}/dns.sh status
    @{{ SCRIPTS_DIR }}/infra.sh status
    @{{ SCRIPTS_DIR }}/skills.sh status

# restart the stack
restart:
    @{{ SCRIPTS_DIR }}/infra.sh restart

# show docker cpmpose logs and follow output
logs:
    @docker compose logs -f

# Open the registry UI in your browser
registry:
    @echo "Opening http://registry.loco..."
    @open http://registry.loco

# Open Traefik dashboard in your browser
traefik:
    @echo "Opening http://traefik.loco..."
    @open http://traefik.loco

# tag and push an image to registry.loco
registry-push image tag="latest":
    @{{ SCRIPTS_DIR }}/registry.sh push "{{ image }}" "{{ tag }}"
    @echo "  → http://registry.loco"

# list repositories in the registry
registry-list:
    @{{ SCRIPTS_DIR }}/registry.sh list

# show registry garbage collection info
registry-clean:
    @{{ SCRIPTS_DIR }}/registry.sh clean

# register a project with Traefik (HTTP only, no SSL)
scaffold-http-only name domain http_port="80":
    @{{ SCRIPTS_DIR }}/scaffold.sh register \
      --name "{{ name }}" \
      --domain "{{ domain }}" \
      --http-port "{{ http_port }}"

# register a project with Traefik (terminate SSL at Traefik)
scaffold-terminate name domain http_port="80":
    @{{ SCRIPTS_DIR }}/scaffold.sh register \
      --name "{{ name }}" \
      --domain "{{ domain }}" \
      --http-port "{{ http_port }}" \
      --ssl terminate

# register a kind cluster with Traefik (passthrough SSL, host.docker.internal)
scaffold-passthrough name domain http_port tls_port:
    @{{ SCRIPTS_DIR }}/scaffold.sh register \
      --name "{{ name }}" \
      --domain "{{ domain }}" \
      --host host.docker.internal \
      --http-port "{{ http_port }}" \
      --tls-port "{{ tls_port }}" \
      --ssl passthrough

# scaffold a kind cluster project (kind-config.yaml)
scaffold-kind name:
    @{{ SCRIPTS_DIR }}/kind.sh scaffold "{{ name }}"

# create a kind cluster with port allocation + Traefik route registration
kind-create name:
    @{{ SCRIPTS_DIR }}/kind.sh create "{{ name }}"

# delete a kind cluster and free its ports
kind-delete name:
    @{{ SCRIPTS_DIR }}/kind.sh delete "{{ name }}"

# register an existing kind cluster with infra (ports + mirror + Traefik route)
kind-import name:
    @{{ SCRIPTS_DIR }}/kind.sh import "{{ name }}"

# initialize mkcert root CA (runs on host, stores CA in etc/certs/ca/)
certs-init:
    @mkdir -p {{ PROJECT_DIR }}/etc/certs/ca
    @CAROOT={{ PROJECT_DIR }}/etc/certs/ca mkcert -install
    @echo "  ✓ mkcert CA initialized in etc/certs/ca/"
    @echo "  ✓ CA installed in host trust store"

# list all kind clusters with port mappings
kind-list:
    @{{ SCRIPTS_DIR }}/kind.sh list

# show port allocations
kind-ports:
    @{{ SCRIPTS_DIR }}/kind.sh ports

# show all running projects on the infra network
ps:
    @echo "══════════════════════════════════════════════"
    @echo "  Docker Compose (loco)"
    @echo "══════════════════════════════════════════════"
    @docker ps --filter "network=loco" --format "table {{ "{{ " }}.Names}}\t{{ "{{ " }}.Image}}\t{{ "{{ " }}.Status}}" 2>/dev/null || echo "  (no containers)"
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

# check all components are healthy
doctor:
    @echo "═══ Loco Infra Doctor ═══"
    @echo ""
    @echo "── Docker ──"
    @if docker info &>/dev/null; then echo "  ✓ Docker is running"; else echo "  ✗ Docker is not running"; fi
    @echo ""
    @echo "── DNS ──"
    @if dscacheutil -q host -a name test.loco 2>/dev/null | grep -q "10.254.254.254"; then echo "  ✓ *.loco → 10.254.254.254"; else echo "  ✗ *.loco not resolving. Run: just setup"; fi
    @echo ""
    @echo "── Infrastructure ──"
    @for svc in loco-traefik loco-registry loco-registry-ui loco-skillrunner; do \
      docker ps --format "{{ "{{ " }}.Names}}" 2>/dev/null | grep -q "$svc" && echo "  ✓ $svc is running" || echo "  ✗ $svc is not running. Run: just up"; \
    done
    @echo ""
    @echo "── Traefik Routing ──"
    @if curl -s -o /dev/null -w "%{http_code}" http://traefik.loco 2>/dev/null | grep -q "200"; then echo "  ✓ Traefik dashboard reachable at http://traefik.loco"; else echo "  ⚠ Traefik dashboard not reachable (may need DNS setup)"; fi
    @echo ""
    @echo "── /etc/hosts conflicts ──"
    @if grep -q "\.loco" /etc/hosts 2>/dev/null; then echo "  ⚠ /etc/hosts contains .loco entries — may conflict with dnsmasq"; grep "\.loco" /etc/hosts 2>/dev/null | sed 's/^/    /'; else echo "  ✓ No .loco entries in /etc/hosts"; fi
    @echo ""
    @echo "═══ Doctor complete ═══"

# show environment variables and paths
env:
    @echo "═══ Loco Infra Environment ═══"
    @echo ""
    @echo "  Project dir:  {{ PROJECT_DIR }}"
    @echo "  Scripts dir:  {{ SCRIPTS_DIR }}"
    @echo "  Compose file: {{ PROJECT_DIR }}/compose.yml"
    @echo "  Traefik cfg:  {{ PROJECT_DIR }}/etc/traefik/traefik.yml"
    @echo "  Providers:    {{ PROJECT_DIR }}/etc/traefik/services/"
    @echo "  Templates:    {{ PROJECT_DIR }}/templates/"
    @echo "  Registry:     {{ PROJECT_DIR }}/var/registry/"
    @echo "  Port allocs:  {{ PROJECT_DIR }}/var/port-allocations.json"
    @echo "  Skills:       {{ PROJECT_DIR }}/skills/"
    @echo ""
    @echo "  Certs:        {{ PROJECT_DIR }}/etc/certs/"
  @echo "    CA root:    {{ PROJECT_DIR }}/etc/certs/ca/
  @echo "  DNS:          *.loco → 10.254.254.254"
    @echo "  Traefik:      http://traefik.loco"
    @echo "  Registry:     http://registry.loco / localhost:5001"
    @echo "  Skillrunner:  http://localhost:9999"
