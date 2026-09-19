"""Synthetic process/socket boundaries only; never load an OpenClaw installation."""
import importlib.machinery
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]


def load(name):
    loader = importlib.machinery.SourceFileLoader(name, str(REPO / "scripts" / name))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class OpenClawBoundaryTest(unittest.TestCase):
    def test_gate_denial_precedes_binary_or_configuration_discovery(self):
        rpc = load("openclaw-rpc.py")
        with mock.patch.dict(os.environ, {"SYMPHONY_OPENCLAW_TEST_DENY": "1"}), \
                mock.patch.object(rpc.shutil, "which", side_effect=AssertionError("discovery")), \
                mock.patch.object(rpc.subprocess, "run", side_effect=AssertionError("process")):
            self.assertEqual(rpc.main(), 126)

    def test_transport_uses_exact_arguments_and_never_returns_error_output(self):
        rpc = load("openclaw-rpc.py")
        args = ["gateway", "call", "agent", "--params", '{"message":"synthetic"}', "--json"]
        with mock.patch.dict(os.environ, {"SYMPHONY_OPENCLAW_TEST_DENY": "0"}), \
                mock.patch.object(rpc.shutil, "which", return_value="/synthetic/openclaw"), \
                mock.patch.object(rpc.sys, "stdin", io.StringIO(json.dumps(args) + "\n")), \
                mock.patch.object(rpc.subprocess, "run", return_value=subprocess.CompletedProcess(args, 1, b"private", b"secret")) as run, \
                mock.patch.object(rpc.sys, "stdout", new_callable=io.StringIO) as output:
            self.assertEqual(rpc.main(), 1)
            self.assertEqual(output.getvalue(), "")
            run.assert_called_once_with(["/synthetic/openclaw", *args], capture_output=True, timeout=12, check=False)

    def test_missing_binary_and_timeout_remain_failures(self):
        rpc = load("openclaw-rpc.py")
        with mock.patch.dict(os.environ, {"SYMPHONY_OPENCLAW_TEST_DENY": "0"}), \
                mock.patch.object(rpc.shutil, "which", return_value=None):
            self.assertEqual(rpc.main(), 127)
        with mock.patch.dict(os.environ, {"SYMPHONY_OPENCLAW_TEST_DENY": "0"}), \
                mock.patch.object(rpc.shutil, "which", return_value="/synthetic/openclaw"), \
                mock.patch.object(rpc.sys, "stdin", io.StringIO('["--version"]\n')), \
                mock.patch.object(rpc.subprocess, "run", side_effect=subprocess.TimeoutExpired("synthetic", 12)):
            self.assertEqual(rpc.main(), 1)

    def test_tool_helper_round_trip_and_expired_binding(self):
        helper = load("sym-yolo-tool.py")
        with tempfile.TemporaryDirectory() as directory, socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            path = Path(directory) / "tools.json"
            path.write_text(json.dumps(dict(port=server.getsockname()[1], token="synthetic-token")))
            observed = []

            def respond():
                client, _ = server.accept()
                with client, client.makefile("rb") as stream:
                    observed.append(json.loads(stream.readline()))
                    client.sendall(b'{"result":{"tools":[]}}\n')

            thread = threading.Thread(target=respond)
            thread.start()
            request = dict(jsonrpc="2.0", id=1, method="tools/list")
            with mock.patch.object(helper, "checkout_proof", return_value={"measured": True}):
                result = helper.call(str(path), request)
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result, dict(result=dict(tools=[])))
            self.assertEqual(observed, [dict(token="synthetic-token", checkout={"measured": True}, request=request)])
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                helper.call(str(path), request)

    def test_live_launcher_requires_opt_in_and_never_runs_inside_standard_gates(self):
        launcher = REPO / "scripts/openclaw-live-test"
        missing = subprocess.run([sys.executable, str(launcher), "--agent", "po"], capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        denied = subprocess.run([sys.executable, str(launcher), "--execute-live", "--agent", "po", "--", "--help"],
                                env=dict(os.environ, SYMPHONY_OPENCLAW_TEST_DENY="1"), capture_output=True)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn(b"forbidden in standard gates", denied.stderr)

    def test_live_evidence_rejects_codex_and_wrong_agent_receipts(self):
        runner = load("test-instance-run")
        run = object.__new__(runner.Run)
        run.args = type("Args", (), dict(openclaw_agent="po"))()
        run.result = {}
        fixture = dict(po_incoming=True, po_receipt=dict(session_id="session"))
        with self.assertRaises(runner.RunFailure):
            run.verify_openclaw([fixture])
        fixture["po_receipt"]["openclaw"] = dict(agent="other", state="completed", session_id="session", payload_sha256="hash")
        with self.assertRaises(runner.RunFailure):
            run.verify_openclaw([fixture])
        fixture["po_receipt"]["openclaw"]["agent"] = "po"
        with self.assertRaises(runner.RunFailure):
            run.verify_openclaw([fixture])
        proof = fixture["po_receipt"]["openclaw"]
        proof.update(id="run", project_id="project", workspace="/proof", sha="sha")
        proof["checkout_proof"] = dict(proof, cwd="/proof", git_root="/proof", clean=True)
        proof["terminal"] = dict(runId="run", status="ok", endedAt=1)
        fixture["po_receipt"].update(sha="sha", workspace="/proof")
        run.verify_openclaw([fixture])
        self.assertEqual(run.result["openclaw"]["knowledge_and_instruction_review"], "operator_evidence_required")

    def test_only_typed_correlated_first_response_errors_prove_rejection(self):
        rpc = load("openclaw-rpc.py")
        raw = json.dumps(dict(agentId="po", sessionKey="session", idempotencyKey="run", cwd="/proof"))
        args = ["gateway", "call", "agent", "--params", raw, "--json"]
        error = dict(ok=False, error=dict(type="gateway_request_error", code="INVALID_REQUEST",
                     message="cwd is reserved for plugin-owned subagent runs", retryable=False, details="SECRET"))
        result = subprocess.CompletedProcess(args, 1, json.dumps(error).encode(), b"SECRET")
        proof = rpc.rejection(args, result)
        self.assertEqual(proof["request_sha256"], hashlib.sha256(raw.encode()).hexdigest())
        self.assertEqual(proof["reason"], "cwd_reserved")
        self.assertNotIn("SECRET", json.dumps(proof))
        for changed in [dict(error, ok=True), dict(error, error=dict(error["error"], type="cli_error")),
                        dict(error, error=dict(error["error"], message="INVALID_REQUEST SECRET")),
                        dict(error, error=dict(error["error"], retryable=True))]:
            self.assertIsNone(rpc.rejection(args, subprocess.CompletedProcess(args, 1, json.dumps(changed).encode(), b"")))
        for output in [b"Gateway call failed: cwd is reserved for plugin-owned subagent runs", b"{}", b"[]", b"x" * 16385]:
            self.assertIsNone(rpc.rejection(args, subprocess.CompletedProcess(args, 1, output, b"")))
        self.assertIsNone(rpc.rejection(args + ["--expect-final"], result))
        self.assertIsNone(rpc.rejection(["gateway", "call", "agent.wait", *args[3:]], result))
        with mock.patch.dict(os.environ, {"SYMPHONY_OPENCLAW_TEST_DENY": "0"}), \
                mock.patch.object(rpc.shutil, "which", return_value="/synthetic/openclaw"), \
                mock.patch.object(rpc.sys, "stdin", io.StringIO(json.dumps(args))), \
                mock.patch.object(rpc.subprocess, "run", return_value=result), \
                mock.patch.object(rpc.sys, "stdout", new_callable=io.StringIO) as output:
            self.assertEqual(rpc.main(), 0)
            self.assertEqual(json.loads(output.getvalue()), proof)

    def test_subsequent_incoming_requires_completed_distinct_execution_in_same_project_and_source(self):
        runner = load("test-instance-run")
        run = object.__new__(runner.Run)
        run.args = type("Args", (), dict(openclaw_agent="po", scenario="po_incoming"))()
        run.result = dict(source={"sha": "source"}, openclaw={})
        proof = dict(id="old", session_id="session-old", project_id="project", agent="po", state="completed",
                     workspace="/proof", sha="sha", payload_sha256="payload")
        proof["checkout_proof"] = dict(proof, cwd="/proof", git_root="/proof", clean=True)
        proof["terminal"] = dict(runId="old", status="ok", endedAt=1)
        previous = dict(run_id="prior", scenario="po_incoming", evidence="live", status="passed",
                        cleanup=True, main_preserved=True, originals_preserved=True, source=run.result["source"],
                        openclaw=dict(agent="po", executions=[proof]))
        following = [dict(id="new", session_id="session-new", project_id="project")]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "result.json")
            path.write_text(json.dumps(previous))
            run.verify_subsequent_incoming(path, following)
            self.assertTrue(run.result["openclaw"]["subsequent_incoming"]["passed"])
            for invalid in [dict(previous, evidence="simulation"), dict(previous, cleanup=False),
                            dict(previous, source={"sha": "other"}), dict(previous, status="failed")]:
                path.write_text(json.dumps(invalid))
                with self.assertRaises(runner.RunFailure):
                    run.verify_subsequent_incoming(path, following)
            path.write_text(json.dumps(previous))
            for current in [[proof], [dict(following[0], project_id="other")]]:
                with self.assertRaises(runner.RunFailure):
                    run.verify_subsequent_incoming(path, current)

    def test_real_helper_measures_exec_checkout_and_rejects_wrong_or_dirty_git_state(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket() as server:
            checkout = Path(directory, "checkout")
            checkout.mkdir()
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=checkout, stderr=subprocess.DEVNULL).decode().strip()
            git("init", "--quiet")
            Path(checkout, "tracked").write_text("fixture")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture")
            sha = git("rev-parse", "HEAD")
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            binding = dict(port=server.getsockname()[1], token="synthetic", checkout=dict(
                id="run", project_id="project", session_id="session", workspace=str(checkout.resolve()), sha=sha))
            descriptor = Path(directory, "tools.json")
            descriptor.write_text(json.dumps(binding))
            observed = []
            def respond():
                client, _ = server.accept()
                with client, client.makefile("rb") as stream:
                    observed.append(json.loads(stream.readline()))
                    client.sendall(b'{"result":{}}\n')
            thread = threading.Thread(target=respond)
            thread.start()
            def call(cwd):
                return subprocess.run([sys.executable, str(REPO / "scripts/sym-yolo-tool.py"), str(descriptor)],
                                      input='{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
                                      cwd=cwd, capture_output=True, text=True,
                                      env=dict(os.environ, GIT_DIR="/wrong/git"))
            self.assertEqual(call(checkout).returncode, 0)
            thread.join(5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(observed[0]["checkout"], dict(binding["checkout"], cwd=str(checkout.resolve()),
                                                         git_root=str(checkout.resolve()), clean=True))
            self.assertNotEqual(call(directory).returncode, 0)
            binding["checkout"]["sha"] = "wrong"
            descriptor.write_text(json.dumps(binding))
            self.assertNotEqual(call(checkout).returncode, 0)
            binding["checkout"]["sha"] = sha
            descriptor.write_text(json.dumps(binding))
            Path(checkout, "tracked").write_text("dirty")
            self.assertNotEqual(call(checkout).returncode, 0)


if __name__ == "__main__":
    unittest.main()
