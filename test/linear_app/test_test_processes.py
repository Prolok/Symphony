"""Synthetic OS process/lock proofs; no real service or tracker is contacted."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
BOOTSTRAP = """
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('helper',sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root=pathlib.Path(sys.argv[2])
if sys.argv[3]=='scopes':
    handles=m.reserve(json.loads(sys.argv[4]),root)
    print('locked',flush=True);sys.stdin.read()
else:
    m.service_paths=lambda name: [root/'normal.lock'] if name is None else [root/'environment.lock',root/(name+'.lock')]
    m.launch(sys.argv[5:],name=None if sys.argv[4]=='normal' else sys.argv[4])
"""
OWNER = """
import pathlib,subprocess,sys,time
marker=pathlib.Path(sys.argv[1]);marker.write_text(str(__import__('os').getpid()))
if len(sys.argv)>2:
    worker=subprocess.Popen([sys.executable,'-c',"import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(120)",str(marker.with_suffix('.worker'))],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
sys.stdin.read()
"""


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.02)
    return False


class TestProcessIsolation(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=REPO / 'tmp')
        self.root = Path(self.directory.name)
        self.children = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=10)
        self.directory.cleanup()

    def spawn(self, script, kind, value, *args):
        child = subprocess.Popen([sys.executable, '-c', BOOTSTRAP, str(REPO / 'scripts' / script), str(self.root), kind, value, *args],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.children.append(child)
        return child

    def service(self, name, marker, worker=False):
        return self.spawn('service-lock.py', 'launch', name, sys.executable, '-c', OWNER, str(self.root / marker), *(['worker'] if worker else []))

    def scopes(self, scope):
        return self.spawn('service-scopes.py', 'scopes', json.dumps(scope))

    def test_disjoint_projects_share_workspace_while_project_and_team_overlap_fail(self):
        teams = [{'id': 'pro-id', 'key': 'PRO'}]
        first = self.scopes([dict(workspace='w', kind='project', scope='a', project_id='a-id', teams=teams)])
        self.assertEqual(first.stdout.readline(), b'locked\n')
        second = self.scopes([dict(workspace='w', kind='project', scope='b', project_id='b-id', teams=teams)])
        self.assertEqual(second.stdout.readline(), b'locked\n')
        for kind, scope in [('project', 'a'), ('team', 'PRO')]:
            rejected = self.scopes([dict(workspace='w', kind=kind, scope=scope, project_id='a-id', teams=teams)])
            rejected.communicate(timeout=5)
            self.assertNotEqual(rejected.returncode, 0)
        first.kill(); first.communicate(timeout=5)
        second.communicate(input=b'x', timeout=5)
        broad = self.scopes([dict(workspace='w', kind='team', scope='PRO', teams=teams)])
        self.assertEqual(broad.stdout.readline(), b'locked\n')
        blocked = self.scopes([dict(workspace='w', kind='project', scope='new', project_id='new-id', teams=teams)])
        blocked.communicate(timeout=5)
        self.assertNotEqual(blocked.returncode, 0)
        other = self.scopes([dict(workspace='other', kind='team', scope='PRO', teams=teams)])
        self.assertEqual(other.stdout.readline(), b'locked\n')

    def test_normal_and_test_are_parallel_but_environment_is_exclusive_across_names(self):
        main = self.service('normal', 'main')
        test = self.service('dev', 'dev')
        self.assertTrue(wait_for(lambda: (self.root / 'main').exists() and (self.root / 'dev').exists()))
        for name in ('normal', 'acceptance', 'dev'):
            rejected = self.service(name, 'rejected-' + name)
            _, error = rejected.communicate(timeout=5)
            self.assertEqual(rejected.returncode, 1)
            self.assertIn('Symphony läuft bereits', error.decode())
        test.communicate(input=b'x', timeout=5)
        self.assertIsNone(main.poll())
        self.assertTrue(wait_for(lambda: self.available('environment.lock')))
        restarted = self.service('acceptance', 'resumed')
        self.assertTrue(wait_for(lambda: (self.root / 'resumed').exists()))
        restarted.communicate(input=b'x', timeout=5)
        self.assertIsNone(main.poll())

    def test_verified_qai_team_and_pro_project_can_reserve_concurrently(self):
        main = self.scopes([dict(workspace='w', kind='team', scope='QAI', teams=[{'id': 'qai-id', 'key': 'QAI'}])])
        self.assertEqual(main.stdout.readline(), b'locked\n')
        test = self.scopes([dict(workspace='w', kind='project', scope='dummy', project_id='dummy-id', teams=[{'id': 'pro-id', 'key': 'PRO'}])])
        self.assertEqual(test.stdout.readline(), b'locked\n')
        for scope in [
            dict(workspace='w', kind='project', scope='multi', project_id='multi-id',
                 teams=[{'id': 'pro-id', 'key': 'PRO'}, {'id': 'qai-id', 'key': 'QAI'}]),
            dict(workspace='w', kind='team', scope='QAI', teams=[{'id': 'qai-id', 'key': 'QAI'}]),
            dict(workspace='w', kind='project', scope='renamed-dummy', project_id='dummy-id', teams=[{'id': 'pro-id', 'key': 'PRO'}]),
            dict(workspace='w', kind='project', scope='unknown', project_id='unknown'),
            dict(workspace='w', kind='project', scope='unknown', project_id='unknown', teams=[]),
        ]:
            with self.subTest(scope=scope):
                rejected = self.scopes([scope])
                rejected.communicate(timeout=5)
                self.assertNotEqual(rejected.returncode, 0)
        main.kill()
        main.communicate(timeout=5)
        resumed = self.scopes([dict(workspace='w', kind='team', scope='QAI', teams=[{'id': 'qai-id', 'key': 'QAI'}])])
        self.assertEqual(resumed.stdout.readline(), b'locked\n')

    def available(self, name):
        import fcntl
        with open(self.root / name, 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                return False

    def test_guardian_owns_orphan_cleanup_after_signals_and_sigkill(self):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=number):
                name = 'owner-' + str(number)
                owner = self.service('dev', name, worker=True)
                marker = (self.root / name).with_suffix('.worker')
                self.assertTrue(wait_for(marker.exists))
                worker = int(marker.read_text())
                time.sleep(.15)  # The real guardian inventories the descendant.
                owner.send_signal(number)
                owner.communicate(timeout=5)
                self.assertFalse(self.available('environment.lock'))
                self.assertTrue(wait_for(lambda: self.available('environment.lock'), timeout=10))
                state = subprocess.run(['ps', '-p', str(worker), '-o', 'stat='], capture_output=True).stdout.strip()
                self.assertTrue(not state or state.startswith(b'Z'), state)
                self.assertTrue((self.root / 'environment.lock').exists())

    def test_failed_second_lock_does_not_leave_first_descriptor_held(self):
        spec = importlib.util.spec_from_file_location('lock', REPO / 'scripts/service-lock.py')
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        held = helper.acquire(self.root / 'busy.lock')
        try:
            with self.assertRaises(SystemExit):
                helper.acquire_all([self.root / 'free.lock', self.root / 'busy.lock'])
            self.assertTrue(self.available('free.lock'))
        finally:
            os.close(held)


if __name__ == '__main__':
    unittest.main()
