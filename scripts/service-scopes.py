#!/usr/bin/env python3
"""Host-local project claims; team scopes exclude all projects in that workspace."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys


def reserve(scopes, root=None):
    root = root or Path.home().resolve() / ".cache/symphony/scopes"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    groups = {}
    for scope in scopes:
        groups.setdefault(scope["workspace"], []).append(scope)
    descriptors = []
    try:
        for workspace, entries in sorted(groups.items()):
            broad = any(e["kind"] == "team" for e in entries)
            keys = [(workspace, fcntl.LOCK_EX if broad else fcntl.LOCK_SH)]
            if not broad:
                keys.extend((workspace + "/" + e["scope"], fcntl.LOCK_EX) for e in entries)
            for key, mode in sorted(set(keys)):
                path = root / (hashlib.sha256(key.encode()).hexdigest() + ".lock")
                descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
                descriptors.append(descriptor)
                fcntl.flock(descriptor, mode | fcntl.LOCK_NB)
        return descriptors
    except BaseException:
        for descriptor in descriptors:
            os.close(descriptor)
        raise


if __name__ == "__main__":
    try:
        scopes = json.loads(sys.stdin.buffer.readline(65537))
        descriptors = reserve(scopes)
        print("locked", flush=True)
        sys.stdin.buffer.read()
    except (BlockingIOError, ValueError, KeyError, TypeError, OSError):
        sys.exit("Projektbereich wird bereits ausgeführt oder kann nicht exklusiv reserviert werden")
