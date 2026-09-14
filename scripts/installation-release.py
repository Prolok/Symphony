#!/usr/bin/env python3
"""Copy the updated, incrementally built installation into a private runtime.

Every start gets distinct Git metadata and build files. Running releases,
global skills and CLI links are never changed by subsequent updates or builds.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
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
    # Clear the cloned HEAD files first: staged removals are already absent
    # from the source index, and old file paths may now be directories.
    for raw in git(destination, "ls-files", "-z").split(b"\0"):
        if raw:
            target = destination / Path(os.fsdecode(raw))
            if target.is_file() or target.is_symlink():
                target.unlink()
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
            elif target.is_dir():
                shutil.rmtree(target)
            shutil.copy2(origin, target, follow_symlinks=True)
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
    # The launcher preserves the operator's project cwd through update/build.
    # Neither the release nor SYMPHONY_ROOT_DIR identifies that Fachprojekt.
    module.prepare(release, original, [Path(release) / ".codex/skills"], Path.cwd())


def prepare(source):
    source = Path(source).resolve()
    release = snapshot(source, source / ".symphony/installations" / str(uuid.uuid4()))
    environment = os.environ.get("MIX_ENV", "dev")
    target_name = os.environ.get("MIX_TARGET", "host")
    build_name = environment if target_name == "host" else target_name + "_" + environment
    # Keep Mix incremental in the installation. Runtime copies must never
    # share writable build files or links back to that mutable checkout.
    for name in ("deps", "_build/" + build_name, "bin", "priv/static/assets"):
        origin, target = source / name, release / name
        if not origin.is_dir():
            continue
        shutil.copytree(origin, target, symlinks=True, dirs_exist_ok=True)
        for link in target.rglob("*"):
            if link.is_symlink():
                original = source / link.relative_to(release)
                try:
                    relative = original.resolve().relative_to(source)
                except ValueError as error:
                    raise RuntimeError("build symlink points outside installation") from error
                link.unlink()
                link.symlink_to(os.path.relpath(release / relative, link.parent))
    return release


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
    if action == "verify":
        verify(source)
        return
    if action == "seal":
        capture_skills(source)
        seal(source)
        return
    if action == "prepare":
        print(prepare(source))
        return
    if action not in ("start", "codex"):
        raise RuntimeError("unknown release action")
    source = Path(source).resolve()
    env = dict(os.environ, SYMPHONY_ROOT_DIR=str(source))
    env.pop("SYMPHONY_RELEASE_ROOT", None)
    if action == "codex":
        env["SYMPHONY_LAUNCH_CODEX"] = "1"
    env.pop("SYMPHONY_LINEAR_AUTH_MODE", None)
    env.pop("SYMPHONY_LINEAR_BINDING_HASH", None)
    os.execve(str(source / "scripts/mix-runtime"), [str(source / "scripts/mix-runtime"), "start", str(source), *args], env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        print("symphony: Isolierter Laufzeitstand konnte nicht vorbereitet werden.", file=sys.stderr)
        sys.exit(1)
