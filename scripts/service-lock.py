#!/usr/bin/env python3
"""Nonblocking per-user service mutex, held across launcher exec and BEAM boot."""

import fcntl
import os
from pathlib import Path
import signal
import sys
import time


def acquire(path=None):
    path = path or Path.home().resolve() / ".cache/symphony/service.lock"
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        print("Symphony läuft bereits", file=sys.stderr, flush=True)
        raise SystemExit(1)
    return descriptor


def launch(command, path=None):
    descriptor = acquire(path)
    owner = os.getpid()
    # Protect the fork/setsid window from terminal/process-group signals. The
    # guardian must outlive owner cleanup, including signalled build children.
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT})
    try:
        guardian = os.fork()
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        os.close(descriptor)
        raise
    if guardian == 0:
        os.setsid()
        # Keep these signals blocked here, including any queued before setsid.
        # Owner death releases the mutex; failed exec explicitly kills us below.
        # Exec keeps the owner's PID. A separate holder survives runtimes that
        # close inherited descriptors. Kernel locks disappear after a crash;
        # the persistent lock file must never be unlinked.
        for number in (0, 1, 2):
            try:
                os.close(number)
            except OSError:
                pass
        while os.getppid() == owner:
            time.sleep(0.02)
        os.close(descriptor)
        os._exit(0)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    os.close(descriptor)
    env = dict(os.environ, SYMPHONY_SERVICE_OWNER_PID=str(owner), SYMPHONY_SERVICE_GUARD_PID=str(guardian))
    try:
        os.execvpe(command[0], command, env)
    finally:
        os.kill(guardian, signal.SIGKILL)
        os.waitpid(guardian, 0)


def hold():
    descriptor = acquire()
    print("locked", flush=True)
    try:
        sys.stdin.buffer.read()
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    if sys.argv[1:] == ["hold"]:
        hold()
    elif len(sys.argv) > 2 and sys.argv[1] == "run":
        launch(sys.argv[2:])
    else:
        raise SystemExit("usage: service-lock.py hold | run command [args...]")
