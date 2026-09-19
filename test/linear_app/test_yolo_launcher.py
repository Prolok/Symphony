"""Exercise the installed shell/profile boundary with real detached Git worktrees."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib


REPO = Path(__file__).resolve().parents[2]


class YoloLauncherTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=REPO / "_build")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.release = self.root / "installation"
        (self.release / "scripts").mkdir(parents=True)
        for name in ("sym-codex", "sym-codex-mcp", "scripts/codex-app-context.py"):
            shutil.copy2(REPO / name, self.release / name)
        for name in ("WORKFLOW.md", "mix.exs"):
            (self.release / name).touch()
        self.project = self.root / "Fachprojekt ä"
        self.project.mkdir()
        self.git(self.project, "init", "-b", "main")
        (self.project / "tracked").write_text("merged state\n")
        self.git(self.project, "add", "tracked")
        self.git(self.project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        self.sha = self.git(self.project, "rev-parse", "HEAD")
        self.run_id = str(uuid.uuid4())
        self.workspace_root = self.root / "workspaces"
        self.workspace = self.workspace_root / "yolo/incoming" / self.run_id
        self.git(self.project, "worktree", "add", "--detach", str(self.workspace), self.sha)
        self.member = str(uuid.uuid4())
        self.scope = {"group": "incoming", "run_id": self.run_id, "members": [self.member],
                      "agent_id": "pai", "project_context_id": str(self.project),
                      "workspace": str(self.workspace), "sha": self.sha,
                      "workspace_root": str(self.workspace_root)}
        self.context = {"root": str(self.project), "yolo_agent_id": "pai",
                        "human_handoff_id": "human", "assignee_ids": ["human"]}
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        codex = self.bin / "codex"
        codex.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                         "print(json.dumps({'cwd': os.getcwd(), 'args': sys.argv[1:], "
                         "'home': os.environ['CODEX_HOME'], 'scope': os.environ.get('SYMPHONY_YOLO_SCOPE')}))\n")
        codex.chmod(0o755)
        self.env = {"PATH": str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": str(self.root / "personal"), "CODEX_HOME": str(self.root / "personal/.codex"),
                    "SYMPHONY_PYTHON": sys.executable, "SYMPHONY_LINEAR_AUTH_MODE": "app",
                    "SYMPHONY_LINEAR_CLIENT_SECRET_ENV": "SYNTHETIC_TEST_SECRET",
                    "SYMPHONY_LINEAR_SECRET_ACCESS": "denied",
                    "SYMPHONY_LINEAR_ENV_DIR": str(self.project / ".symphony"),
                    "SYMPHONY_CODEX_STATE_ROOT": str(self.root / "state"),
                    "SYMPHONY_PROJECT_WORKTREES_ROOT": str(self.workspace_root),
                    "SYMPHONY_ACTIVE_REPO_ROOT": str(self.workspace),
                    "SYMPHONY_ISSUE_ID": self.member, "SYMPHONY_ISSUE_IDENTIFIER": "PRI-129",
                    "SYMPHONY_RUN_ID": self.run_id, "SYMPHONY_PHASE": "YOLO incoming"}

    @staticmethod
    def git(root, *args):
        return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def launch(self, scope=None, env=None, cwd=None, args=None):
        binding = base64.urlsafe_b64encode(zlib.compress(json.dumps(self.context).encode())).decode()
        launch_env = dict(self.env, SYMPHONY_PROJECT_CONTEXT=binding,
                          SYMPHONY_YOLO_SCOPE=json.dumps(self.scope if scope is None else scope))
        launch_env.update(env or {})
        return subprocess.run(["/bin/bash", str(self.release / "sym-codex"), *(args or ["--app-server"])],
                              cwd=cwd or self.workspace, env=launch_env, capture_output=True, text=True, timeout=15)

    def test_bound_detached_checkout_reaches_codex_with_project_profile_and_mcp(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["cwd"], str(self.workspace))
        self.assertEqual(json.loads(output["scope"]), self.scope)
        profile = Path(output["home"])
        self.assertTrue(profile.is_relative_to(self.root / "state/profiles"))
        self.assertIn(str(self.project), (profile / "config.toml").read_text())
        args = output["args"]
        self.assertEqual(args[-1], "app-server")
        self.assertIn("features.memories=false", args)
        mcp = next(arg for arg in args if arg.startswith("mcp_servers.symphony_linear.env="))
        self.assertIn("SYMPHONY_YOLO_SCOPE", mcp)
        self.assertIn(self.run_id, mcp)
        self.assertIn(str(self.release / "sym-codex-mcp"), " ".join(args))
        self.assertEqual(self.git(self.workspace, "branch", "--show-current"), "")

    def test_incomplete_or_foreign_group_bindings_fail_before_codex(self):
        cases = [dict(self.scope, members=[]), dict(self.scope, members=["foreign"]),
                 dict(self.scope, members=[self.member, self.member]), dict(self.scope, members=[{}]),
                 dict(self.scope, agent_id="foreign"), dict(self.scope, project_context_id="foreign"),
                 dict(self.scope, group="../escape"), dict(self.scope, run_id=str(uuid.uuid4())),
                 dict(self.scope, sha="0" * 40), dict(self.scope, workspace=str(self.project)),
                 dict(self.scope, workspace_root="relative"), {}]
        for scope in cases:
            with self.subTest(scope=scope):
                result = self.launch(scope=scope)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)
        for env in ({"SYMPHONY_PROJECT_CONTEXT": "broken"}, {"SYMPHONY_YOLO_SCOPE": "broken"},
                    {"SYMPHONY_PHASE": "In Arbeit (AI)"}, {"SYMPHONY_LINEAR_AUTH_MODE": "other"},
                    {"SYMPHONY_ACTIVE_REPO_ROOT": str(self.project)}):
            with self.subTest(env=env):
                result = self.launch(env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)

    def test_checkout_changes_and_sibling_or_symlink_paths_fail_before_codex(self):
        tracked = self.workspace / "tracked"
        tracked.write_text("changed\n")
        self.assertNotEqual(self.launch().returncode, 0)
        self.git(self.workspace, "restore", "tracked")
        self.git(self.workspace, "checkout", "-b", "symphony/yolo")
        self.assertNotEqual(self.launch().returncode, 0)
        self.git(self.workspace, "checkout", "--detach")
        sibling = self.workspace_root / "yolo/incoming" / str(uuid.uuid4())
        self.git(self.project, "worktree", "add", "--detach", str(sibling), self.sha)
        self.assertNotEqual(self.launch(cwd=sibling).returncode, 0)
        self.git(self.project, "worktree", "remove", str(self.workspace))
        self.workspace.symlink_to(sibling, target_is_directory=True)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_scope_does_not_enable_manual_or_positional_start(self):
        for args in (["PRI-129"], ["--app-server", "PRI-129"]):
            with self.subTest(args=args):
                result = self.launch(args=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires a bound app-server launch", result.stderr)

    def test_unbound_regular_ticket_keeps_branch_validation(self):
        ticket = self.workspace_root / "PRI-130"
        self.git(self.project, "worktree", "add", "-b", "symphony/PRI-130", str(ticket), self.sha)
        env = {"SYMPHONY_YOLO_SCOPE": "", "SYMPHONY_ACTIVE_REPO_ROOT": str(ticket)}
        result = self.launch(env=env, cwd=ticket, args=["--app-server", "PRI-130"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["cwd"], str(ticket))
        self.git(ticket, "checkout", "--detach")
        result = self.launch(env=env, cwd=ticket, args=["--app-server", "PRI-130"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected symphony/PRI-130", result.stderr)
