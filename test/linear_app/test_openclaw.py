"""Synthetic process/socket boundaries only; never load an OpenClaw installation."""
import importlib.machinery
import importlib.util
import io
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
            result = helper.call(str(path), request)
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result, dict(result=dict(tools=[])))
            self.assertEqual(observed, [dict(token="synthetic-token", request=request)])
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
        run.verify_openclaw([fixture])
        self.assertEqual(run.result["openclaw"]["knowledge_and_instruction_review"], "operator_evidence_required")


if __name__ == "__main__":
    unittest.main()
