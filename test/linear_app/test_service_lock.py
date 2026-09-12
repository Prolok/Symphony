import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/service-lock.py"


class ServiceLockTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.lock = self.root / "service.lock"
        self.processes = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        self.directory.cleanup()

    def start(self, name):
        # Two independent entry commands use the actual lock implementation.
        marker = self.root / name
        child = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('started'); sys.stdin.buffer.read(1)"
        bootstrap = "import importlib.util,pathlib,sys; s=importlib.util.spec_from_file_location('lock',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.launch(sys.argv[3:],pathlib.Path(sys.argv[2]))"
        process = subprocess.Popen([sys.executable, "-c", bootstrap, str(SCRIPT), str(self.lock), sys.executable, "-c", child, str(marker)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        return process, marker

    def wait_started(self, process, marker):
        deadline = time.monotonic() + 5
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists())

    def assert_restart(self, signal_number):
        first, marker = self.start("first")
        self.wait_started(first, marker)
        second, second_marker = self.start("second")
        _, error = second.communicate(timeout=2)
        self.assertEqual(second.returncode, 1)
        self.assertIn("Symphony läuft bereits", error.decode())
        self.assertFalse(second_marker.exists())
        if signal_number is None:
            first.communicate(input=b"x", timeout=2)
            self.assertEqual(first.returncode, 0)
        else:
            first.send_signal(signal_number)
            first.communicate(timeout=2)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            restarted, restarted_marker = self.start("restarted")
            startup_deadline = time.monotonic() + 5
            while not restarted_marker.exists() and restarted.poll() is None and time.monotonic() < startup_deadline:
                time.sleep(0.01)
            if restarted_marker.exists():
                break
            restarted.communicate(timeout=2)
        self.wait_started(restarted, restarted_marker)
        self.assertTrue(self.lock.exists())

    def test_second_start_and_restart_after_termination(self):
        self.assert_restart(signal.SIGTERM)

    def test_second_start_and_restart_after_clean_exit(self):
        self.assert_restart(None)

    def test_second_start_and_restart_after_crash(self):
        self.assert_restart(signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
