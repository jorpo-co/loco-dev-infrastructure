"""
projects.py — Parse Traefik file provider configs, detect project status, and control lifecycle.

All paths are inside the skillrunner container (/infra, /projects).
"""

import json
import os
import re
import subprocess

INFRA_DIR = os.environ.get("INFRA_DIR", "/infra")
PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/projects")
HOST_PROJECTS_DIR = os.environ.get("HOST_PROJECTS_DIR", "")
CONFIGS_DIR = os.path.join(INFRA_DIR, "etc/traefik/configs")


def _run(cmd, cwd=None, timeout=30):
    """Run a command and return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", f"timeout after {timeout}s"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


def _find_compose_dir(name):
    """Search PROJECTS_DIR for a directory with compose.yaml and matching container_name."""
    if not os.path.isdir(PROJECTS_DIR):
        return None
    for entry in os.listdir(PROJECTS_DIR):
        candidate = os.path.join(PROJECTS_DIR, entry, name)
        if os.path.isdir(candidate):
            for cf in ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"):
                if os.path.isfile(os.path.join(candidate, cf)):
                    return candidate
    return None


def _parse_domain(rule):
    """Extract the domain suffix from a Traefik HostRegexp rule.
    e.g. '{subdomain:.+}.myapp.jorpo.loco' → '.jorpo.loco'
    """
    m = re.search(r'HostRegexp\(`\{subdomain:\.\+\}\.\*?'
                   r'[a-zA-Z0-9_-]+'
                   r'((?:\.[a-zA-Z0-9_-]+)+)`', rule)
    if m:
        return m.group(1)
    # Fallback: Host() match
    m = re.search(r"Host\(`[a-zA-Z0-9_-]+(\.[^`]+)`", rule)
    if m:
        return m.group(1)
    return ".loco"


def _parse_http_port(services, name):
    """Extract HTTP port from the loadBalancer URL."""
    svc = services.get(name, {})
    servers = svc.get("loadBalancer", {}).get("servers", [])
    for s in servers:
        url = s.get("url", "")
        m = re.search(r":(\d+)$", url)
        if m:
            return m.group(1)
    return "?"


def _parse_tls_port(config, name):
    """Extract TLS port from TCP passthrough config."""
    tcp = config.get("tcp", {})
    routers = tcp.get("routers", {})
    for rname, r in routers.items():
        svc_name = r.get("service", "")
        svc = tcp.get("services", {}).get(svc_name, {})
        servers = svc.get("loadBalancer", {}).get("servers", [])
        for s in servers:
            addr = s.get("address", "")
            m = re.search(r":(\d+)$", addr)
            if m:
                return m.group(1)
    return None


def _parse_ssl_mode(config):
    """Determine SSL mode from config structure."""
    # Check for kind/passthrough (TCP router with passthrough: true)
    tcp = config.get("tcp", {})
    for router in tcp.get("routers", {}).values():
        tls = router.get("tls", {})
        if tls.get("passthrough") is True:
            return "passthrough"
    # Check for terminate (websecure entry point with tls: {})
    http = config.get("http", {})
    for router in http.get("routers", {}).values():
        eps = router.get("entryPoints", [])
        if "websecure" in eps and router.get("tls") is not None:
            return "terminate"
    return "none"


def _is_kind(config):
    """Is this a kind cluster config (passthrough or host.docker.internal)?"""
    if _parse_ssl_mode(config) == "passthrough":
        return True
    # Check if any service points to host.docker.internal
    http = config.get("http", {})
    for svc in http.get("services", {}).values():
        for server in svc.get("loadBalancer", {}).get("servers", []):
            if "host.docker.internal" in server.get("url", ""):
                return True
    return False


def _get_host(config, name):
    """Extract backend hostname from service config."""
    http = config.get("http", {})
    svc = http.get("services", {}).get(name, {})
    servers = svc.get("loadBalancer", {}).get("servers", [])
    for s in servers:
        url = s.get("url", "")
        m = re.search(r"://([^:]+):", url)
        if m:
            return m.group(1)
    # Try the -tcp service for kind
    tcp = config.get("tcp", {})
    for svc_name, s in tcp.get("services", {}).items():
        for server in s.get("loadBalancer", {}).get("servers", []):
            addr = server.get("address", "")
            m = re.search(r"^([^:]+):", addr)
            if m:
                return m.group(1)
    return name


def get_parsed_projects():
    """Scan configs dir and return a list of project dicts."""
    projects = {}

    if not os.path.isdir(CONFIGS_DIR):
        return []

    for fname in sorted(os.listdir(CONFIGS_DIR)):
        if not fname.endswith(".yml") and not fname.endswith(".yaml"):
            continue
        # Skip internal files
        if fname.startswith("_certs-") or fname == "_middlewares.yml":
            continue

        fpath = os.path.join(CONFIGS_DIR, fname)

        # Parse project_dir comment from raw file content
        project_dir = ""
        with open(fpath) as f:
            first_line = f.readline().strip()
        m = re.match(r"^# project_path:\s*(.*)", first_line)
        if m:
            project_dir = m.group(1).strip()

        try:
            import yaml
            with open(fpath) as f:
                config = yaml.safe_load(f)
        except Exception:
            # Fallback: minimal grep-based parsing for basic info
            config = {}
            with open(fpath) as f:
                content = f.read()
            m = re.search(r"Host\(`([^`]+)`\)", content)
            if m:
                config["_rule_host"] = m.group(1)
            m = re.search(r"HostRegexp\(`[^`]+`\)", content)
            if m:
                config["_rule_regexp"] = m.group(1)
            m = re.search(r'url: "http://([^:]+):(\d+)"', content)
            if m:
                config.setdefault("_services", {})["_"] = {"host": m.group(1), "port": m.group(2)}

        name = fname.replace(".yml", "").replace(".yaml", "")

        http = config.get("http", {})
        routers = http.get("routers", {})

        # Get the first router's rule to extract domain
        rule = ""
        host = ""
        for rname, r in routers.items():
            if not rname.endswith("-secure") and not rname.endswith("-tcp"):
                rules = r.get("rule", "")
                rule = rules
                break

        if not rule and "_rule_regexp" in config:
            rule = config["_rule_regexp"]

        domain = _parse_domain(rule)
        ssl_mode = _parse_ssl_mode(config)
        kind = _is_kind(config)
        http_port = _parse_http_port(http.get("services", {}), name)
        tls_port = _parse_tls_port(config, name)
        host = _get_host(config, name)

        p = {
            "name": name,
            "domain": domain,
            "host": host,
            "http_port": http_port,
            "tls_port": tls_port or "",
            "ssl_mode": ssl_mode,
            "type": "kind" if kind else "compose",
            "project_dir": project_dir,
            "status": "unknown",
            "url": ("https" if ssl_mode != "none" else "http") + "://" + name + domain,
        }
        projects[name] = p

    return projects


def _to_host_path(container_path):
    """Translate a container path to the equivalent host path.
    Docker commands run against the host daemon via mounted socket,
    so bind mounts need host-visible paths."""
    if HOST_PROJECTS_DIR and container_path.startswith(PROJECTS_DIR):
        return container_path.replace(PROJECTS_DIR, HOST_PROJECTS_DIR, 1)
    return container_path


def resolve_status(projects):
    """Add running status to each project dict (mutates in place)."""
    # Get running kind clusters
    kind_clusters = set()
    rc, out, _ = _run(["kind", "get", "clusters"])
    if rc == 0:
        kind_clusters = set(out.splitlines())

    # Get running docker containers on loco network
    compose_running = set()
    rc, out, _ = _run(["docker", "ps", "--filter", "network=loco",
                        "--format", "{{.Names}}"])
    if rc == 0:
        for line in out.splitlines():
            compose_running.add(line.strip())

    for p in projects.values():
        if p["type"] == "kind":
            p["status"] = "running" if p["name"] in kind_clusters else "stopped"
        else:  # compose
            p["status"] = "running" if p["name"] in compose_running else "stopped"


def action_project(name, action):
    """Perform start/stop/restart on a project. Returns (ok, message)."""
    # Re-parse projects to determine type and path
    projects = get_parsed_projects()
    if name not in projects:
        return False, f"Project '{name}' not found"

    p = projects[name]

    if p["type"] == "kind":
        return _action_kind(name, action)
    else:
        return _action_compose(name, p.get("project_dir", ""), action)


def _action_kind(name, action):
    if action == "start":
        # Try to find a kind-config.yaml
        config_path = None
        if os.path.isdir(PROJECTS_DIR):
            for entry in os.listdir(PROJECTS_DIR):
                candidate = os.path.join(PROJECTS_DIR, entry, name, "kind-config.yaml")
                if os.path.isfile(candidate):
                    config_path = candidate
                    break
        if config_path:
            return _run_and_report(["kind", "create", "cluster", "--name", name,
                                     "--config", config_path], timeout=120)
        else:
            # Fallback: use infra kind-create recipe (allocates ports etc.)
            rc, out, err = _run(
                ["just", "--justfile", f"{INFRA_DIR}/justfile",
                 "--working-directory", INFRA_DIR, "kind-create", name],
                timeout=120,
            )
            return rc == 0, out or err

    elif action == "stop":
        return _run_and_report(["kind", "delete", "cluster", "--name", name])
    elif action == "restart":
        ok1, msg1 = _action_kind(name, "stop")
        ok2, msg2 = _action_kind(name, "start")
        return ok2, f"Restarted: {msg1}; {msg2}"
    return False, f"Unknown action: {action}"


def _action_compose(name, project_dir, action):
    if project_dir and os.path.isdir(project_dir):
        compose_dir = project_dir
    else:
        compose_dir = _find_compose_dir(name)
    if not compose_dir:
        return False, f"No compose.yaml found for '{name}'. Searched project_dir '{project_dir or '(empty)'}' and PROJECTS_DIR."

    # Determine compose filename (container path) then translate to host path for Docker
    compose_filename = "compose.yaml" if os.path.isfile(
        os.path.join(compose_dir, "compose.yaml")) else "compose.yml"
    compose_file = os.path.join(compose_dir, compose_filename)
    host_dir = _to_host_path(compose_dir)

    if action == "start":
        return _run_and_report(
            ["docker", "compose", "--project-directory", host_dir,
             "-f", compose_file, "up", "-d"],
            cwd=compose_dir,
        )
    elif action == "stop":
        return _run_and_report(
            ["docker", "compose", "--project-directory", host_dir,
             "-f", compose_file, "down"],
            cwd=compose_dir,
        )
    elif action == "restart":
        ok1, msg1 = _action_compose(name, project_dir, "stop")
        ok2, msg2 = _action_compose(name, project_dir, "start")
        return ok2, f"Restarted: {msg1}; {msg2}"
    return False, f"Unknown action: {action}"


def _run_and_report(cmd, cwd=None, timeout=30):
    rc, out, err = _run(cmd, cwd=cwd, timeout=timeout)
    if rc == 0:
        return True, out or "OK"
    else:
        return False, err or out or f"exit code {rc}"