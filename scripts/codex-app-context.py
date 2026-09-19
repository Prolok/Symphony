#!/usr/bin/env python3
"""Prepare project-local Codex profiles without copying the Symphony checkout."""

import fcntl
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
import zlib


def skill_directories(root):
    root = Path(root)
    if not root.is_dir():
        return []
    found, seen = [], set()
    for directory, children, files in os.walk(root, followlinks=True):
        current = Path(directory)
        real = current.resolve()
        if real in seen:
            children[:] = []
            continue
        seen.add(real)
        if "SKILL.md" in files:
            found.append(current)
    return sorted(found)


def project_root(directory):
    directory = Path(directory).resolve(strict=True)
    try:
        common = subprocess.check_output(
            ["git", "-C", str(directory), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except subprocess.CalledProcessError:
        return directory
    return Path(common).resolve(strict=True).parent


def prepare(release, original_home, skill_roots, project_dir, target=None):
    release, original_home = Path(release).resolve(), Path(original_home)
    target = Path(target) if target is not None else release / ".symphony" / "codex"
    if (target / "skills.json").is_file():
        return target
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    skills = target / "repository-skills"
    skills.mkdir(exist_ok=True)
    captured = []
    # Caller serializes preparation before any worker is started. Copy contents,
    # including referenced helper files; never keep links to mutable skill roots.
    selected = {}
    for root in skill_roots:
        selected.update({entry.name: entry for entry in skill_directories(root)})
    for entry in selected.values():
        destination = skills / entry.name
        shutil.copytree(entry, destination, dirs_exist_ok=True, symlinks=False, ignore=shutil.ignore_patterns("__pycache__"))
        captured.append({"source": str(entry), "path": str(destination)})
    auth = original_home / "auth.json"
    if auth.is_file() and not (target / "auth.json").exists():
        # OpenAI login stays in its existing credential location. This helper
        # neither reads its content nor copies it into a profile.
        (target / "auth.json").symlink_to(auth.resolve())
    # Trust only the project authorized by this start, including its worktrees.
    (target / "config.toml").write_text(project_config(project_dir))
    (target / "skills.json").write_text(json.dumps(captured))
    return target


def profile_home(checkout, state, original_home, project):
    roots = [checkout / ".codex/skills"]
    selected = {skill.name: skill for root in roots for skill in skill_directories(root)}
    contents = {}
    for name, skill in selected.items():
        for path in sorted(skill.rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                contents[str(Path(name) / path.relative_to(skill))] = hashlib.sha256(path.read_bytes()).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(["profile-v1", str(checkout), str(original_home), project_config(project), contents], sort_keys=True).encode())
    profiles = state / "profiles"
    profiles.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = profiles / fingerprint.hexdigest()
    # Only the small Codex profile is captured. Its sessions stay in the
    # existing state directory and concurrent workers share a complete profile.
    with (profiles / ".prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare(checkout, original_home, roots, project, target=target)
        if (target / "config.toml").is_symlink() or not project_config_matches(target / "config.toml", project):
            raise RuntimeError("changed project configuration")
        captured = [{"source": str(skill), "path": str(target / "repository-skills" / name)} for name, skill in selected.items()]
        if json.loads((target / "skills.json").read_text()) != captured:
            raise RuntimeError("changed skill bindings")
        actual = {str(path.relative_to(target / "repository-skills")): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (target / "repository-skills").rglob("*") if path.is_file() and "__pycache__" not in path.parts}
        if actual != contents:
            raise RuntimeError("changed project skills")
        auth = Path(original_home) / "auth.json"
        if auth.is_file() and not (target / "auth.json").exists():
            (target / "auth.json").symlink_to(auth.resolve())
        bind_sessions(target, state)
    return target


def project_config_matches(path, project):
    import tomllib
    actual = tomllib.loads(path.read_text())
    # Codex persists these UI counters after showing a model notice. They do
    # not change the trusted project, integrations, or execution configuration.
    tui = actual.pop("tui", {})
    if not isinstance(tui, dict) or set(tui) - {"model_availability_nux"}:
        return False
    notices = tui.get("model_availability_nux", {})
    if not isinstance(notices, dict) or not all(type(count) is int and count >= 0 for count in notices.values()):
        return False
    expected = tomllib.loads(project_config(project))
    try:
        return json.dumps(actual, sort_keys=True) == json.dumps(expected, sort_keys=True)
    except TypeError:
        return False


def project_config(project_dir):
    project = json.dumps(str(project_root(project_dir)), ensure_ascii=False)
    return ('[features]\napps = false\nmemories = false\n\n'
            '[memories]\ngenerate_memories = false\nuse_memories = false\n\n'
            '[projects.' + project + ']\ntrust_level = "trusted"\n')


def launch_config(release, target, cwd, user_home, environment=None):
    import tomllib
    environment = os.environ if environment is None else environment
    captured = json.loads((target / "skills.json").read_text())
    roots = [user_home / ".agents/skills", user_home / ".codex/skills", Path("/etc/codex/skills")]
    configs = [Path("/etc/codex/config.toml"), target / "config.toml"]
    for parent in [cwd, *cwd.parents]:
        roots.extend([parent / ".agents/skills", parent / ".codex/skills"])
        configs.append(parent / ".codex/config.toml")
        if (parent / ".git").exists():
            break
    disabled = {entry["source"] for entry in captured}
    for root in roots:
        for entry in skill_directories(root):
            disabled.update((str(entry), str(entry.resolve())))
    enabled = [{"path": entry["path"], "enabled": True} for entry in captured]
    settings = [{"path": path, "enabled": False} for path in sorted(disabled)] + enabled
    overrides = "[" + ",".join("{path=" + json.dumps(item["path"]) + ",enabled=" + str(item["enabled"]).lower() + "}" for item in settings) + "]"
    args = ["--config", "skills.config=" + overrides, "--config", "features.apps=false",
            "--config", "features.memories=false", "--config", "memories.generate_memories=false",
            "--config", "memories.use_memories=false"]
    disabled_servers, disabled_plugins = set(), set()
    for config in configs:
        if config.is_file():
            document = tomllib.loads(config.read_text())
            disabled_servers.update(document.get("mcp_servers", {}))
            disabled_plugins.update(document.get("plugins", {}))
    # Codex splits CLI key paths on dots, without TOML key unquoting. Put
    # arbitrary names inside a TOML table value instead, so the override disables
    # the existing server/plugin rather than creating an invalid quoted name.
    if disabled_servers:
        blocked = ",".join(json.dumps(name) + "={enabled=false}" for name in sorted(disabled_servers))
        args.extend(["--config", "mcp_servers={" + blocked + "}"])
    if disabled_plugins:
        blocked = ",".join(json.dumps(name) + "={enabled=false}" for name in sorted(disabled_plugins))
        args.extend(["--config", "plugins={" + blocked + "}"])
    # Only the installation-owned MCP is enabled. Dynamic tools share its client.
    args.extend(["--config", "mcp_servers.symphony_linear.enabled=true",
                 "--config", "mcp_servers.symphony_linear.required=true",
                 "--config", "mcp_servers.symphony_linear.command=" + json.dumps(str(release / "sym-codex-mcp"))])
    names = ("SYMPHONY_ROOT_DIR", "SYMPHONY_PROJECT_CONTEXT", "SYMPHONY_LINEAR_ENV_DIR", "SYMPHONY_LINEAR_AUTH_MODE", "SYMPHONY_LINEAR_CLIENT_SECRET_ENV", "SYMPHONY_LINEAR_BINDING_HASH",
             "SYMPHONY_RUN_ID", "SYMPHONY_PHASE", "SYMPHONY_ISSUE_ID", "SYMPHONY_ISSUE_IDENTIFIER", "SYMPHONY_YOLO_SCOPE",
             "SYMPHONY_SOURCE_REPO", "SYMPHONY_PROJECT_ROOT", "SYMPHONY_PROJECT_WORKTREES_ROOT", "SYMPHONY_WORKFLOW_FILE", "SYMPHONY_CODEX_STATE_ROOT", "SYMPHONY_PYTHON")
    forwarded = ",".join(json.dumps(name) + "=" + json.dumps(environment[name]) for name in names if name in environment)
    # Only the configured MCP may load the project secret on demand. A shell child
    # keeps the denied marker even when it invokes a launcher or Mix itself.
    access = environment.get("SYMPHONY_LINEAR_SECRET_ACCESS", "allowed")
    forwarded += ',SYMPHONY_LINEAR_SECRET_ACCESS=' + json.dumps(access)
    args.extend(["--config", "mcp_servers.symphony_linear.env={" + forwarded + "}"])
    # Forward only the name via Codex configuration; values stay in process env.
    secret_name = environment.get("SYMPHONY_LINEAR_CLIENT_SECRET_ENV", "")
    if not secret_name or not secret_name.isascii() or not secret_name.replace("_", "a").isalnum() or secret_name[0].isdigit():
        raise RuntimeError("missing client secret reference")
    args.extend(["--config", "mcp_servers.symphony_linear.env_vars=" + json.dumps([secret_name])])
    # The Codex host needs the secret for MCP, but shell commands must not inherit
    # it. The allowlist contains names only and also prevents a lower-layer `set`
    # from restoring the excluded secret. Disable snapshots and unrelated hooks
    # in this app context so those subprocesses cannot capture the host env.
    secrets = [secret_name, "LINEAR_API_KEY", "LINEAR_APP_SECRET", "LINEAR_RELAY_KEY"]
    relay_secret = environment.get("SYMPHONY_RELAY_KEY_ENV", "")
    if relay_secret:
        secrets.append(relay_secret)
    allowed = sorted({name for name in environment if name.upper() not in {key.upper() for key in secrets}} | {"SYMPHONY_LINEAR_SECRET_ACCESS"})
    args.extend(["--config", "shell_environment_policy.exclude=" + json.dumps(secrets),
                 "--config", "shell_environment_policy.include_only=" + json.dumps(allowed),
                 "--config", 'shell_environment_policy.set.SYMPHONY_LINEAR_SECRET_ACCESS="denied"',
                 "--config", "features.shell_snapshot=false", "--config", "features.hooks=false",
                 "--config", "notify=[]"])
    return args


def bind_sessions(target, state):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ("sessions", "archived_sessions"):
        (state / name).mkdir(exist_ok=True, mode=0o700)
        link = target / name
        try:
            link.symlink_to(state / name, target_is_directory=True)
        except FileExistsError:
            pass
        if not link.is_symlink() or link.resolve() != (state / name).resolve():
            raise RuntimeError("changed session binding")


def yolo_workspace(environment):
    """Validate the runtime-minted reservation before shell ticket inference.

    The parent holds the group/member leases and checks fresh Linear ownership.
    This boundary binds that reservation to the exact detached checkout and
    immutable project context; it does not grant an independent manual start.
    """
    scope = json.loads(environment["SYMPHONY_YOLO_SCOPE"])
    context = json.loads(zlib.decompress(base64.urlsafe_b64decode(environment["SYMPHONY_PROJECT_CONTEXT"])))
    group = scope["group"]
    run_id = str(uuid.UUID(scope["run_id"]))
    members = scope["members"]
    if (environment["SYMPHONY_LINEAR_AUTH_MODE"] != "app"
            or group not in ("incoming", "planning", "in_progress", "blocker", "review")
            or run_id != environment["SYMPHONY_RUN_ID"]
            or environment["SYMPHONY_PHASE"] != "YOLO " + group
            or not isinstance(members, list) or not members
            or not all(isinstance(member, str) and member for member in members)
            or len(set(members)) != len(members)
            or environment["SYMPHONY_ISSUE_ID"] not in members
            or not scope["agent_id"] or scope["agent_id"] != context["yolo_agent_id"]
            or not context["human_handoff_id"] or context["human_handoff_id"] not in context["assignee_ids"]
            or scope["project_context_id"] != context["root"]):
        raise ValueError("unbound YOLO group")

    project = Path(context["root"]).resolve(strict=True)
    root = Path(scope["workspace_root"]).resolve(strict=True)
    workspace = root / "yolo" / group / run_id
    if (not root.is_absolute() or not Path(scope["workspace_root"]).is_absolute()
            or workspace.resolve(strict=True) != workspace
            or str(workspace) != scope["workspace"]
            or str(project / ".symphony") != environment["SYMPHONY_LINEAR_ENV_DIR"]
            or str(workspace) != environment["SYMPHONY_ACTIVE_REPO_ROOT"]
            or Path.cwd() != workspace):
        raise ValueError("changed YOLO workspace")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(workspace), *args], stderr=subprocess.DEVNULL).decode().strip()

    if (git("rev-parse", "--show-toplevel") != str(workspace)
            or project_root(workspace) != project
            or git("branch", "--show-current")
            or git("rev-parse", "HEAD") != scope["sha"]
            or git("status", "--porcelain")):
        raise ValueError("changed YOLO checkout")
    return workspace


def main():
    if sys.argv[1:] == ["--validate-yolo-workspace"]:
        print(yolo_workspace(os.environ))
        return
    release = Path(os.environ["SYMPHONY_ROOT_DIR"]).resolve()
    state = Path(os.environ["SYMPHONY_CODEX_STATE_ROOT"])
    if not state.is_absolute():
        raise RuntimeError("unbound session state")
    original = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    target = profile_home(release, state, original, Path(os.environ["SYMPHONY_PROJECT_ROOT"]))
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("codex unavailable")
    env = dict(os.environ, CODEX_HOME=str(target))
    env.pop("LINEAR_API_KEY", None)
    env.pop("LINEAR_RELAY_KEY", None)
    env.pop(env.get("SYMPHONY_RELAY_KEY_ENV", "LINEAR_RELAY_KEY"), None)
    supplied = sys.argv[1:]
    index = 0
    while index < len(supplied) and supplied[index] in ("-c", "--config", "--model", "-m"):
        index += 2
    args = [executable, *supplied[:index],
            *launch_config(release, target, Path.cwd(), Path.home()), *supplied[index:]]
    # Global -c options must precede app-server/resume subcommands. These trusted
    # overrides come last among configuration options and cannot be bypassed by
    # a user's Linear MCP setting.
    os.execve(executable, args, env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, KeyError, ValueError, ImportError, TypeError, AttributeError, zlib.error, subprocess.CalledProcessError):
        print("sym-codex: Gebundener App-Kontext ist nicht verfügbar (Python 3.11+ erforderlich).", file=sys.stderr)
        sys.exit(1)
