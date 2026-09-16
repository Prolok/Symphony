#!/usr/bin/env python3
"""Host-local claims using complete team membership verified by the bound client."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys


def lock_keys(scopes):
    keys = {}
    identities = {}
    for scope in scopes:
        workspace, kind, name = scope['workspace'], scope['kind'], scope['scope']
        teams = scope['teams']
        if (not all(isinstance(v, str) and v.strip() == v and v for v in (workspace, name))
                or kind not in ('team', 'project') or not isinstance(teams, list) or not teams):
            raise ValueError('Unverifizierte Projekt-/Teambindung')
        if kind == 'team' and (len(teams) != 1 or teams[0]['key'] != name):
            raise ValueError('Mehrdeutige Teambindung')
        # Preserve the workspace gate and slug lock used by older builds.
        keys[workspace] = fcntl.LOCK_SH
        if kind == 'project':
            project = scope['project_id']
            if not isinstance(project, str) or not project.strip():
                raise ValueError('Projekt-ID fehlt')
            keys[workspace + '/' + name] = fcntl.LOCK_EX
            keys[json.dumps([workspace, 'project', project])] = fcntl.LOCK_EX
        for team in teams:
            team_id, key = team['id'], team['key']
            if not all(isinstance(v, str) and v.strip() == v and v for v in (team_id, key)):
                raise ValueError('Unvollständige Teambindung')
            for field, value, peer in [('id', team_id, key), ('key', key, team_id)]:
                identity = (workspace, field, value)
                if identities.setdefault(identity, peer) != peer:
                    raise ValueError('Widersprüchliche Teambindung')
                lock = json.dumps([workspace, 'team-' + field, value])
                if kind == 'team' or lock not in keys:
                    keys[lock] = fcntl.LOCK_EX if kind == 'team' else fcntl.LOCK_SH
    return keys


def reserve(scopes, root=None):
    keys = lock_keys(scopes)
    root = root or Path.home().resolve() / ".cache/symphony/scopes"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptors = []
    try:
        for key, mode in sorted(keys.items()):
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
