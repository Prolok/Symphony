import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("app_context", REPO / "scripts/codex-app-context.py")
context = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(context)


class AppContextTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=REPO / "_build")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.release = self.root / "release"
        self.release.mkdir()
        self.personal = self.root / "personal"
        self.original = self.personal / ".codex"
        self.original.mkdir(parents=True)
        (self.original / "auth.json").write_text("synthetic-openai")
        (self.original / "config.toml").write_text('[mcp_servers.personal_linear]\nurl="https://example.invalid"\n')
        self.skill = self.original / "skills/symphony-test"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text("original skill")
        (self.skill / "helper.py").write_text("original helper")

    def test_pinned_skills_keep_referenced_files_after_global_changes_and_second_start(self):
        target = context.prepare(self.release, self.original, [self.original / "skills"])
        captured = json.loads((target / "skills.json").read_text())
        self.assertEqual(len(captured), 1)
        pinned = Path(captured[0]["path"])
        self.assertEqual(pinned, target / 'skills/symphony-test')
        (self.skill / "SKILL.md").write_text("changed global")
        (self.skill / "helper.py").write_text("changed helper")
        self.assertEqual(context.prepare(self.release, self.original, [self.original / "skills"]), target)
        self.assertEqual((pinned / "SKILL.md").read_text(), "original skill")
        self.assertEqual((pinned / "helper.py").read_text(), "original helper")
        self.assertNotIn("personal_linear", (target / "config.toml").read_text())
        self.assertTrue((target / "auth.json").is_symlink())

    def test_repo_skills_override_global_version_and_personal_project_mcps_are_disabled(self):
        local = self.release / ".codex/skills/symphony-test"
        local.mkdir(parents=True)
        (local / "SKILL.md").write_text("release skill")
        target = context.prepare(self.release, self.original, [self.original / "skills", local.parent])
        captured = json.loads((target / "skills.json").read_text())
        self.assertEqual(len(captured), 1)
        self.assertEqual((Path(captured[0]["path"]) / "SKILL.md").read_text(), "release skill")
        project = self.root / "project"
        (project / ".codex").mkdir(parents=True)
        (project / ".git").mkdir()
        (project / ".codex/config.toml").write_text('[mcp_servers.personal_linear]\nurl="https://example.invalid"\n')
        with mock.patch.dict(os.environ, {"SYMPHONY_LINEAR_AUTH_MODE": "app", "SYMPHONY_LINEAR_CLIENT_SECRET_ENV": "SYMPHONY_TEST_SECRET", "SYMPHONY_LINEAR_BINDING_HASH": "fixed", "LINEAR_API_KEY": "synthetic-personal"}):
            args = context.launch_config(self.release, target, project, self.personal)
        joined = " ".join(args)
        self.assertIn('mcp_servers."personal_linear".enabled=false', joined)
        self.assertIn("mcp_servers.symphony_linear.required=true", joined)
        self.assertIn('"SYMPHONY_LINEAR_AUTH_MODE"="app"', joined)
        self.assertNotIn("synthetic-personal", joined)
        self.assertIn(str(self.skill), joined)
