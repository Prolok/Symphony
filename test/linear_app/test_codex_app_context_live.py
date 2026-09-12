"""Opt-in, token-free regression with the installed Codex and real Symphony MCP.

Requires Codex, mise and an already compiled _build/dev/lib plus deps. Run:
SYMPHONY_TEST_REAL_CODEX=1 python3 -m unittest discover -s test/linear_app \
    -p 'test_codex_app_context_live.py' -v

Only disposable fixtures are changed. No login, model turn, Linear call, build
or operator release is used; HOME and the child environment are synthetic.
"""

import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import unittest

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installation_release", REPO / "scripts/installation-release.py")
release_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_helper)


@unittest.skipUnless(os.environ.get("SYMPHONY_TEST_REAL_CODEX") == "1", "opt-in real Codex handshake")
class RealCodexContextTest(unittest.TestCase):
    def setUp(self):
        for executable in ("codex", "mise", "git"):
            self.assertIsNotNone(shutil.which(executable), f"Required executable: {executable}")
        for directory in ("_build/dev/lib/symphony_elixir/ebin", "deps"):
            self.assertTrue((REPO / directory).is_dir(), f"Compile the dev runtime first: {directory}")
        self.temporary = tempfile.TemporaryDirectory(prefix="codex-trust-", dir=REPO / "_build")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.personal = self.root / "home"
        self.personal.mkdir()
        self.original = self.personal / ".codex"
        self.original.mkdir()
        self.project = self.root / "Fachprojekt ä"
        self.project.mkdir()
        self.release = self.root / "release"
        self.release.mkdir()
        self.marker = self.root / "foreign-mcp-started"
        foreign = '[mcp_servers.foreign]\ncommand="/usr/bin/touch"\nargs=' + json.dumps([str(self.marker)]) + '\n'
        (self.original / "config.toml").write_text(foreign)
        (self.project / ".codex").mkdir()
        self.foreign_config = foreign + '[mcp_servers."foreign.with.dots"]\ncommand="/usr/bin/touch"\nargs=' + json.dumps([str(self.marker)]) + '\n'
        self.foreign_config += '[mcp_servers.foreign_http]\nurl="http://127.0.0.1:9"\n'
        self.foreign_config += '[features]\nmemories=true\n[memories]\ngenerate_memories=true\nuse_memories=true\n'
        self.foreign_config += '[plugins."foreign.plugin@market"]\nenabled=true\n'
        # No inherited auth, project binding, personal Codex config or secrets.
        # mise may reuse installed tool binaries, with all mutable state private.
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(self.personal), "USER": "synthetic",
            "CODEX_HOME": str(self.original), "TMPDIR": str(self.root / "tmp"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "MISE_DATA_DIR": os.environ.get("MISE_DATA_DIR", str(Path.home() / ".local/share/mise")),
            "MISE_CONFIG_DIR": str(self.root / "mise-config"),
            "MISE_CACHE_DIR": str(self.root / "mise-cache"),
            "MISE_STATE_DIR": str(self.root / "mise-state"),
            "MISE_TRUSTED_CONFIG_PATHS": str(self.release / "mise.toml"),
            "MIX_ENV": "dev", "HEX_HOME": str(self.root / "hex"),
            "SYMPHONY_PYTHON": sys.executable,
            "SYMPHONY_RELEASE_ROOT": str(self.release),
            "SYMPHONY_ROOT_DIR": str(self.release),
            "SYMPHONY_SOURCE_REPO": str(self.project),
            "SYMPHONY_PROJECT_ROOT": str(self.project),
            "SYMPHONY_LINEAR_ENV_DIR": str(self.project / ".symphony"),
            "SYMPHONY_WORKFLOW_FILE": str(self.release / "WORKFLOW.md"),
            "SYMPHONY_CODEX_STATE_ROOT": str(self.root / "sessions-state"),
            "SYMPHONY_LINEAR_AUTH_MODE": "app",
            "SYMPHONY_LINEAR_CLIENT_SECRET_ENV": "PROBE_LINEAR_SECRET",
            "SYMPHONY_LINEAR_BINDING_HASH": "synthetic-binding",
            "SYMPHONY_LINEAR_SECRET_ACCESS": "denied",
        }
        (self.root / "tmp").mkdir()
        installs = self.personal / ".local/share/mise/installs"
        installs.parent.mkdir(parents=True)
        installs.symlink_to(Path(self.env["MISE_DATA_DIR"]) / "installs", target_is_directory=True)
        self.git(self.project, "init", "-q")
        self.git(self.project, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        for name in ("lib", "config", "deps", "_build/dev/lib"):
            shutil.copytree(REPO / name, self.release / name, symlinks=False)
        for name in ("mix.exs", "mix.lock", "mise.toml", "sym-codex-mcp",
                     "scripts/mix-runtime", "scripts/installation-release.py", "scripts/codex-app-context.py"):
            target = self.release / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, target)
        (self.release / "WORKFLOW.md").write_text('---\ntracker:\n  kind: linear\n  auth_mode: app\n---\nSynthetic handshake only.\n')
        (self.release / ".symphony").mkdir()
        (self.release / ".symphony/root-config.json").write_text(json.dumps({"root": str(self.release), "values": {}}))
        self.git(self.release, "init", "-q")
        self.git(self.release, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        self.config = self.release / ".symphony/codex/config.toml"

    def git(self, directory, *args):
        subprocess.run(["git", "-C", str(directory), *args], env=self.env, check=True, capture_output=True)

    def seal(self, cwd):
        subprocess.run([sys.executable, str(self.release / "scripts/installation-release.py"), "seal", str(self.release)],
                       cwd=cwd, env=self.env, check=True, capture_output=True)
        self.manifest = (self.release / ".symphony-release.json").read_bytes()
        self.config_before = self.config.read_bytes()
        release_helper.verify(self.release)

    def handshake(self, cwd):
        # The deliberately unusable local provider prevents any remote model
        # discovery; no turn/start or tool/call request is ever sent.
        args = [sys.executable, str(self.release / "scripts/codex-app-context.py"),
                "--config", 'model_provider="offline_probe"',
                "--config", 'model_providers.offline_probe={name="Offline probe",base_url="http://127.0.0.1:9",wire_api="responses",requires_openai_auth=false}',
                "--config", 'cli_auth_credentials_store="file"',
                "app-server"]
        messages = queue.Queue()
        with tempfile.TemporaryFile(mode="w+") as stderr:
            process = subprocess.Popen(args, cwd=cwd, env=self.env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)

            def read_messages():
                for line in process.stdout:
                    messages.put(json.loads(line))
                messages.put(None)

            reader = threading.Thread(target=read_messages, daemon=True)
            reader.start()

            def request(identifier, method, params):
                process.stdin.write(json.dumps({"id": identifier, "method": method, "params": params}) + "\n")
                process.stdin.flush()
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    try:
                        message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                    except queue.Empty:
                        break
                    if message is None:
                        break
                    if message.get("id") == identifier:
                        return message
                stderr.seek(0)
                self.fail(f"Real Codex {method} failed or timed out: {stderr.read()[-5000:]}")

            try:
                initialized = request(1, "initialize", {"clientInfo": {"name": "symphony-trust-probe", "version": "1"},
                                                        "capabilities": {"experimentalApi": True}})
                self.assertIn("result", initialized, initialized)
                process.stdin.write('{"method":"initialized","params":{}}\n')
                process.stdin.flush()
                started = request(2, "thread/start", {"cwd": str(cwd), "approvalPolicy": "never", "sandbox": "workspace-write"})
                status = request(3, "mcpServerStatus/list", {}) if "result" in started else None
                if "result" in started:
                    config = request(4, "config/read", {"cwd": str(cwd)})["result"]["config"]
                    self.assertFalse(config["features"]["memories"])
                    self.assertFalse(config["memories"]["generate_memories"])
                    self.assertFalse(config["memories"]["use_memories"])
                    servers = config["mcp_servers"]
                    self.assertEqual({name for name, server in servers.items() if server.get("enabled", True)}, {"symphony_linear"})
                    self.assertTrue(all(not plugin["enabled"] for plugin in config.get("plugins", {}).values()))
                    self.assertEqual(servers["symphony_linear"]["env"]["SYMPHONY_LINEAR_SECRET_ACCESS"], "denied")
                    policy = config["shell_environment_policy"]
                    self.assertNotIn("PROBE_LINEAR_SECRET", policy["include_only"])
                    self.assertEqual(policy["set"]["SYMPHONY_LINEAR_SECRET_ACCESS"], "denied")
                return started, status
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # Only our own child is stopped, including on sandboxes
                    # which prohibit process-group signals.
                    process.terminate()
                    process.wait(timeout=5)
                reader.join(timeout=5)
                process.stdout.close()
                stderr.seek(0)
                self.last_stderr = stderr.read()

    def assert_unchanged(self):
        self.assertEqual((self.release / ".symphony-release.json").read_bytes(), self.manifest)
        self.assertEqual(self.config.read_bytes(), self.config_before)
        release_helper.verify(self.release)
        self.assertFalse(self.marker.exists(), "Personal/project MCP must stay disabled")

    def assert_direct_mcp(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "symphony-trust-probe", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]
        result = subprocess.run([str(self.release / "sym-codex-mcp")], cwd=self.project, env=self.env,
                                input="".join(json.dumps(item) + "\n" for item in requests),
                                capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "symphony-linear")
        self.assertIn("linear_graphql", json.dumps(responses[1]))

    def test_real_initialize_thread_start_worktree_and_tampering(self):
        (self.project / ".codex/config.toml").write_text(self.foreign_config)
        launch_worktree = self.root / "worktrees" / "launch"
        self.git(self.project, "worktree", "add", "--detach", str(launch_worktree))
        self.seal(launch_worktree)
        self.assertEqual(tomllib.loads(self.config.read_text())["projects"], {
            str(self.project): {"trust_level": "trusted"},
        })
        self.assert_direct_mcp()
        started, status = self.handshake(self.project)
        self.assert_unchanged()
        self.assertIn("result", started, f"{started}\n{self.last_stderr}")
        self.assertIn("result", status, status)
        self.assertIn("linear_graphql", json.dumps(status))
        self.assertIn("symphony_linear", json.dumps(status))
        # A new worktree created after sealing must use the same project trust.
        worktree = self.root / "worktrees" / "issue"
        self.git(self.project, "worktree", "add", "--detach", str(worktree))
        (worktree / ".codex").mkdir()
        (worktree / ".codex/config.toml").write_text(self.foreign_config)
        started, status = self.handshake(worktree)
        self.assertIn("result", started, f"{started}\n{self.last_stderr}")
        self.assertIn("linear_graphql", json.dumps(status))
        self.assert_unchanged()
        self.config.write_text(self.config.read_text().replace("apps = false", "apps = true"))
        with self.assertRaisesRegex(RuntimeError, "content changed"):
            release_helper.verify(self.release)
        started, _ = self.handshake(worktree)
        self.assertIn("error", started, started)
        self.assertIn("symphony_linear", started["error"]["message"])

    def test_second_project_uses_its_own_home_and_keeps_the_release_unchanged(self):
        self.seal(self.project)
        started, _ = self.handshake(self.project)
        self.assertIn("result", started, f"{started}\n{self.last_stderr}")
        second = self.root / "second-project"
        second.mkdir()
        self.git(second, "init", "-q")
        self.env.update(SYMPHONY_PROJECT_ROOT=str(second), SYMPHONY_SOURCE_REPO=str(second),
                        SYMPHONY_CODEX_STATE_ROOT=str(self.root / "second-state"),
                        SYMPHONY_LINEAR_ENV_DIR=str(second / ".symphony"))
        started, status = self.handshake(second)
        self.assertIn("result", started, f"{started}\n{self.last_stderr}")
        self.assertIn("linear_graphql", json.dumps(status))
        homes = list((self.release / ".symphony/codex/projects").iterdir())
        self.assertEqual(len(homes), 2)
        self.assertEqual({(home / "sessions").resolve() for home in homes}, {
            self.root / "sessions-state/sessions", self.root / "second-state/sessions"})
        self.assert_unchanged()


if __name__ == "__main__":
    unittest.main()
