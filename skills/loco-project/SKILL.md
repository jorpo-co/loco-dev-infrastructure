---
name: loco-project
description: "Register local Docker Compose / site projects with the infra Traefik router using the file provider. Writes a Traefik config to etc/traefik/services/<name>.yml so the route is managed by infra, not by Docker labels. No loco.compose.yaml files are generated. Use whenever the user asks to create a new project, expose a service, or give something a local domain. Runs via the skillrunner HTTP API at localhost:9999."
---

# Loco Project

The user organises projects under `~/Projects/<category>/<name>/`. Each project that needs
networking gets a Traefik file provider config in `etc/traefik/services/<name>.yml` inside
the infra stack. No `loco.compose.yaml` files — the project's own compose file just needs to
join the `loco` network.

## How commands are run

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"<recipe>","args":["<name>","<port>"]}'
```

Two SSL modes are available, each using a different template:

| Mode | Recipe | Template | Use case |
|---|---|---|---|
| HTTP only | `scaffold-http-only` | `traefik-http-only.yml` | Compose projects (internal) |
| SSL terminate | `scaffold-terminate` | `traefik-terminate.yml` | Public sites (`.loco` TLD) |

Kind clusters use `scaffold-passthrough` internally — handled automatically by `loco-kind`.

The templates produce a config with both bare domain and wildcard subdomain
(e.g. `myapp.jorpo.loco` + `*.myapp.jorpo.loco`).

## Variable mapping

The templates use `{{name}}`, `{{domain}}`, `{{host}}`, `{{http_port}}`, `{{tls_port}}`:

| Type | Recipe | `{{host}}` | `{{domain}}` | Resolution |
|---|---|---|---|---|
| Compose | `scaffold-http-only` | container name | `.jorpo.loco` | Docker DNS on `loco` network |
| Site | `scaffold-terminate` | container name | `.loco` | Docker DNS on `loco` network |

## Determining the project directory

The scaffold scripts infer the category from the agent's working directory (inside `/projects`).
The agent must ensure CWD is set correctly, or pass `--project-dir` via the underlying script.

| User says | Resolution |
|---|---|
| "create a compose project in this folder" | Use CWD → derives name + category from path |
| "make a new project called 'myapp' in ./something/" | Resolve to `/projects/<category>/myapp/` |
| "make me a project called 'concerto'" | Default category `jorpo` → `/projects/jorpo/concerto` |

## What the project's compose.yaml needs

After scaffolding, the project's own `compose.yaml` must:

1. Set `container_name: <name>` on the service (or name the service after the project)
2. Add `networks: [loco]` to the service
3. Define an external network: `networks: { loco: { external: true } }`

```yaml
services:
  app:
    build: .
    container_name: myapp
    networks:
      - loco

networks:
  loco:
    external: true
```

## Modifying an existing project

Edit the config in `etc/traefik/services/<name>.yml` directly. Traefik watches for changes —
no restart needed.

## Validating output

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/bin/docker","args":["compose","-f","/projects/jorpo/myapp/compose.yaml","config"]}'
```

Check: valid YAML, network `loco` is `external: true`, container has `container_name` or
matches the service name used in the Traefik config.