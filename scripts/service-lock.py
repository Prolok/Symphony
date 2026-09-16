#!/usr/bin/env python3
"""Nonblocking per-user service mutex, held across launcher exec and BEAM boot."""

import fcntl
import importlib.util
import os
from pathlib import Path
import signal
import select
import sys
import time


def test_support():
    spec = importlib.util.spec_from_file_location("test_instance", Path(__file__).with_name("test-instance.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def requested_name(args):
    if any(arg == "--test-instance" or arg.startswith("--test-instance=") for arg in args):
        return test_support().instance_name(args)
    return None


def process_support():
    spec = importlib.util.spec_from_file_location("test_processes", Path(__file__).with_name("test-processes.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def service_paths(name):
    root = Path.home().resolve() / ".cache/symphony"
    if name is None:
        return [root / "service.lock"]
    # One fixture reservation across names, checkouts and restart attempts.
    return [root / "test-environment.lock", root / "test-instances" / (name + ".lock")]


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


def acquire_all(paths):
    descriptors = []
    try:
        for path in paths:
            descriptors.append(acquire(path))
        return descriptors
    except BaseException:
        for descriptor in descriptors:
            os.close(descriptor)
        raise


def launch(command, path=None, name=None):
    descriptors = acquire_all([path] if path else service_paths(name))
    owner = os.getpid()
    # Protect the fork/setsid window from terminal/process-group signals. The
    # guardian must outlive owner cleanup, including signalled build children.
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT})
    try:
        guardian = os.fork()
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        for descriptor in descriptors:
            os.close(descriptor)
        raise
    if guardian == 0:
        os.setsid()
        processes = process_support() if name else None
        known = {}
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
            if processes:
                processes.descendants(owner, known, {os.getpid()})
            time.sleep(0.02)
        if processes:
            processes.cleanup(owner, known, {os.getpid()})
        for descriptor in descriptors:
            os.close(descriptor)
        os._exit(0)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    for descriptor in descriptors:
        os.close(descriptor)
    env = dict(os.environ, SYMPHONY_SERVICE_OWNER_PID=str(owner), SYMPHONY_SERVICE_GUARD_PID=str(guardian))
    env["SYMPHONY_SERVICE_LOCK_MODE"] = name or "normal"
    try:
        os.execvpe(command[0], command, env)
    finally:
        os.kill(guardian, signal.SIGKILL)
        os.waitpid(guardian, 0)


def hold(name=None):
    descriptors = acquire_all(service_paths(name))
    owner = os.getppid()
    known = {}
    processes = process_support() if name else None
    print("locked", flush=True)
    try:
        if processes:
            while True:
                processes.descendants(owner, known, {os.getpid()})
                if select.select([sys.stdin.buffer], [], [], 0.05)[0] and not os.read(0, 4096):
                    break
        else:
            sys.stdin.buffer.read()
    finally:
        if processes:
            processes.cleanup(owner, known, {os.getpid()})
        for descriptor in descriptors:
            os.close(descriptor)


if __name__ == "__main__":
    if sys.argv[1:2] == ["hold"]:
        hold(requested_name(sys.argv[2:]))
    elif len(sys.argv) > 2 and sys.argv[1] == "run":
        try:
            name = requested_name(sys.argv[2:])
        except ValueError as error:
            raise SystemExit(str(error)) from error
        launch(sys.argv[2:], name=name)
    else:
        raise SystemExit("usage: service-lock.py hold | run command [args...]")
