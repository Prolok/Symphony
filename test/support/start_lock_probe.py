"""Exercise the real launcher process tree with handshakes and bounded waits."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def wait_until(predicate):
    deadline = time.monotonic() + 30
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("startup handshake timed out")
        time.sleep(0.02)


repo, mode, signum, other = sys.argv[1:]
repo = Path(repo)
signum = int(signum)
processes = []


def start(checkout, hold=False):
    env = dict(os.environ, HOLD_START="1" if hold else "0",
               HOLD_SERVICE="1" if mode == "service" and not processes else "0")
    process = subprocess.Popen(
        ["/bin/bash", str(Path(checkout) / "symphony")],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    processes.append(process)
    return process


autoupdate = repo / "autoupdate"
autoupdate.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
if os.environ.get("HOLD_START") == "1":
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
    (root / ".child-pid").write_text(str(child.pid))
    (root / ".ready").touch()
    while not (root / ".release").exists():
        time.sleep(0.02)
''')
autoupdate.chmod(0o755)

try:
    if mode == "service":
        (repo / "bin/symphony").write_text('''#!/usr/bin/env python3
import os, pathlib, time
if os.environ.get("HOLD_SERVICE") == "1":
    (pathlib.Path(__file__).parent.parent / ".service-ready").touch()
    while True:
        time.sleep(0.02)
''')
    first = start(repo, hold=mode != "service")
    ready = repo / (".service-ready" if mode == "service" else ".ready")
    wait_until(lambda: ready.exists() or first.poll() is not None)
    assert first.poll() is None, first.communicate()
    second = start(other if mode == "independent" else repo)

    output, _ = second.communicate(timeout=5)
    assert second.returncode == 1 and "Symphony läuft bereits" in output, output
    assert first.poll() is None
    if mode == "service":
        first.terminate()
        output, _ = first.communicate(timeout=30)
        assert first.returncode == -signal.SIGTERM, output
    elif mode == "independent":
        (repo / ".release").touch()
        output, _ = first.communicate(timeout=30)
        assert first.returncode == 0, output
    else:
        os.kill(first.pid, signum)
        output, _ = first.communicate(timeout=30)
        assert first.returncode == 128 + signum, output

    # The build grandchild must no longer be running after lock handoff.
    child_pid = (repo / ".child-pid").read_text() if mode != "service" else None

    def child_stopped():
        state = subprocess.run(
            ["ps", "-o", "stat=", "-p", child_pid], capture_output=True, text=True
        ).stdout.strip()
        return not state or state.startswith("Z")

    if child_pid:
        wait_until(child_stopped)
    # The guardian observes parent exit asynchronously; retry only the lock
    # rejection while waiting for release, never an actual launch failure.
    deadline = time.monotonic() + 5
    while True:
        third = start(repo)
        output, _ = third.communicate(timeout=30)
        if third.returncode == 0:
            break
        assert "Symphony läuft bereits" in output and time.monotonic() < deadline, output
        time.sleep(0.02)
    print("lock probe passed: " + mode)
finally:
    (repo / ".release").touch()
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
