"""Offline pipeline-launch and owned-process proofs; never live acceptance."""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]


def load():
    loader = importlib.machinery.SourceFileLoader('pipeline', str(REPO / 'scripts/test-instance-pipeline'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class PipelinePlan(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=REPO / 'tmp')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.module = load()
        self.workflow = (REPO / 'WORKFLOW.md').read_text()
        (self.root / 'WORKFLOW.md').write_text(self.workflow)
        self.source = dict(checkout=str(self.root), sha='a' * 40, source_sha256='b' * 64, dirty=True)
        (self.root / 'source.json').write_text(json.dumps(self.source))
        (self.root / 'manifest.json').write_text(json.dumps(dict(project_root=str(self.root / 'fixtures'))))
        self.args = argparse.Namespace(source=self.root / 'source.json', manifest=self.root / 'manifest.json',
                                       result_dir=self.root / '_build/run', run_id='pipeline-fixture',
                                       issue_id=['11111111-1111-4111-8111-111111111111'],
                                       port=4101, timeout=2, yolo=True)
        patch = mock.patch.object(self.module.TEST, 'source', return_value=self.source)
        patch.start()
        self.addCleanup(patch.stop)

    def test_plan_preserves_every_gate_and_restricts_exact_fixture_ids(self):
        plan = self.module.prepare(self.args)
        overlay = Path(plan['workflow']).read_text()
        added = '    allowed_issue_ids: ' + json.dumps(self.args.issue_id) + '\n    allow_yolo_followup_ids: true\n'
        self.assertEqual(overlay.replace(added, ''), self.workflow)
        self.assertEqual(plan['issue_ids'], self.args.issue_id)
        self.assertEqual(plan['acceptance'], 'pending_operator_evidence')
        self.assertFalse((self.args.result_dir / 'result.json').exists())
        with self.assertRaisesRegex(ValueError, 'already_exists'):
            self.module.prepare(self.args)

    def test_rejects_changed_source_unsafe_paths_and_ambiguous_ids_before_writing(self):
        for values in (dict(issue_id=['PRO-734']), dict(issue_id=self.args.issue_id * 2),
                       dict(result_dir=self.root / 'outside'), dict(run_id='../escape'), dict(timeout=601)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.module.prepare(argparse.Namespace(**(vars(self.args) | values)))
        with mock.patch.object(self.module.TEST, 'source', return_value={}), self.assertRaisesRegex(ValueError, 'source_changed'):
            self.module.prepare(self.args)
        self.assertFalse(self.args.result_dir.exists())

    def test_environment_excludes_worker_and_bootstrap_contracts(self):
        plan = self.module.prepare(self.args)
        original = dict(SYMPHONY_TEST_RUN_STAGE='run', SYMPHONY_TEST_RUN_PLAN='foreign-plan',
                        SYMPHONY_PROJECT_CONTEXT='foreign', SYMPHONY_ISSUE_ID='foreign',
                        SYMPHONY_YOLO_SCOPE='foreign', SYMPHONY_SERVICE_OWNER_PID='foreign',
                        SYMPHONY_SERVICE_GUARD_PID='17', SYMPHONY_SERVICE_LOCK_MODE='pipeline-fixture')
        with mock.patch.dict(os.environ, original):
            env = self.module.environment(plan)
        for key in original.keys() - {'SYMPHONY_SERVICE_GUARD_PID', 'SYMPHONY_SERVICE_LOCK_MODE'}:
            self.assertNotIn(key, env)
        self.assertEqual(env['SYMPHONY_WORKFLOW_FILE'], plan['workflow'])
        self.assertEqual(env['SYMPHONY_TEST_EXPECTED_SOURCE'], self.source['source_sha256'])
        self.assertEqual(env['SYMPHONY_SERVICE_GUARD_PID'], '17')

    def test_timeout_reaps_owned_service_and_detached_worker_without_claiming_acceptance(self):
        plan = self.module.prepare(self.args)
        stamp = self.root / '_build/symphony-source.json'
        stamp.write_text(json.dumps(self.source))
        tools = self.root / 'tools'
        tools.mkdir()
        mise = tools / 'mise'
        mise.write_text('#!/bin/sh\nshift\nshift\nexec "$@"\n')
        mise.chmod(0o755)
        (self.root / 'bin').mkdir()
        service = self.root / 'bin/symphony'
        service.write_text('#!' + sys.executable + '''
import json,os,subprocess,sys,time
from pathlib import Path
worker=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
Path('started.json').write_text(json.dumps(dict(pid=os.getpid(),worker=worker.pid,
    workflow=os.environ['SYMPHONY_WORKFLOW_FILE'],args=sys.argv[1:],
    stage=os.environ.get('SYMPHONY_TEST_RUN_STAGE'))))
time.sleep(30)
''')
        service.chmod(0o755)
        capsule = dict(manifest=dict(project_root=str(self.root / 'fixtures'), projects={'symphony-test': {}},
                                     main_instance=dict(pid=os.getpid(), started='fixture')))
        bootstrap = '''
import importlib.machinery,importlib.util,json,sys
loader=importlib.machinery.SourceFileLoader('pipeline',sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
plan=json.loads(sys.argv[2]);capsule=json.loads(sys.argv[3])
m.TEST.preflight=lambda *_:capsule
m.TEST.source=lambda *_:plan['source']
m.TEST.normal_service_running=lambda:True
m.TEST.process_started=lambda _:'fixture'
sys.exit(m.execute(plan))
'''
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
        for key in ('SYMPHONY_SERVICE_GUARD_PID', 'SYMPHONY_SERVICE_OWNER_PID'):
            env.pop(key, None)
        process = subprocess.run([sys.executable, '-c', bootstrap, str(REPO / 'scripts/test-instance-pipeline'),
                                  json.dumps(plan), json.dumps(capsule)], env=env, capture_output=True, timeout=15)
        self.assertEqual(process.returncode, 1, process.stderr)
        receipt = json.loads((self.args.result_dir / 'result.json').read_text())
        self.assertEqual(receipt['status'], 'timeout')
        self.assertEqual(receipt['acceptance'], 'pending_operator_evidence')
        self.assertEqual(receipt['cleanup'], 'pending_operator_reset')
        self.assertTrue(receipt['processes_stopped'])
        self.assertTrue((self.root / 'started.json').exists(), (self.args.result_dir / 'service.log').read_text())
        started = json.loads((self.root / 'started.json').read_text())
        self.assertEqual(started['workflow'], plan['workflow'])
        self.assertIsNone(started['stage'])
        self.assertIn('--test-instance', started['args'])
        self.assertIn('--yolo', started['args'])
        for pid in (started['pid'], started['worker']):
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True).stdout.strip()
            self.assertTrue(not state or state.startswith(b'Z'), state)

    def test_unexpected_issue_stops_before_any_acceptance_and_keeps_fixture_data_pending(self):
        plan = self.module.prepare(self.args)
        (self.root / '_build/symphony-source.json').write_text(json.dumps(self.source))
        binding = dict(project_id='fixture-project', workspace_id='fixture-workspace')
        capsule = dict(manifest=dict(project_root=str(self.root / 'fixtures'), projects={'symphony-test': binding},
                                     main_instance=dict(pid=23, started='fixture')))
        child = mock.Mock(pid=42)
        child.poll.return_value = None
        state = dict(service=dict(source=self.source, pid=42, test_instance=plan['run_id'],
                                  bindings=[dict(name='symphony-test', **binding)]),
                     running=[dict(issue_id='not-owned')])
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(state)
        with mock.patch.object(self.module.TEST, 'preflight', return_value=capsule), \
                mock.patch.object(self.module.TEST, 'normal_service_running', return_value=True), \
                mock.patch.object(self.module.TEST, 'process_started', return_value='fixture'), \
                mock.patch.object(self.module.subprocess, 'Popen', return_value=child), \
                mock.patch.object(self.module.urllib.request, 'urlopen', return_value=response), \
                mock.patch.object(self.module.PROCESSES, 'descendants'), \
                mock.patch.object(self.module.PROCESSES, 'cleanup') as cleanup, \
                mock.patch.object(self.module.os, 'killpg') as kill:
            self.assertEqual(self.module.execute(plan), 1)
        receipt = json.loads((self.args.result_dir / 'result.json').read_text())
        self.assertEqual(receipt['status'], 'unexpected_issue')
        self.assertEqual(receipt['sessions'], [])
        self.assertEqual(receipt['cleanup'], 'pending_operator_reset')
        cleanup.assert_called_once()
        kill.assert_called_once()
        child.wait.assert_called_once()


if __name__ == '__main__':
    unittest.main()
