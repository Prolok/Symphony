#!/usr/bin/env python3
"""Bind app-mode Codex skills/configuration to one release, without Linear secrets."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


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


def prepare(release, original_home, skill_roots, project_dir):
    release, original_home = Path(release).resolve(), Path(original_home)
    target = release / ".symphony" / "codex"
    if (target / "skills.json").is_file():
        return target
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    skills = target / "skills"
    skills.mkdir(exist_ok=True)
    captured = []
    # Caller serializes preparation before any worker is started. Copy contents,
    # including referenced helper files; never keep links to mutable skill roots.
    selected = {}
    for root in skill_roots:
        selected.update({entry.name: entry for entry in skill_directories(root)})
    for entry in selected.values():
        destination = skills / entry.name
        shutil.copytree(entry, destination, dirs_exist_ok=True, symlinks=False)
        captured.append({"source": str(entry), "path": str(destination)})
    auth = original_home / "auth.json"
    if auth.is_file() and not (target / "auth.json").exists():
        # OpenAI login stays in its existing credential location. This helper
        # neither reads its content nor copies it into a release.
        (target / "auth.json").symlink_to(auth.resolve())
    # The operator's project start authorizes this one repository, including its
    # worktrees. Codex otherwise persists this trust during thread/start, after
    # sealing, and the required MCP correctly rejects the changed release.
    project = json.dumps(str(project_root(project_dir)), ensure_ascii=False)
    (target / "config.toml").write_text(
        '[features]\napps = false\n\n[projects.' + project + ']\ntrust_level = "trusted"\n'
    )
    (target / "skills.json").write_text(json.dumps(captured))
    return target


def launch_config(release, target, cwd, user_home, environment=None):
    import tomllib
    environment = os.environ if environment is None else environment
    captured = json.loads((target / "skills.json").read_text())
    roots = [user_home / ".agents/skills", user_home / ".codex/skills", Path("/etc/codex/skills")]
    configs = [Path("/etc/codex/config.toml")]
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
    args = ["--config", "skills.config=" + overrides, "--config", "features.apps=false"]
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
    names = ("SYMPHONY_RELEASE_ROOT", "SYMPHONY_ROOT_DIR", "SYMPHONY_LINEAR_ENV_DIR", "SYMPHONY_LINEAR_AUTH_MODE", "SYMPHONY_LINEAR_CLIENT_SECRET_ENV", "SYMPHONY_LINEAR_BINDING_HASH",
             "SYMPHONY_RUN_ID", "SYMPHONY_PHASE", "SYMPHONY_ISSUE_ID", "SYMPHONY_ISSUE_IDENTIFIER",
             "SYMPHONY_SOURCE_REPO", "SYMPHONY_PROJECT_ROOT", "SYMPHONY_WORKFLOW_FILE", "SYMPHONY_CODEX_STATE_ROOT", "SYMPHONY_PYTHON")
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
    allowed = sorted({name for name in environment if name.upper() not in {secret_name.upper(), "LINEAR_API_KEY", "LINEAR_APP_SECRET"}} | {"SYMPHONY_LINEAR_SECRET_ACCESS"})
    args.extend(["--config", "shell_environment_policy.exclude=" + json.dumps([secret_name, "LINEAR_API_KEY", "LINEAR_APP_SECRET"]),
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


def main():
    release = Path(os.environ["SYMPHONY_RELEASE_ROOT"]).resolve()
    if not (release / ".symphony-release.json").is_file():
        raise RuntimeError("unbound release")
    target = release / ".symphony/codex"
    if not (target / "skills.json").is_file():
        raise RuntimeError("skills not captured before startup")
    state = Path(os.environ["SYMPHONY_CODEX_STATE_ROOT"])
    if not state.is_absolute():
        raise RuntimeError("unbound session state")
    bind_sessions(target, state)
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("codex unavailable")
    env = dict(os.environ, CODEX_HOME=str(target))
    env.pop("LINEAR_API_KEY", None)
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
    except (OSError, RuntimeError, KeyError, ValueError, ImportError):
        print("sym-codex: Gebundener App-Kontext ist nicht verfügbar (Python 3.11+ erforderlich).", file=sys.stderr)
        sys.exit(1)
