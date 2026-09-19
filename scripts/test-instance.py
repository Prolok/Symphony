#!/usr/bin/env python3
"""Public preflight shared by test launchers and direct escript starts.

No credential files are read here. Live binding verification belongs to the
bound Elixir client, before the project supervisors are started.
"""

import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

PROJECTS = {"symphony-test": "prolok"}
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}\Z")
UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\Z")


def instance_name(args):
    values = []
    for index, arg in enumerate(args):
        if arg == "--test-instance":
            values.append(args[index + 1] if index + 1 < len(args) else "")
        elif arg.startswith("--test-instance="):
            values.append(arg.split("=", 1)[1])
    if not values:
        return None
    if len(values) != 1 or not NAME.fullmatch(values[0]):
        raise ValueError("--test-instance verlangt genau einen Namen (1–48 Buchstaben, Ziffern, _ oder -)")
    return values[0]


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL)


def source(repo):
    repo = Path(repo).resolve(strict=True)
    head = git(repo, "rev-parse", "HEAD").decode().strip()
    # Include tracked files and nonignored additions, including mode/symlink
    # changes. Never include ignored local credentials or generated artifacts.
    names = set(git(repo, "ls-files", "-z").split(b"\0"))
    names.update(git(repo, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"))
    digest = hashlib.sha256()
    for raw in sorted(names - {b""}):
        path = repo / os.fsdecode(raw)
        digest.update(raw + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode & 0o777).encode() + b"\0" + path.read_bytes())
        else:
            digest.update(b"missing\0")
    return {"checkout": str(repo), "sha": head, "source_sha256": digest.hexdigest(),
            "dirty": bool(git(repo, "status", "--porcelain", "--untracked-files=normal"))}


def canonical(path):
    expanded = Path(path).expanduser().absolute()
    if expanded != expanded.resolve():
        raise ValueError("Testpfade dürfen keine Symlink-Aliase enthalten")
    return expanded


def read_manifest(path, project_root):
    path = canonical(path)
    if path.stat().st_size > 65536:
        raise ValueError("Testmanifest ist zu groß")
    value = json.loads(path.read_text())
    root = canonical(value["project_root"])
    if str(root) != str(canonical(project_root)) or "," in project_root:
        raise ValueError("SYM_PROJECT_ROOT muss genau den isolierten Testroot bezeichnen")
    if (root / ".symphony").exists():
        raise ValueError("Der Testsammelroot darf keine .symphony enthalten")
    found = {p.name for p in root.iterdir() if (p / ".symphony").is_dir()}
    if found != PROJECTS.keys():
        raise ValueError("Testdiscovery verlangt ausschließlich symphony-test")
    bindings = value["projects"]
    if not isinstance(bindings, dict) or bindings.keys() != PROJECTS.keys():
        raise ValueError("Testmanifest muss genau das freigegebene Dummy-Projekt binden")
    for name, workspace in PROJECTS.items():
        canonical(root / name)
        canonical(root / name / ".symphony")
        binding = bindings[name]
        if binding["workspace"] != workspace or not all(UUID.fullmatch(binding[k]) for k in ("workspace_id", "project_id")):
            raise ValueError("Ungültige Dummy-Workspace-/Projektbindung")
        if not isinstance(binding["slug_id"], str) or not binding["slug_id"]:
            raise ValueError("Dummy-Projektslug fehlt")
        verified_teams(binding)
    return value


def verified_teams(binding):
    teams = binding.get('teams')
    if (not isinstance(teams, list) or not teams
            or any(not isinstance(t, dict) or not all(isinstance(t.get(k), str) and t[k].strip() == t[k] and t[k]
                                                     for k in ('id', 'key')) for t in teams)):
        raise ValueError('Vollständige verifizierte Projektteams fehlen')
    ids, keys = {t['id'] for t in teams}, {t['key'] for t in teams}
    if len(ids) != len(teams) or len(keys) != len(teams):
        raise ValueError('Mehrdeutige Projektteams')
    return ids, keys


def process_started(pid):
    if type(pid) is not int or pid <= 1:
        raise ValueError("Hauptprozess fehlt")
    return subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart="], stderr=subprocess.DEVNULL).decode().strip()


def normal_service_running(path=None):
    path = path or Path.home().resolve() / ".cache/symphony/service.lock"
    with open(path, "r") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False


def validate_main(manifest):
    main = manifest["main_instance"]
    if not normal_service_running():
        raise ValueError("Die normale Hauptdienstsperre ist nicht belegt")
    if not main["started"] or process_started(main["pid"]) != main["started"]:
        raise ValueError("Hauptinstanzbeleg gehört nicht zum laufenden Prozess")
    if not re.fullmatch(r"[a-f0-9]{40}", main["sha"]):
        raise ValueError("Quellstand der Hauptinstanz fehlt")
    if not 0 <= time.time() - main["verified_at"] <= 3600 or manifest["fixtures_idle"] is not True:
        raise ValueError("Frischer Betreiberbeleg nach Neustart und freie Fixtures erforderlich")
    scopes = main["projects"]
    if not isinstance(scopes, list) or not scopes:
        raise ValueError("Tatsächlich geladene Hauptprojektbindungen fehlen")
    expected = manifest["projects"].values()
    for fixture in expected:
        verified_teams(fixture)
        if not 0 <= time.time() - fixture['verified_at'] <= 3600:
            raise ValueError('Frischer Projekt-/Teambeleg erforderlich')
    for scope in scopes:
        if not scope.get("workspace_id") or bool(scope.get("project_id")) == bool(scope.get("team_key")):
            raise ValueError("Mehrdeutige Hauptprojektbindung")
        if scope.get('team_key') and not all(isinstance(scope.get(k), str) and scope[k].strip() == scope[k] and scope[k]
                                             for k in ('team_id', 'team_key')):
            raise ValueError('Verifizierte Hauptteambindung fehlt')
        for reserved in (canonical(manifest["workspace_root"]), canonical(manifest["project_root"])):
            for occupied in (canonical(scope["root"]), canonical(scope["workspace_root"])):
                if reserved.is_relative_to(occupied) or occupied.is_relative_to(reserved):
                    raise ValueError("Testpfade überlappen mit einem Hauptprojektbereich")
        for fixture in expected:
            ids, keys = verified_teams(fixture)
            if scope["workspace_id"] == fixture["workspace_id"] and (
                    scope.get('team_id') in ids or scope.get('team_key') in keys
                    or scope.get('project_id') == fixture['project_id']):
                raise ValueError("Hauptinstanz und Testfixtures überlappen")


def preflight(name, repo, env=None):
    env = os.environ if env is None else env
    if not NAME.fullmatch(name):
        raise ValueError("Ungültiger Testinstanzname")
    manifest = read_manifest(env["SYMPHONY_TEST_MANIFEST"], env["SYM_PROJECT_ROOT"])
    # Cleanup is restricted by the durable runtime journal. It remains possible
    # after loss/restart of the main process; no new worker may start then.
    if env.get("SYMPHONY_TEST_RUN_STAGE") != "cleanup":
        validate_main(manifest)
        if env.get("SYMPHONY_SERVICE_GUARD_PID"):
            process_started(int(env["SYMPHONY_SERVICE_GUARD_PID"]))
        revision = source(repo)
    else:
        # Recovery invokes the already built escript. Its embedded fingerprint
        # must match this stamp and the durable plan, even after source edits.
        revision = json.loads((Path(repo) / "_build/symphony-source.json").read_text())
    root = canonical(manifest["project_root"])
    if Path(revision["checkout"]).is_relative_to(root):
        raise ValueError("Testquellcode muss außerhalb der Fixture-Discovery liegen")
    if revision["sha"] != env["SYMPHONY_TEST_EXPECTED_SHA"] or revision["source_sha256"] != env["SYMPHONY_TEST_EXPECTED_SOURCE"]:
        raise ValueError("Testquellstand stimmt nicht mit der erwarteten SHA/Quellkennung überein")
    capsule = {"name": name, "manifest": manifest, "source": revision}
    recovery = env.get("SYMPHONY_TEST_CLEANUP_PLAN_SHA256")
    if recovery:
        if env.get("SYMPHONY_TEST_RUN_STAGE") != "cleanup" or revision != source(repo):
            raise ValueError("Cleanup-Recovery verlangt den unveränderten korrigierten Build und ausschließlich Cleanup")
        path = canonical(env["SYMPHONY_TEST_RUN_PLAN"])
        raw = path.read_bytes()
        plan = json.loads(raw)
        if (not re.fullmatch(r"[0-9a-f]{64}", recovery) or hashlib.sha256(raw).hexdigest() != recovery
                or plan.get("evidence") != "live" or plan.get("instance") != name
                or not NAME.fullmatch(plan.get("run_id", ""))
                or plan.get("source", {}).get("checkout") != str(canonical(repo))):
            raise ValueError("Cleanup-Recovery gehört nicht zum unveränderten ursprünglichen Laufplan")
        capsule["cleanup_recovery"] = {"plan_path": str(path), "plan_sha256": recovery, "source": plan["source"]}
    return capsule


if __name__ == "__main__":
    try:
        if sys.argv[1] == "source" and len(sys.argv) == 3:
            result = source(sys.argv[2])
        elif sys.argv[1] == "preflight" and len(sys.argv) == 4:
            result = preflight(sys.argv[2], sys.argv[3])
        elif sys.argv[1] == "stamp" and len(sys.argv) == 3:
            result = source(sys.argv[2])
            path = Path(sys.argv[2]) / "_build/symphony-source.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            contents = json.dumps(result, sort_keys=True)
            if not path.exists() or path.read_text() != contents:
                temporary = path.with_suffix(".tmp")
                temporary.write_text(contents)
                temporary.replace(path)
        else:
            raise ValueError("usage: test-instance.py source checkout | preflight name checkout")
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        sys.exit("Teststart abgewiesen: öffentliche Testbindung, Pfade und erwarteten Quellstand prüfen")
