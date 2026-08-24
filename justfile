
set unstable
set lists

set dotenv-load := true
set dotenv-path := [".env.defaults", ".env"]

PROJECT_DIR := justfile_directory()
SCRIPTS_DIR := PROJECT_DIR + "/scripts"

default:
  @just -l -u

# install requirements
setup:
  @{{ SCRIPTS_DIR }}/dns.sh install
  @docker compose -f compose.yml pull --ignore-pull-failures --include-deps --policy missing


# remove installed components
teardown:
  @{{ SCRIPTS_DIR }}/dns.sh uninstall


# start the infrastructure
up:
  @{{ SCRIPTS_DIR }}/infra.sh up


# bring the infrastructure down
down:
  @{{ SCRIPTS_DIR }}/infra.sh down


# status of system
status: _status_dns

_status_dns:
  @{{ SCRIPTS_DIR }}/dns.sh status

_status_infra:
  @{{ SCRIPTS_DIR }}/infra.sh status


# show docker cpmpose logs and follow output
logs:
  @docker compose logs -f


# Open the registry UI in your browser
registry:
  @echo "Opening http://registry.loco..."
  @open http://registry.loco

# Open Traefik dashboard in your browser
traefik:
  @echo "Opening http://traefik.jorpo.loco..."
  @open http://traefik.jorpo.loco
