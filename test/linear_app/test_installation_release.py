import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installation_release", REPO / "scripts/installation-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


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


class InstallationReleaseTest(GitFixture):
    def test_separate_checkouts_keep_workflow_skills_helpers_and_git_storage(self):
        first = release.snapshot(self.source, self.root / "first")
        (self.source / "WORKFLOW.md").write_text("new workflow\n")
        (self.source / "sym-codex").write_text("new helper\n")
        (self.source / ".codex/skills/symphony-test/SKILL.md").write_text("new skill\n")
        second = release.snapshot(self.source, self.root / "second")
        self.assertEqual((first / "WORKFLOW.md").read_text(), "old contents\n")
        self.assertEqual((first / "sym-codex").read_text(), "old contents\n")
        self.assertEqual((first / ".codex/skills/symphony-test/SKILL.md").read_text(), "old contents\n")
        self.assertEqual((second / "WORKFLOW.md").read_text(), "new workflow\n")
        self.assertNotEqual((first / "sym-codex").stat().st_ino, (self.source / "sym-codex").stat().st_ino)
        self.assertTrue((first / ".git").is_dir())
        self.assertTrue((second / ".git").is_dir())

    def test_deleted_tracked_file_stays_deleted_and_ignored_credentials_are_not_copied(self):
        (self.source / "sym-codex").unlink()
        (self.source / ".env.local").write_text("synthetic-secret")
        (self.source / "untracked-helper").write_text("new helper")
        snapshot = release.snapshot(self.source, self.root / "release")
        self.assertFalse((snapshot / "sym-codex").exists())
        self.assertFalse((snapshot / ".env.local").exists())
        self.assertTrue((snapshot / "untracked-helper").exists())

    def test_private_root_file_cannot_be_tracked_even_with_a_missing_ignore_rule(self):
        (self.source / ".env.local").write_text("LINEAR_APP_SECRET=synthetic-secret\n")
        self.git("add", "-f", ".env.local")
        with self.assertRaisesRegex(RuntimeError, "must be untracked"):
            release.snapshot(self.source, self.root / "release")
        self.assertFalse((self.root / "release").exists())

    def test_staged_deletions_and_renames_leave_no_head_files_in_the_snapshot(self):
        self.git("rm", "--quiet", "sym-codex")
        self.git("mv", "scripts/helper", "scripts/renamed-helper")
        snapshot = release.snapshot(self.source, self.root / "release")
        self.assertFalse((snapshot / "sym-codex").exists())
        self.assertFalse((snapshot / "scripts/helper").exists())
        self.assertEqual((snapshot / "scripts/renamed-helper").read_text(), "old contents\n")
        self.assertEqual((snapshot / "WORKFLOW.md").read_text(), "old contents\n")

    def test_staged_directory_replacement_is_a_file_in_the_snapshot(self):
        self.git("rm", "--quiet", "scripts/helper")
        (self.source / "scripts").write_text("replacement file\n")
        self.git("add", "scripts")
        snapshot = release.snapshot(self.source, self.root / "release")
        self.assertTrue((snapshot / "scripts").is_file())
        self.assertEqual((snapshot / "scripts").read_text(), "replacement file\n")

    def test_prepared_build_copies_files_and_rebinds_dependency_links_to_the_release(self):
        asset = self.source / "deps/demo/priv/asset"
        asset.parent.mkdir(parents=True)
        asset.write_text("built asset")
        compiled = self.source / "_build/dev/lib/demo"
        compiled.mkdir(parents=True)
        (compiled / "priv").symlink_to(asset.parent)
        (compiled / "module.beam").write_text("compiled module")
        (self.source / "_build/test").mkdir()
        with mock.patch.dict(os.environ, {"MIX_ENV": "dev"}):
            prepared = release.prepare(self.source)
        copied = prepared / "_build/dev/lib/demo"
        self.assertEqual((copied / "priv").resolve(), prepared / "deps/demo/priv")
        self.assertFalse((prepared / "_build/test").exists())
        asset.write_text("updated asset")
        (compiled / "module.beam").write_text("updated module")
        self.assertEqual((copied / "priv/asset").read_text(), "built asset")
        self.assertEqual((copied / "module.beam").read_text(), "compiled module")

    def test_sealing_records_actual_contents_without_touching_existing_global_links(self):
        old_link = self.root / "old-global-link"
        old_link.symlink_to(self.source / "sym-codex")
        snapshot = release.snapshot(self.source, self.root / "release")
        release.seal(snapshot)
        manifest = json.loads((snapshot / ".symphony-release.json").read_text())
        self.assertIn("WORKFLOW.md", manifest["files"])
        self.assertIn(".codex/skills/symphony-test/SKILL.md", manifest["files"])
        self.assertEqual(old_link.readlink(), self.source / "sym-codex")
        self.assertEqual(old_link.read_text(), "old contents\n")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            release.snapshot(self.source, snapshot)

    def test_sealed_helper_changes_fail_but_local_workflow_reload_remains_possible(self):
        snapshot = release.snapshot(self.source, self.root / "release")
        release.seal(snapshot)
        self.assertTrue(release.verify(snapshot)["revision"])
        (snapshot / "WORKFLOW.md").write_text("local workflow change")
        release.verify(snapshot)
        (snapshot / "sym-codex").write_text("unexpected helper change")
        with self.assertRaisesRegex(RuntimeError, "content changed"):
            release.verify(snapshot)
        with self.assertRaisesRegex(RuntimeError, "already sealed"):
            release.seal(snapshot)

    def test_capture_binds_project_cwd_before_sealing_and_rejects_config_tampering(self):
        snapshot = release.snapshot(self.source, self.root / "release")
        personal = self.root / "personal"
        personal.mkdir()
        # Even an unrelated Symphony root must never become the trusted project.
        with mock.patch.dict("os.environ", {"CODEX_HOME": str(personal), "SYMPHONY_ROOT_DIR": str(snapshot)}), \
             mock.patch.object(Path, "home", return_value=personal), \
             mock.patch.object(Path, "cwd", return_value=self.source), \
             mock.patch("os.walk", return_value=[]):
            release.capture_skills(snapshot)
        config = snapshot / ".symphony/codex/config.toml"
        self.assertEqual(tomllib.loads(config.read_text())["projects"], {
            str(self.source.resolve()): {"trust_level": "trusted"},
        })
        release.seal(snapshot)
        self.assertIn(".symphony/codex/config.toml", release.verify(snapshot)["files"])
        config.write_text(config.read_text() + '\n[mcp_servers.foreign]\ncommand = "foreign"\n')
        with self.assertRaisesRegex(RuntimeError, "content changed"):
            release.verify(snapshot)


