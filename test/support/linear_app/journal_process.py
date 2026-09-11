"""Independent BEAMs and real flock ports sharing one disposable project journal."""
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[3]
children = []
with tempfile.TemporaryDirectory(prefix='journal-process-') as directory:
    root = Path(directory)
    release = root / 'release'
    helpers = release / 'priv/linear_app'
    helpers.mkdir(parents=True)
    (release / '.symphony-release.json').write_text('{}')
    shutil.copyfile(repo / 'priv/linear_app/issue_lease.py', helpers / 'issue_lease.py')
    source = (repo / 'priv/linear_app/state_lock.py').read_text()
    # Only relocate the fixture's lock directory; use the actual flock backend.
    source += '\noriginal_lock = state_lock\ndef state_lock(a, b, timeout=10):\n    return original_lock(a, b, timeout=timeout, root=' + repr(directory) + ')\n'
    (helpers / 'state_lock.py').write_text(source)
    binding = dict(state_root=str(root / 'project/.symphony/state'), workspace_id='workspace', user_id='app', installation_id='install')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('LINEAR_', 'SYMPHONY_'))}
    env.update(SYMPHONY_RELEASE_ROOT=str(release), ERL_FLAGS='+S 2:2')
    runtime = sys.argv[1:] + [str(Path(__file__).with_suffix('.exs'))]

    class Worker:
        def __init__(self, **command):
            self.process = subprocess.Popen(runtime, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, env=env, bufsize=0)
            children.append(self)
            self.selector = selectors.DefaultSelector()
            self.selector.register(self.process.stdout, selectors.EVENT_READ)
            ready = self.read('ready')
            assert int(ready['pid']) == self.process.pid
            self.process.stdin.write((json.dumps({'binding': binding, 'phase': 'Todo (AI)', **command}) + '\n').encode())
            self.read('started')

        def read(self, event):
            line = bytearray()
            while not line.endswith(b'\n'):
                assert self.selector.select(15), f'timeout waiting for {event}'
                byte = self.process.stdout.read(1)
                assert byte, f'child exited waiting for {event}: {self.process.stderr.read().decode()}'
                line.extend(byte)
            result = json.loads(line)
            assert result['event'] == event, result
            return result

        def release(self):
            self.process.stdin.write(b'continue\n')

        def finish(self, error=None):
            result = self.read('result')
            assert result == ({'event': 'result', 'ok': True} if error is None else {'event': 'result', 'error': error}), result
            self.process.stdin.close()
            assert self.process.wait(timeout=10) == 0
            assert self.process.stderr.read() == b''

    def create(ident, issue):
        return {'query': 'mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }',
                'variables': {'input': {'id': ident, 'issueId': issue, 'body': '## Symphony Workpad\nGrüße\n'}}}

    try:
        first = Worker(payload=create('workpad-a', 'issue-a'), gate=True)
        first.read('http')
        second = Worker(payload=create('workpad-b', 'issue-b'))
        assert first.process.pid != second.process.pid
        if second.selector.select(0.2):
            raise AssertionError(f"second writer did not wait: {second.read('result')}")
        assert len(list((root / 'project/.symphony/state/comments').glob('*.intent.json'))) == 1

        # Readers bypass a held journal; bounded contention has its own error.
        Worker(payload={'query': 'query { viewer { id } }'}).finish()
        Worker(payload=create('blocked', 'issue-c'), timeout=100).finish(':comment_journal_busy')
        reconciler = Worker(action='reconcile')
        assert not reconciler.selector.select(0.2), 'reconciliation wrote through a held journal'
        first.release()
        first.finish()
        second.read('http')
        second.finish()
        reconciler.finish()

        # A fresh planning runtime edits the existing workpad in the same journal.
        update = {'query': 'mutation($id: String!, $input: CommentUpdateInput!) { commentUpdate(id: $id, input: $input) { success } }',
                  'variables': {'id': 'workpad-a', 'input': {'body': '## Symphony Workpad\nPlanung überarbeitet\n'}}}
        later = Worker(payload=update, phase='Planung (AI)')
        later.read('http')
        later.finish()
        remote = root / 'project/.symphony/state/remote'
        assert json.loads((remote / 'workpad-a').read_text())['body'] == update['variables']['input']['body']

        # Lost response recovery must not issue another create, even in a new VM.
        lost = Worker(payload=create('lost', 'issue-d'), lose_response=True)
        lost.read('http')
        lost.finish(':connection_lost')
        Worker(payload=create('lost', 'issue-d')).finish('{:comment_write_recovered, ["lost"]}')
        after = Worker(payload=create('after-recovery', 'issue-e'))
        after.read('http')
        after.finish()
        assert len(list(remote.iterdir())) == 4
        assert len(list((remote.parent / 'comments').glob('*.confirmed.json'))) == 5

        # True competing issue ownership still fails immediately across VMs.
        owner = Worker(action='lease', issue='issue-a', gate=True)
        owner.read('owned')
        started = time.monotonic()
        Worker(action='lease', issue='issue-a').finish(':issue_already_owned')
        assert time.monotonic() - started < 3, 'competing issue owner did not fail fast'
        other = Worker(action='lease', issue='issue-b')
        other.read('owned')
        other.finish()
        owner.release()
        owner.finish()
        new_owner = Worker(action='lease', issue='issue-a')
        new_owner.read('owned')
        new_owner.finish()
        print('Journal processes: contention, bounded wait, read bypass, later update, pending recovery and true issue exclusion passed')
    finally:
        for child in children:
            child.selector.close()
            if child.process.poll() is None:
                child.process.terminate()
                child.process.wait(timeout=5)
            for stream in (child.process.stdin, child.process.stdout, child.process.stderr):
                stream.close()
