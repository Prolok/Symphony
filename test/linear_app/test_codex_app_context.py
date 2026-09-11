import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
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
        self.project = self.root / 'Fachprojekt ä "quoted"'
        self.project.mkdir()
        subprocess.run(["git", "-C", str(self.project), "init", "-q"], check=True, capture_output=True)
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
        target = context.prepare(self.release, self.original, [self.original / "skills"], self.project)
        captured = json.loads((target / "skills.json").read_text())
        self.assertEqual(len(captured), 1)
        pinned = Path(captured[0]["path"])
        self.assertEqual(pinned, target / 'skills/symphony-test')
        (self.skill / "SKILL.md").write_text("changed global")
        (self.skill / "helper.py").write_text("changed helper")
        before = (target / "config.toml").read_bytes()
        self.assertEqual(context.prepare(self.release, self.original, [self.original / "skills"], self.personal), target)
        self.assertEqual((target / "config.toml").read_bytes(), before)
        self.assertEqual((pinned / "SKILL.md").read_text(), "original skill")
        self.assertEqual((pinned / "helper.py").read_text(), "original helper")
        self.assertNotIn("personal_linear", (target / "config.toml").read_text())
        self.assertTrue((target / "auth.json").is_symlink())

    def test_repo_skills_override_global_version_and_personal_project_mcps_are_disabled(self):
        local = self.release / ".codex/skills/symphony-test"
        local.mkdir(parents=True)
        (local / "SKILL.md").write_text("release skill")
        target = context.prepare(self.release, self.original, [self.original / "skills", local.parent], self.project)
        captured = json.loads((target / "skills.json").read_text())
        self.assertEqual(len(captured), 1)
        self.assertEqual((Path(captured[0]["path"]) / "SKILL.md").read_text(), "release skill")
        project = self.root / "project"
        (project / ".codex").mkdir(parents=True)
        (project / ".git").mkdir()
        (project / ".codex/config.toml").write_text(
            '[mcp_servers.personal_linear]\nurl="https://example.invalid"\n'
            '[mcp_servers."personal.with.dots"]\ncommand="foreign"\n'
            '[plugins."personal.plugin@market"]\nenabled=true\n'
        )
        with mock.patch.dict(os.environ, {"SYMPHONY_LINEAR_AUTH_MODE": "app", "SYMPHONY_LINEAR_CLIENT_SECRET_ENV": "SYMPHONY_TEST_SECRET", "SYMPHONY_LINEAR_BINDING_HASH": "fixed", "SYMPHONY_PYTHON": "/bound/python3", "LINEAR_API_KEY": "synthetic-personal"}):
            args = context.launch_config(self.release, target, project, self.personal)
        joined = " ".join(args)
        blocked = tomllib.loads(next(arg for arg in args if arg.startswith("mcp_servers={")))["mcp_servers"]
        self.assertEqual(set(blocked), {"personal_linear", "personal.with.dots"})
        self.assertTrue(all(server == {"enabled": False} for server in blocked.values()))
        self.assertIn('plugins={"personal.plugin@market"={enabled=false}}', args)
        self.assertNotIn("https://example.invalid", joined)
        self.assertNotIn('command="foreign"', joined)
        self.assertIn("mcp_servers.symphony_linear.required=true", joined)
        self.assertIn('"SYMPHONY_LINEAR_AUTH_MODE"="app"', joined)
        self.assertIn('"SYMPHONY_PYTHON"="/bound/python3"', joined)
        self.assertNotIn("synthetic-personal", joined)
        self.assertIn(str(self.skill), joined)

    def test_preparation_trusts_only_the_authorized_project_without_personal_config(self):
        target = context.prepare(self.release, self.original, [], self.project)
        self.assertEqual(tomllib.loads((target / "config.toml").read_text()), {
            "features": {"apps": False},
            "projects": {str(self.project.resolve()): {"trust_level": "trusted"}},
        })

    def test_non_git_project_uses_only_its_canonical_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            target = context.prepare(self.release, self.original, [], directory)
            self.assertEqual(tomllib.loads((target / "config.toml").read_text())["projects"], {
                str(Path(directory).resolve()): {"trust_level": "trusted"},
            })

    def test_project_trust_uses_git_common_root_from_subdirectories_and_worktrees(self):
        def git(*args):
            return subprocess.run(["git", "-C", str(self.project), *args], check=True, capture_output=True)

        git("init", "-q")
        git("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
            "commit", "--allow-empty", "-qm", "fixture")
        worktree = self.root / "worktrees" / "issue"
        git("worktree", "add", "--detach", str(worktree))
        alias = self.root / "project-link"
        alias.symlink_to(self.project, target_is_directory=True)
        for index, directory in enumerate([self.project, worktree, alias]):
            with self.subTest(directory=directory):
                nested = directory / "nested"
                nested.mkdir(exist_ok=True)
                target = context.prepare(self.root / str(index), self.original, [], nested)
                self.assertEqual(tomllib.loads((target / "config.toml").read_text())["projects"], {
                    str(self.project.resolve()): {"trust_level": "trusted"},
                })
