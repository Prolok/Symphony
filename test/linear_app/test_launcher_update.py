import os
import fcntl
import importlib.util
import json
import time
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=REPO / "_build")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Synthetic")
        self.git("config", "user.email", "synthetic@example.invalid")
        for name in ("WORKFLOW.md", "sym-codex", "scripts/helper", ".codex/skills/symphony-test/SKILL.md"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("old contents\n")
        (self.source / ".gitignore").write_text("_build/\n.symphony/installations/\n.env.local\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], stderr=subprocess.DEVNULL)


class LauncherUpdateTest(GitFixture):
    def setUp(self):
        super().setUp()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.trace = self.root / "builds"
        for name in ("symphony", "autoupdate", "scripts/mix-runtime", "scripts/codex-app-context.py"):
            shutil.copy2(REPO / name, self.source / name)
        (self.source / ".gitignore").write_text("_build/\ndeps/\nbin/\n.symphony/\n.env.local\n")
        (self.source / "mise.toml").write_text('[tools]\nerlang = "28"\nelixir = "1.19.5-otp-28"\n')
        self.write_tool("mise", '''#!/bin/bash
case "$1" in
  ls) python3 -c 'import json,sys; print(json.dumps([{"installed": True, "active": True, "source": {"path": sys.argv[1] + "/mise.toml"}}]))' "$3" ;;
  env) exit 0 ;;
  exec) shift 2; exec "$@" ;;
  *) exit 1 ;;
esac
''')
        for tool in ("codex", "erl", "escript", "elixir"):
            self.write_tool(tool, "#!/bin/bash\nexit 0\n")
        self.write_tool("make", '#!/bin/bash\necho "gate $PWD" >> "$BUILD_TRACE"\nexit "${GATE_STATUS:-0}"\n')
        self.write_tool("mix", '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path.cwd()
compiled = root / "_build/dev/compiled"
if sys.argv[1] == "deps.loadpaths":
    sys.exit(0 if (root / "deps").exists() else 1)
if sys.argv[1] == "deps.get":
    (root / "deps").mkdir(exist_ok=True)
if sys.argv[1] == "compile":
    contents = (root / "WORKFLOW.md").read_text()
    if not compiled.exists() or compiled.read_text() != contents:
        with open(os.environ["BUILD_TRACE"], "a") as trace:
            trace.write("compile " + str(root) + "\\n")
        compiled.parent.mkdir(parents=True, exist_ok=True)
        compiled.write_text(contents)
if sys.argv[1] == "escript.build":
    with open(os.environ["BUILD_TRACE"], "a") as trace:
        trace.write("escript " + str(root) + "\\n")
    binary = root / "bin/symphony"
    binary.parent.mkdir(exist_ok=True)
    binary.write_text('#!/bin/bash\\nprintf "launched=%s\\\\n" "$SYMPHONY_ROOT_DIR"\\n')
    binary.chmod(0o755)
''')
        self.git("add", ".")
        self.git("commit", "-qm", "launcher fixture")
        self.remote = self.root / "remote.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(self.source), str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-qu", "origin", "main")
        self.seed = self.root / "seed"
        subprocess.run(["git", "clone", "-q", str(self.remote), str(self.seed)], check=True)

    def write_tool(self, name, contents):
        path = self.tools / name
        path.write_text(contents)
        path.chmod(0o755)

    def push_update(self):
        (self.seed / "WORKFLOW.md").write_text("updated workflow\n")
        for args in (("add", "."), ("-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid", "commit", "-qm", "update"), ("push", "-q")):
            subprocess.run(["git", "-C", str(self.seed), *args], check=True)
        return subprocess.check_output(["git", "-C", str(self.seed), "rev-parse", "HEAD"])

    def start(self, answer="", flags=(), launcher=None, **overrides):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("SYMPHONY_", "MIX_"))}
        env.update(HOME=str(self.home), CODEX_HOME=str(self.home / ".codex"),
                   PATH=str(self.tools) + os.pathsep + os.environ["PATH"], BUILD_TRACE=str(self.trace), **overrides)
        command = ([str(launcher)] if launcher else [str(self.source / "scripts/mix-runtime"), "start", str(self.source), "symphony"])
        result = subprocess.run(command + list(flags),
                                cwd=self.root, env=env, input=answer, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        return result

    def test_explicit_test_launcher_and_ticket_alias_build_pinned_source_without_update(self):
        for name in ("service-lock.py", "test-instance.py", "test-processes.py"):
            shutil.copy2(REPO / "scripts" / name, self.source / "scripts" / name)
        spec = importlib.util.spec_from_file_location("test_instance", REPO / "scripts/test-instance.py")
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        fixtures = self.root / "fixtures"
        projects = {}
        for i, (name, workspace) in enumerate(helper.PROJECTS.items(), 1):
            (fixtures / name / ".symphony").mkdir(parents=True)
            projects[name] = dict(workspace=workspace, workspace_id=str(i)*8+"-1111-1111-1111-111111111111",
                                  project_id=str(i+2)*8+"-1111-1111-1111-111111111111", slug_id=name,
                                  teams=[dict(id='team-' + workspace, key='PRO' if workspace == 'prolok' else 'PRI')],
                                  verified_at=time.time())
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps(dict(project_root=str(fixtures), workspace_root=str(self.root / "worktrees"),
                            fixtures_idle=True, projects=projects,
                            main_instance=dict(pid=os.getpid(), started=helper.process_started(os.getpid()), sha="a"*40,
                            verified_at=time.time(), projects=[dict(workspace_id="other",project_id="main",
                            root=str(self.root/"main"),workspace_root=str(self.root/"main-worktrees"))]))))
        revision=helper.source(self.source)
        self.push_update()
        lock_path=self.home/".cache/symphony/service.lock"
        lock_path.parent.mkdir(parents=True)
        alias=self.root/"symphony-PRO-736"
        alias.symlink_to(self.source/"symphony")
        with lock_path.open('a') as main_lock:
            fcntl.flock(main_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            for launcher in (self.source/"symphony",alias):
                result=self.start(flags=["--test-instance","dev","--port","4101"], launcher=launcher,
                                  SYMPHONY_TEST_MANIFEST=str(manifest),SYM_PROJECT_ROOT=str(fixtures),
                                  SYMPHONY_TEST_EXPECTED_SHA=revision['sha'],SYMPHONY_TEST_EXPECTED_SOURCE=revision['source_sha256'])
                self.assertEqual(result.returncode,0,result.stdout)
                self.assertNotIn('Update ausführen',result.stdout)
                self.assertEqual(self.git('rev-parse','HEAD').decode().strip(),revision['sha'])
                stamp=json.loads((self.source/'_build/symphony-source.json').read_text())
                self.assertEqual(stamp,revision)
                # Owner exit is followed by the guardian's short cleanup interval.
                time.sleep(.2)
        self.assertFalse((self.home/'.local/bin').exists())

    def test_accepted_update_persists_and_next_start_reuses_compiled_version(self):
        remote_head = self.push_update()
        first = self.start("Ja\n")
        self.assertEqual(first.returncode, 0, first.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), remote_head)
        builds = self.trace.read_text()
        second = self.start()
        self.assertEqual(second.returncode, 0, second.stdout)
        self.assertNotIn("Update ausführen", second.stdout)
        self.assertEqual(self.trace.read_text(), builds)

    def test_declined_update_reuses_checkout_and_build_without_runtime_copies(self):
        first = self.start()
        self.assertEqual(first.returncode, 0, first.stdout)
        old_head = self.git("rev-parse", "HEAD")
        self.push_update()
        builds = self.trace.read_text()
        second = self.start("Nein\n")
        self.assertEqual(second.returncode, 0, second.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), old_head)
        self.assertEqual(self.trace.read_text(), builds)
        for result in (first, second):
            self.assertEqual(Path(result.stdout.split("launched=")[1].strip()), self.source)
        self.assertFalse((self.source / ".symphony/installations").exists())
        self.assertEqual((self.source / "_build/dev/compiled").read_text(), "old contents\n")

    def test_failed_update_gate_blocks_launch_and_is_retried_on_next_start(self):
        remote_head = self.push_update()
        for answer in ("Ja\n", ""):
            result = self.start(answer, GATE_STATUS="9")
            self.assertEqual(result.returncode, 9, result.stdout)
            self.assertNotIn("launched=", result.stdout)
            self.assertEqual(self.git("rev-parse", "HEAD"), remote_head)
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("launched=", result.stdout)
        self.assertEqual(self.trace.read_text().count("gate "), 3)
        self.assertEqual(self.trace.read_text().count("compile "), 1)

    def test_changed_modules_and_missing_binary_rebuild_the_escript(self):
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stdout)
        beam = self.source / "_build/dev/lib/demo/ebin/module.beam"
        beam.parent.mkdir(parents=True)
        changes = (lambda: beam.write_text("new module"), beam.unlink,
                   lambda: (self.source / "bin/symphony").unlink())
        for expected, change in enumerate(changes, start=2):
            change()
            result = self.start()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(self.trace.read_text().count("escript "), expected)


if __name__ == "__main__":
    unittest.main()
