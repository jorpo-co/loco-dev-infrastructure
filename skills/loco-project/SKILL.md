---
name: loco-project
description: "Register local Docker Compose / site projects with the infra Traefik router using the file provider. Writes a Traefik config to etc/traefik/services/<name>.yml so the route is managed by infra, not by Docker labels. No loco.compose.yaml files are generated. Use whenever the user asks to create a new project, expose a service, or give something a local domain. Runs via the skillrunner HTTP API at localhost:9999."
---

# Loco Project

The user organises projects under `~/Projects/<category>/<name>/`. Each project that needs
networking gets a Traefik file provider config in `etc/traefik/services/<name>.yml` inside
the infra stack. No `loco.compose.yaml` files — the project's own compose file just needs to
join the `loco` network.

All types (compose, kind, site) use the file provider approach. No Docker labels required.

## How commands are run

All operations use the skillrunner at `http://localhost:9999` via the `recipe` API:

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"scaffold-compose","args":["<name>","<port>"]}'
```

The skillrunner mounts `/infra` → `_infra` and `/projects` → `~/Projects`.
Recipes run via `just --justfile /infra/justfile`.

## Determining the project directory

The scaffold scripts infer the category from the agent's working directory (inside `/projects`).
The agent must ensure CWD is set correctly, or pass `--project-dir` via the underlying script.

| User says | Resolution |
|---|---|
| "create a compose project in this folder" | Use CWD → derives name + category from path |
| "make a new project called 'myapp' in ./something/" | Resolve to `/projects/<category>/myapp/` |
| "make me a project called 'concerto'" | Default category `jorpo` → `/projects/jorpo/concerto` |

## Creating a new compose project

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"scaffold-compose","args":["myapp","3000"]}'
```

Writes a Traefik file provider config to `/infra/etc/traefik/services/myapp.yml`:

```yaml
http:
  routers:
    myapp:
      rule: "HostRegexp(`{subdomain:.+}.myapp.jorpo.loco`) || Host(`myapp.jorpo.loco`)"
      entryPoints: ["web"]
      service: myapp
    myapp-secure:
      rule: "HostRegexp(`{subdomain:.+}.myapp.jorpo.loco`) || Host(`myapp.jorpo.loco`)"
      entryPoints: ["websecure"]
      service: myapp
      tls: {}
  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://myapp:3000"
```

This gives both `myapp.jorpo.loco` and `*.myapp.jorpo.loco` (e.g. `api.myapp.jorpo.loco`).
Traefik resolves `myapp:3000` via Docker DNS — both are on the `loco` network.

No `loco.compose.yaml` is generated. The user's project just needs to be on the `loco`
network — add to their own `compose.yaml`:

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

## Creating a site (`.loco` TLD)

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"recipe":"scaffold-site","args":["blog","80"]}'
```

Writes a Traefik file provider config with domain `blog.loco` to
`/infra/etc/traefik/services/blog.yml`.

## The generated Traefik config

```yaml
http:
  routers:
    <name>:
      rule: "HostRegexp(`{subdomain:.+}.<name>.jorpo.loco`) || Host(`<name>.jorpo.loco`)"
      entryPoints: ["web"]
      service: <name>
  services:
    <name>:
      loadBalancer:
        servers:
          - url: "http://<name>:<port>"
```

This gives both `<name>.jorpo.loco` and `*.<name>.jorpo.loco`.

- `server.port` is the **container** port, not a host port.
- The container name must match `<name>` so Docker DNS resolves correctly.
- Domain is `<name>.jorpo.loco` for compose projects, `<name>.loco` for sites.

## Next steps after scaffolding

The project's own `compose.yaml` needs:

1. `container_name: <name>` on the service (or name the service after the project)
2. `networks: [loco]` on the service
3. An external network definition: `networks: { loco: { external: true } }`

## Modifying an existing project

If the project already has a Traefik config in `etc/traefik/services/`, edit it in place.
The Traefik file provider watches for changes — no restart needed.

## Validating output

```bash
curl -s -X POST http://localhost:9999/run \
  -d '{"script":"/usr/bin/docker","args":["compose","-f","/projects/jorpo/myapp/compose.yaml","config"]}'
```

Check: valid YAML, network `loco` is `external: true`, container has `container_name` or
matches the service name used in the Traefik config.