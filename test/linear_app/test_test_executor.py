"""Bound executor tests. All receipts are synthetic, never live acceptance."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = Path(__file__).resolve().parents[2]


def load(path):
    spec = importlib.util.spec_from_file_location('test_executor', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestExecutor(unittest.TestCase):
    def setUp(self):
        (REPO / 'tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=REPO / 'tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / 'PRO-756'
        self.checkout.mkdir()
        (self.checkout / 'source').write_text('first version')
        for args in [('init', '-q'), ('add', '.'), ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'base')]:
            subprocess.run(['git', '-C', str(self.checkout), *args], check=True, capture_output=True)
        self.module = load(REPO / 'scripts/test-executor.py')
        self.config = dict(issue_id='11111111-1111-4111-8111-111111111111', identifier='PRO-756', checkout=str(self.checkout),
                           manifest=str(self.root / 'manifest.json'), result_root=str(self.root / 'results'), instance='development', port=4101, timeout=10)
        self.calls = []
        self.executor = self.module.Executor(self.config, self.launch)

    def request(self, operation='start', run='run-1', scenario='bootstrap'):
        source = self.module.helper().source(self.checkout)
        return dict(operation=operation, run_id=run, scenario=scenario, head_sha=source['sha'], source_sha256=source['source_sha256'],
                    **{key: self.config[key] for key in ('issue_id', 'identifier', 'checkout')})

    def launch(self, directory, descriptor, cleanup):
        self.calls.append((directory, cleanup))
        request = self.module.read(directory / 'request.json')['request']
        result = dict(evidence='fixture', run_id=request['run_id'], source=dict(checkout=request['checkout'], sha=request['head_sha'], source_sha256=request['source_sha256']),
                      cleanup=True, status='failed' if request['scenario'] == 'failure-probe' else 'passed', main_preserved=True, originals_preserved=True,
                      scenarios={'bootstrap': {'passed': True}, 'private': {'secret': 'must not escape'}}, raw_secret='must not escape')
        self.module.atomic(directory / 'result.json', result)
        self.module.atomic(directory / 'executor-result.json', dict(exit_code=1 if result['status'] == 'failed' else 0, cleanup_only=cleanup))

    def test_failed_probe_corrected_source_and_new_run_with_idempotent_replay(self):
        first = self.request(scenario='failure-probe')
        self.assertEqual(self.executor.handle(first)['status'], 'failed')
        self.assertTrue(self.executor.handle(dict(first, operation='result'))['cleanup'])
        (self.checkout / 'source').write_text('corrected version')
        second = self.request(run='run-2')
        self.assertNotEqual(first['source_sha256'], second['source_sha256'])
        result = self.executor.handle(second)
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['evidence'], 'fixture')
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(self.executor.handle(second), result)
        resumed = self.module.Executor(self.config, self.launch)
        self.assertEqual(resumed.handle(second), result)
        self.assertEqual(len(self.calls), 2)
        self.assertTrue((Path(self.config['result_root']) / 'run-1/result.json').exists())

    def test_rejects_foreign_bindings_paths_unknown_operations_and_changed_source(self):
        good = self.request()
        cases = [dict(good, checkout=str(self.root)), dict(good, issue_id='foreign'), dict(good, identifier='PRO-999'),
                 dict(good, manifest='/private/env'), dict(good, run_id='../escape'), dict(good, scenario='shell'),
                 dict(good, operation='restart-main'), dict(good, head_sha=None)]
        for bad in cases:
            self.assertIn('error', self.executor.handle(bad))
        (self.checkout / 'source').write_text('changed during request')
        self.assertEqual(self.executor.handle(good)['error'], 'test_source_changed')
        self.assertEqual(self.calls, [])
        self.assertEqual(self.executor.handle(self.request(operation='cleanup'))['error'], 'test_run_not_found')

    def test_pending_run_blocks_new_sources_and_cleanup_never_upgrades_failure(self):
        first = self.request(scenario='failure-probe')
        self.executor.handle(first)
        directory = Path(self.config['result_root']) / 'run-1'
        result = self.module.read(directory / 'result.json')
        result['cleanup'] = False
        self.module.atomic(directory / 'result.json', result)
        self.assertEqual(self.executor.handle(self.request(run='run-2'))['error'], 'test_environment_needs_cleanup')
        self.assertIn('error', self.executor.handle(dict(first, scenario='bootstrap')))
        result = self.executor.handle(dict(first, operation='cleanup'))
        self.assertTrue(result['cleanup'])
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(self.calls[-1][1])
        self.assertEqual(self.executor.handle(self.request(run='run-2'))['status'], 'passed')

    def test_live_lock_survives_server_restart_and_cancel_only_marks_owned_run(self):
        locks = []
        def launch(directory, descriptor, _cleanup):
            locks.append(os.dup(descriptor))
        self.executor.launch = launch
        request = self.request()
        try:
            self.assertTrue(self.executor.handle(request)['running'])
            restarted = self.module.Executor(self.config, launch)
            self.assertTrue(restarted.handle(request)['running'])
            self.assertEqual(len(locks), 1)
            self.assertEqual(restarted.handle(self.request(run='other'))['error'], 'test_environment_needs_cleanup')
            self.assertTrue(restarted.handle(dict(request, operation='cancel'))['running'])
            self.assertTrue((Path(self.config['result_root']) / 'run-1/cancel.json').exists())
        finally:
            for descriptor in locks:
                os.close(descriptor)

    def test_lost_socket_response_does_not_repeat_a_start(self):
        endpoint = self.root / 'e.sock'
        with socketserver.UnixStreamServer(str(endpoint), self.module.Handler) as server:
            server.executor = self.executor
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(str(endpoint))
                    client.sendall(json.dumps(self.request()).encode() + b'\n')
                    # Deliberately discard the start response.
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(str(endpoint))
                    client.sendall(json.dumps(self.request()).encode() + b'\n')
                    result = json.loads(client.makefile().readline())
                self.assertEqual(result['status'], 'passed')
                self.assertEqual(len(self.calls), 1)
            finally:
                server.shutdown()
                thread.join()

    def test_symlink_result_alias_and_invalid_operator_config_fail_closed(self):
        external = self.root / 'foreign'
        external.mkdir()
        (Path(self.config['result_root']) / 'run-1').symlink_to(external, target_is_directory=True)
        self.assertIn('error', self.executor.handle(self.request()))
        self.assertEqual(list(external.iterdir()), [])
        with self.assertRaises(ValueError):
            self.module.Executor(dict(self.config, result_root=str(self.checkout / 'results')))

    def test_supervisor_reuses_runner_and_handles_cancellation_without_exposing_logs(self):
        scripts = self.root / 'installed'
        scripts.mkdir()
        for name in ('test-executor.py', 'test-instance.py'):
            shutil.copy(REPO / 'scripts' / name, scripts / name)
        # A real subprocess fixture replaces only the external runner. It writes
        # a plan before activity and receives the exact bounded runner arguments.
        (scripts / 'test-instance-run').write_text('''import json,pathlib,signal,sys,time
args=dict(zip(sys.argv[1::2],sys.argv[2::2]));root=pathlib.Path(args['--result-dir'])
(root/'plan.json').write_text('{}')
result=dict(evidence='fixture',run_id=args['--run-id'],source=dict(checkout=args['--checkout'],sha=args['--expected-sha'],source_sha256=args['--expected-source']),status='failed',cleanup=False)
def stop(*_):
 result['cleanup']=True;(root/'result.json').write_text(json.dumps(result));sys.exit(1)
signal.signal(signal.SIGTERM,stop)
print('private operator diagnostic',flush=True)
while True:time.sleep(.02)
''')
        installed = load(scripts / 'test-executor.py')
        executor = installed.Executor(self.config)
        request = self.request()
        reply = executor.handle(request)
        self.assertTrue(reply['running'])
        self.addCleanup(lambda: [child.wait(timeout=15) for child in executor.children])
        directory = Path(self.config['result_root']) / 'run-1'
        deadline = time.monotonic() + 10
        while not (directory / 'plan.json').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((directory / 'plan.json').exists())
        executor.handle(dict(request, operation='cancel'))
        while executor.handle(dict(request, operation='result'))['running'] and time.monotonic() < deadline:
            time.sleep(.02)
        reply = executor.handle(dict(request, operation='result'))
        self.assertFalse(reply['running'])
        self.assertTrue(reply['cleanup'])
        self.assertEqual(reply['status'], 'failed')
        self.assertNotIn('private', json.dumps(reply))
        self.assertIn('private operator diagnostic', (directory / 'executor.log').read_text())
