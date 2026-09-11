import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installation_release", REPO / "scripts/installation-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class InstallationReleaseTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
