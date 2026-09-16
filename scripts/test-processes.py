"""Track owned descendants by PID and process start time for test cleanup."""
import os
import signal
import subprocess
import time


def snapshot():
    probe = subprocess.Popen(["ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    output, _ = probe.communicate(timeout=10)
    if probe.returncode:
        raise OSError("Prozessinventar nicht verfügbar")
    records = {}
    for line in output.decode().splitlines():
        pid, parent, group, state, started = line.strip().split(None, 4)
        if not state.startswith("Z") and int(pid) != probe.pid:
            records[int(pid)] = (int(parent), int(group), started)
    return records


def descendants(owner, known, excluded):
    records = snapshot()
    parents = {owner} | {pid for pid, started in known.items() if records.get(pid, (None, None, None))[2] == started}
    found = True
    while found:
        found = False
        for pid, (parent, _group, started) in records.items():
            if parent in parents and pid not in parents and pid not in excluded:
                parents.add(pid)
                known[pid] = started
                found = True
    return records


def cleanup(owner, known, excluded=(), grace=5):
    deadline = time.monotonic() + grace
    while True:
        records = descendants(owner, known, excluded)
        alive = {pid: started for pid, started in known.items() if records.get(pid, (None, None, None))[2] == started}
        if not alive:
            return
        number = signal.SIGTERM if time.monotonic() < deadline else signal.SIGKILL
        for pid in alive:
            try:
                os.kill(pid, number)
            except ProcessLookupError:
                pass
        # Keep the reservation while descendants still exist. Do not delete
        # persistent locks or signal a reused PID after the identity changes.
        time.sleep(0.05)