class LauncherUpdateTest(GitFixture):
    def setUp(self):
        super().setUp()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.trace = self.root / "builds"
        for name in ("symphony", "autoupdate", "scripts/mix-runtime", "scripts/installation-release.py", "scripts/codex-app-context.py"):
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
    binary.write_text('#!/bin/bash\\nprintf "launched=%s\\\\n" "$SYMPHONY_RELEASE_ROOT"\\n')
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
        result = subprocess.run([sys.executable, str(self.source / "scripts/installation-release.py"),
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

    def test_declined_update_reuses_build_and_keeps_releases_independent(self):
        first = self.start()
        self.assertEqual(first.returncode, 0, first.stdout)
        old_head = self.git("rev-parse", "HEAD")
        self.push_update()
        builds = self.trace.read_text()
        second = self.start("Nein\n")
        self.assertEqual(second.returncode, 0, second.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), old_head)
        self.assertEqual(self.trace.read_text(), builds)
        first_release = Path(first.stdout.split("launched=")[1].strip())
        second_release = Path(second.stdout.split("launched=")[1].strip())
        self.assertNotEqual(first_release, second_release)
        first_artifact = first_release / "_build/dev/compiled"
        second_artifact = second_release / "_build/dev/compiled"
        self.assertNotEqual(first_artifact.stat().st_ino, second_artifact.stat().st_ino)
        (self.source / "_build/dev/compiled").write_text("changed build")
        self.assertEqual(first_artifact.read_text(), "old contents\n")
        self.assertEqual(second_artifact.read_text(), "old contents\n")

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
