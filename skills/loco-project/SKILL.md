---
name: loco-project
description: "Scaffold or modify local Docker Compose / site projects so they join the user's shared loco network and register routes with Traefik at *.jorpo.loco or *.loco. Use whenever the user asks to create a new project, add networking to an existing project, expose a service, or give something a local domain. Runs via the skillrunner HTTP API."
---

# Loco Project

The user organises projects under `~/Projects/<category>/<name>/`. Each project that needs
networking gets a `compose.yaml` that joins the shared `loco` network and registers routes
with Traefik. This skill creates those files via the **skillrunner HTTP API**.

## How commands are run

All operations use the skillrunner at `http://localhost:9999`:

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/<category>/<name>","compose","<port>"]}'
```

The container resolves:
- `/infra` → `~/Projects/_infra` (templates, scripts)
- `/projects` → `~/Projects` (where projects live)

## Determining the project directory

The agent must resolve the project directory from the user's prompt before calling the API:

| User says | Resolution |
|---|---|
| "create a compose project in this folder" | Use the agent's CWD → convert to `/projects/...` |
| "make a new project called 'myapp' in ./something/" | Resolve `./something/` to absolute → `/projects/...` |
| "make me a project called 'concerto'" | Default category `jorpo` → `/projects/jorpo/concerto`. Ask if ambiguous. |
| "scaffold a site called 'blog'" | Always under `/projects/sites/blog/` |

## Creating a new compose project

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/jorpo/myapp","compose","3000"]}'
```

Creates `/projects/jorpo/myapp/compose.yaml` with domain `http://myapp.jorpo.loco` on port 3000.

The script:
1. Derives project name from the directory basename (`myapp`)
2. Derives category from the parent dirname (`jorpo`)
3. Generates `compose.yaml` from the template at `/infra/templates/compose.yml`
4. Creates `.gitignore`
5. Outputs the project path and domain

## Creating a site (`.loco` TLD)

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/sites/blog","site","80"]}'
```

Creates `/projects/sites/blog/compose.yaml` with domain `http://blog.loco`.

## Creating a kind cluster project

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/infra/scripts/scaffold.sh","args":["--project-dir","/projects/jorpo/orchestration","kind"]}'
```

Creates `/projects/jorpo/orchestration/kind-config.yaml`.
Next step: use the `loco-kind` skill to create the cluster.

## The generated compose template

```yaml
services:
  <name>:
    build: .
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<name>.rule=Host(`<name>.jorpo.loco`)"
      - "traefik.http.routers.<name>.entrypoints=web"
      - "traefik.http.services.<name>.loadbalancer.server.port=<port>"
      - "traefik.docker.network=loco"
    networks:
      - loco

networks:
  loco:
    external: true
```

Rules:
- `traefik.enable=true` — required (Traefik uses `exposedByDefault: false`).
- `server.port` is the **container** port, not host port.
- `traefik.docker.network=loco` — required for correct routing.
- Domain is `<name>.jorpo.loco` for compose projects, `<name>.loco` for sites.

## Modifying an existing project

If a project already has a `compose.yaml`, **do not overwrite it**. Edit it in place:
1. Ensure every externally-reachable service is on `networks: [loco]`.
2. Add the four Traefik labels (from template above) to each reachable service.
3. Add the `networks: loco: external: true` block.
4. Keep all existing services, volumes, env, and other settings intact.
5. Internal-only services (e.g. databases) should NOT have `traefik.enable=true`.

## Validating output

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/bin/docker","args":["compose","-f","/projects/jorpo/myapp/compose.yaml","config"]}'
```

Check: valid YAML, network `loco` is `external: true`, all four labels present, port matches.

## Starting the project

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/bin/docker","args":["compose","-f","/projects/jorpo/myapp/compose.yaml","up","-d"]}'
```

DNS is wildcard — no `/etc/hosts` edit needed. The domain resolves automatically.