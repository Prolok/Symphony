#!/usr/bin/env python3
"""Prepare a private Symphony checkout before updating or building a launcher.

The source checkout, global skills and CLI links are never changed. Every start
gets a distinct release directory, including its Git metadata and build output.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL)


def snapshot(source, destination):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    if destination.exists():
        raise RuntimeError("release already exists")
    if git(source, "ls-files", "--", ".env.local").strip():
        raise RuntimeError("private root configuration must be untracked")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", "--no-checkout", str(source), str(destination)], check=True)
    revision = git(source, "rev-parse", "HEAD").decode().strip()
    subprocess.run(["git", "-C", str(destination), "checkout", "--quiet", "--detach", revision], check=True)
    # Include the exact working state in developer runs. No ignored secrets,
    # shared dependencies, build products, worktrees or nested release copies.
    tracked = git(source, "ls-files", "-z").split(b"\0")
    paths = git(source, "ls-files", "-c", "-o", "--exclude-standard", "-z").split(b"\0")
    for raw in set(paths):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        origin, target = source / relative, destination / relative
        if origin.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink():
                target.unlink()
            shutil.copy2(origin, target, follow_symlinks=True)
        elif raw in tracked and not origin.exists() and target.exists():
            target.unlink()
    try:
        upstream = git(source, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}").decode().strip()
    except subprocess.CalledProcessError:
        return destination
    remote, branch = upstream.split("/", 1)
    url = git(source, "remote", "get-url", remote).decode().strip()
    subprocess.run(["git", "-C", str(destination), "remote", "set-url", "origin", url], check=True)
    local_branch = git(source, "branch", "--show-current").decode().strip()
    if local_branch:
        subprocess.run(["git", "-C", str(destination), "checkout", "--quiet", "-B", local_branch], check=True)
        subprocess.run(["git", "-C", str(destination), "config", "branch." + local_branch + ".remote", "origin"], check=True)
        subprocess.run(["git", "-C", str(destination), "config", "branch." + local_branch + ".merge", "refs/heads/" + branch], check=True)
    return destination


def capture_skills(release):
    spec = importlib.util.spec_from_file_location("codex_app_context", Path(__file__).with_name("codex-app-context.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    module.prepare(release, original, [original / "skills", Path.home() / ".agents/skills", Path("/etc/codex/skills"), Path(release) / ".codex/skills"])


def seal(release):
    release = Path(release).resolve()
    if (release / ".symphony-release.json").exists():
        raise RuntimeError("release already sealed")
    manifest = {}
    for name in ("lib", "priv", "scripts", ".codex/skills", ".symphony/codex/skills", "bin", "_build"):
        directory = release / name
        if directory.is_dir():
            for path in directory.rglob("*"):
                if path.is_file():
                    manifest[str(path.relative_to(release))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ("WORKFLOW.md", "WORKFLOW_DIALOG.md", "WORKFLOW_INTERACTIVE.md", "symphony", "sym-codex", "sym-codex-mcp", "sym-watch", "mix.exs", "mix.lock", "mise.toml", ".symphony/codex/config.toml", ".symphony/codex/skills.json", ".symphony/root-config.json"):
        path = release / name
        if path.is_file():
            manifest[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (release / ".symphony-release.json").write_text(json.dumps({"revision": git(release, "rev-parse", "HEAD").decode().strip(), "files": manifest}, sort_keys=True))


def verify(release):
    release = Path(release).resolve()
    manifest = json.loads((release / ".symphony-release.json").read_text())
    for name, expected in manifest["files"].items():
        # The local workflow remains reloadable. Auth-binding changes are
        # rejected by WorkflowStore and the per-turn configuration hash.
        if name in ("WORKFLOW.md", "WORKFLOW_DIALOG.md", "WORKFLOW_INTERACTIVE.md"):
            continue
        path = release / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("release content changed")
    return manifest


def main():
    action, source, *args = sys.argv[1:]
    if action == "app-workflow":
        # Only selects release preparation, never credentials or auth semantics.
        # Config.Schema remains the authoritative YAML/config validator.
        front = (Path(source) / "WORKFLOW.md").read_text().split("---", 2)[1]
        sys.exit(0 if re.search(r'[\"\x27]?auth_mode[\"\x27]?\s*:\s*[\"\x27]?app\b', front) else 1)
    if action == "verify":
        verify(source)
        return
    if action == "seal":
        capture_skills(source)
        seal(source)
        return
    if action not in ("start", "codex"):
        raise RuntimeError("unknown release action")
    root = Path(source) / ".symphony" / "installations"
    release = snapshot(source, root / str(uuid.uuid4()))
    env = dict(os.environ, SYMPHONY_RELEASE_ROOT=str(release), SYMPHONY_ROOT_DIR=str(Path(source).resolve()))
    if action == "codex":
        env["SYMPHONY_LAUNCH_CODEX"] = "1"
    env.pop("SYMPHONY_LINEAR_AUTH_MODE", None)
    env.pop("SYMPHONY_LINEAR_BINDING_HASH", None)
    print("symphony: Eigener Laufzeitstand " + str(release), file=sys.stderr)
    os.execve(str(release / "scripts/mix-runtime"), [str(release / "scripts/mix-runtime"), "start", str(release), *args], env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        print("symphony: Isolierter Laufzeitstand konnte nicht vorbereitet werden.", file=sys.stderr)
        sys.exit(1)
