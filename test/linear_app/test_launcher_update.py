import os
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

    def start(self, answer="", **overrides):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("SYMPHONY_", "MIX_"))}
        env.update(HOME=str(self.home), CODEX_HOME=str(self.home / ".codex"),
                   PATH=str(self.tools) + os.pathsep + os.environ["PATH"], BUILD_TRACE=str(self.trace), **overrides)
        result = subprocess.run([str(self.source / "scripts/mix-runtime"),
                                 "start", str(self.source), "symphony"],
                                cwd=self.root, env=env, input=answer, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        return result

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
