"""Local runner protocol fixtures, explicitly not a Linear/Codex live acceptance."""
import importlib.util
import importlib.machinery
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
BOOT = r'''
import importlib.machinery,importlib.util,json,os,pathlib,signal,sys
loader=importlib.machinery.SourceFileLoader('runner',sys.argv[1])
spec=importlib.util.spec_from_loader('runner',loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
args=m.parser().parse_args(sys.argv[2:]);run=m.Run(args)
capsule=json.loads(os.environ['FIXTURE_CAPSULE'])
run.test.preflight=lambda *_: capsule
run.test.normal_service_running=lambda: True
run.test.process_started=lambda _: 'fixture-main'
run.fixture_journal_path=lambda: pathlib.Path(args.result_dir)/'fixtures.json'
run.competition=lambda: None # Real competing processes are covered separately.
run.result['evidence']='fixture'
def interrupt(number,_):
    signal.signal(number,signal.SIG_IGN)
    raise m.RunFailure('signal_'+str(number))
for number in (signal.SIGINT,signal.SIGTERM): signal.signal(number,interrupt)
sys.exit(run.execute())
'''
SERVICE = r'''
import http.server,json,os,pathlib,subprocess,sys,time
capsule=json.loads(os.environ['FIXTURE_CAPSULE'])
scenario=os.environ.get('FIXTURE_SCENARIO','success')
stage=os.environ['SYMPHONY_TEST_RUN_STAGE']
root=pathlib.Path(os.environ['SYMPHONY_TEST_RUN_PLAN']).parent
if scenario=='compile_failed': sys.exit(1) # No compiled runtime or fixture intent.
fixtures=[dict(id=str(i),project=name,created=True,deleted=False,complete=True) for i,name in enumerate(capsule['manifest']['projects'],1)]
if stage=='run':
    worker=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    with (root/'children').open('a') as f:f.write(str(worker.pid)+'\n')
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_): pass
        def do_GET(self):
            bindings=[dict(name=name,**value) for name,value in capsule['manifest']['projects'].items()]
            data=dict(service=dict(pid=os.getpid(),source=capsule['source'],test_instance='dev',bindings=bindings),
                      relay={entry['workspace_id']:dict(status='ready',consumer_id='fixture-'+entry['workspace_id']) for entry in bindings},
                      running=[dict(issue_id=f['id'],session_id='fixture-session-'+f['id']) for f in fixtures])
            if scenario=='not_ready': data['service']['source']={}
            self.send_response(200);self.end_headers();self.wfile.write(json.dumps(data).encode())
    http.server.HTTPServer(('127.0.0.1',int(sys.argv[-1])),Handler).serve_forever()
elif stage=='prepare':
    (root/'fixtures.json').write_text(json.dumps(dict(fixtures=fixtures)))
    (root/'remote-fixtures.json').write_text(json.dumps(fixtures))
    if scenario=='prepare_lost': sys.exit(1)
else:
    if stage=='cleanup':
        if scenario=='cleanup_failed':sys.exit(1)
        (root/'remote-fixtures.json').unlink(missing_ok=True)
        fixtures=[dict(f,deleted=True) for f in fixtures]
print('Test run result='+json.dumps(dict(fixtures=fixtures)),flush=True)
'''


class TestRunnerProtocol(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=REPO / 'tmp')
        self.root = Path(self.directory.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'bin').mkdir()
        for file in (self.source / 'symphony', self.source / 'bin/symphony'):
            file.write_text('#!' + sys.executable + '\n' + SERVICE)
            file.chmod(0o755)
        self.git(self.source, 'init', '-qb', 'main')
        self.git(self.source, 'add', '.')
        self.git(self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        self.fakebin = self.root / 'tools'
        self.fakebin.mkdir()
        (self.fakebin / 'mise').write_text('#!/bin/sh\nshift\nshift\nexec "$@"\n')
        (self.fakebin / 'mise').chmod(0o755)
        self.collector = self.root / 'fixtures'
        self.bindings = {}
        for i, name in enumerate(('symphony-test', 'symphony-test-tilor'), 1):
            project = self.collector / name
            project.mkdir(parents=True)
            (project / 'unrelated').write_text('preserve')
            self.git(project, 'init', '-qb', 'main')
            self.git(project, 'add', '.')
            self.git(project, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
            (project / 'local-edit').write_text('keep existing untracked work')
            self.bindings[name] = dict(project_id='p' + str(i), workspace_id='w' + str(i))
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text(json.dumps(dict(project_root=str(self.collector))))
        self.children = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for process in self.children:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=20)
        self.directory.cleanup()

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def start(self, scenario='success', checkout=None, mode='development', resume=False, cleanup=False, probe=False):
        checkout = checkout or self.source
        spec = importlib.util.spec_from_file_location('test_instance', REPO / 'scripts/test-instance.py')
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        source = helper.source(checkout)
        self.result_dir = self.root / ('results-' + scenario)
        if cleanup and resume:
            source = json.loads((self.result_dir/'plan.json').read_text())['source']
        capsule = dict(source=source, name='dev', manifest=dict(projects=self.bindings,project_root=str(self.collector),
                      main_instance=dict(pid=os.getpid(),started='fixture-main')))
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
        args = ['--checkout',str(checkout),'--test-instance','dev','--manifest',str(self.manifest),'--run-id','fixture',
                '--expected-sha',source['sha'],'--expected-source',source['source_sha256'],'--port',str(port),
                '--result-dir',str(self.result_dir),'--timeout','2' if scenario=='not_ready' else '10','--source-mode',mode]
        if probe:args+=['--scenario','failure-probe']
        if resume:args+=['--resume']
        if cleanup:args+=['--cleanup-only']
        env=dict(os.environ,FIXTURE_CAPSULE=json.dumps(capsule),FIXTURE_SCENARIO="recovered" if cleanup else scenario,
                 PATH=str(self.fakebin)+os.pathsep+os.environ['PATH'])
        for key in ('SYMPHONY_SERVICE_GUARD_PID','SYMPHONY_SERVICE_OWNER_PID','SYMPHONY_PROJECT_CONTEXT'):
            env.pop(key,None)
        process=subprocess.Popen([sys.executable,'-c',BOOT,str(REPO/'scripts/test-instance-run'),*args],
                                 env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.children.append(process)
        return process

    def receipt(self, process, originals=True):
        output,error=process.communicate(timeout=25)
        self.assertTrue((self.result_dir/'result.json').exists(),error.decode())
        result=json.loads((self.result_dir/'result.json').read_text())
        self.assertEqual(result['evidence'],'fixture')
        if originals:
            self.assertTrue(result['originals_preserved'])
        children=self.result_dir/'children'
        if children.exists():
            for pid in children.read_text().splitlines():
                state=subprocess.run(['ps','-p',pid,'-o','stat='],capture_output=True).stdout.strip()
                self.assertTrue(not state or state.startswith(b'Z'),(pid,state))
        return result

    def test_intentional_probe_cleans_fixtures_before_corrected_source_retest(self):
        failed = self.start(scenario='negative-probe', probe=True)
        result = self.receipt(failed)
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(result['error'], 'intentional_failure_probe')
        self.assertTrue(result['cleanup'])
        self.assertTrue(result['main_preserved'])
        self.assertTrue(result['originals_preserved'])
        self.assertFalse((self.result_dir/'remote-fixtures.json').exists())
        (self.source/'corrected-source').write_text('correction after negative integration result')
        passed = self.start(scenario='corrected-probe')
        corrected = self.receipt(passed)
        self.assertEqual(passed.returncode, 0)
        self.assertNotEqual(result['source']['source_sha256'], corrected['source']['source_sha256'])
        self.assertTrue(corrected['cleanup'])

    def test_compile_failure_without_fixture_intent_allows_corrected_retest(self):
        failed = self.start(scenario='compile_failed')
        result = self.receipt(failed)
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(result['error'], 'prepare_failed')
        self.assertTrue((self.result_dir/'plan.json').exists())
        self.assertFalse((self.result_dir/'fixtures.json').exists())
        self.assertTrue(result['cleanup'])
        self.assertEqual(result['cleanup_scope'], 'no_fixture_intent')
        self.assertEqual(result['status'], 'failed')
        # Recover an older receipt after an executor restart, even when the
        # original broken source/build is no longer available.
        result['cleanup'] = False
        (self.result_dir/'result.json').write_text(json.dumps(result))
        (self.source/'bin/symphony').unlink()
        (self.source/'corrected-source').write_text('compile error fixed')
        recovered = self.receipt(self.start(scenario='compile_failed', resume=True, cleanup=True))
        self.assertTrue(recovered['cleanup'])
        self.assertEqual(recovered['source'], result['source'])
        self.assertEqual(recovered['status'], 'failed')
        (self.source/'bin/symphony').write_bytes((self.source/'symphony').read_bytes())
        (self.source/'bin/symphony').chmod(0o755)
        corrected = self.start(scenario='corrected-build')
        self.assertEqual(self.receipt(corrected)['status'], 'passed')

    def test_existing_or_uncertain_fixture_journal_still_requires_runtime_cleanup(self):
        loader = importlib.machinery.SourceFileLoader('runner_journal', str(REPO / 'scripts/test-instance-run'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        runner = importlib.util.module_from_spec(spec)
        loader.exec_module(runner)
        args = runner.parser().parse_args([
            '--checkout', str(self.source), '--test-instance', 'dev', '--manifest', str(self.manifest),
            '--run-id', 'fixture', '--expected-sha', 'a' * 40, '--expected-source', 'b' * 64,
            '--port', '4101', '--result-dir', str(self.root/'results')])
        run = runner.Run(args)
        journal = self.root/'fixtures.json'
        run.fixture_journal_path = lambda: journal
        for contents in ('broken JSON', '{}', '{"fixtures": []}'):
            journal.write_text(contents)
            self.assertFalse(run.confirm_no_fixture_intent())
            self.assertFalse(run.result['cleanup'])
        journal.unlink()
        journal.symlink_to(self.root/'missing-journal')
        self.assertFalse(run.confirm_no_fixture_intent())
        with mock.patch.object(run.test, 'canonical', side_effect=PermissionError):
            self.assertFalse(run.confirm_no_fixture_intent())

    def test_complete_development_run_and_independent_merged_checkout(self):
        first=self.start()
        result=self.receipt(first)
        self.assertEqual(first.returncode,0,result)
        self.assertEqual(result['status'],'passed')
        self.assertTrue(result['cleanup'])
        self.assertTrue(result['scenarios']['resume']['passed'])
        independent=self.root/'independent'
        remote=self.root/'remote.git'
        subprocess.run(['git','clone','-q','--bare',str(self.source),str(remote)],check=True)
        subprocess.run(['git','clone','-q',str(remote),str(independent)],check=True)
        # Git applies the caller's umask; this fixture compares identical file
        # modes as well as contents, even under a restrictive operator umask.
        for path in ('symphony', 'bin/symphony'):
            (independent/path).chmod((self.source/path).stat().st_mode & 0o777)
        self.source.rename(self.root/'unavailable')
        second=self.start('separate',independent,'merged')
        next_result=self.receipt(second)
        self.assertEqual(second.returncode,0,next_result)
        self.assertEqual(next_result['source']['sha'],result['source']['sha'])
        self.assertEqual(next_result['source']['source_sha256'],result['source']['source_sha256'])
        self.assertEqual(next_result['source']['checkout'],str(independent))

    def test_timeout_missing_readiness_and_partial_prepare_preserve_failure_and_cleanup(self):
        for scenario in ('not_ready','prepare_lost','cleanup_failed'):
            with self.subTest(scenario=scenario):
                process=self.start(scenario)
                result=self.receipt(process)
                self.assertEqual(process.returncode,1,result)
                self.assertEqual(result['status'],'failed')
                self.assertEqual(result['cleanup'],scenario!='cleanup_failed')

    def test_partial_cleanup_is_resumed_without_recreating_fixtures(self):
        first=self.start('cleanup_failed')
        failed=self.receipt(first)
        self.assertFalse(failed['cleanup'])
        self.assertTrue((self.result_dir/'remote-fixtures.json').exists())
        second=self.start('cleanup_failed',resume=True,cleanup=True)
        recovered=self.receipt(second)
        self.assertTrue(recovered['cleanup'])
        self.assertEqual(recovered['status'],'failed')
        self.assertFalse((self.result_dir/'remote-fixtures.json').exists())
        self.assertTrue(list(self.result_dir.glob('result-*.json')))

    def test_signals_cleanup_own_descendants_and_preserve_receipts(self):
        for number in (signal.SIGINT,signal.SIGTERM):
            process=self.start('signal-'+str(number))
            deadline=time.monotonic()+10
            while not (self.result_dir/'children').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.result_dir/'children').exists())
            process.send_signal(number)
            result=self.receipt(process)
            self.assertEqual(result['status'],'failed')
            self.assertTrue(result['cleanup'])
            self.assertIn('signal_',result['error'])

    def test_resume_preserves_previous_evidence_when_preflight_fails(self):
        loader = importlib.machinery.SourceFileLoader('runner_resume', str(REPO / 'scripts/test-instance-run'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        runner = importlib.util.module_from_spec(spec)
        loader.exec_module(runner)
        results = self.root / 'resume-results'
        results.mkdir()
        previous = dict(status='failed', sessions={'one': 'session-1'}, scenarios={'readiness': True},
                        original_projects={'one': dict(checkout=str(self.source))})
        (results / 'result.json').write_text(json.dumps(previous))
        args = runner.parser().parse_args([
            '--checkout', str(self.source), '--test-instance', 'dev', '--manifest', str(self.manifest),
            '--run-id', 'fixture', '--expected-sha', 'a' * 40, '--expected-source', 'b' * 64,
            '--port', '4101', '--result-dir', str(results), '--resume'])
        run = runner.Run(args)
        with mock.patch.object(run.test, 'preflight', side_effect=ValueError('source changed')):
            self.assertEqual(run.execute(), 1)
        archives = list(results.glob('result-*.json'))
        self.assertEqual(len(archives), 1)
        self.assertEqual(json.loads(archives[0].read_text()), previous)

    def test_merged_fetch_obeys_run_timeout_and_reaps_its_process(self):
        slow_git = self.fakebin / 'git'
        real_git = subprocess.check_output(['which', 'git']).decode().strip()
        slow_git.write_text('#!' + sys.executable + '\n' +
                            "import os,sys,time,pathlib\n" +
                            "if 'fetch' in sys.argv:\n" +
                            " pathlib.Path(os.environ['FETCH_PID_FILE']).write_text(str(os.getpid()))\n time.sleep(120)\n" +
                            "os.execv(" + repr(real_git) + ",[" + repr(real_git) + ",*sys.argv[1:]])\n")
        slow_git.chmod(0o755)
        marker = self.root / 'fetch-pid'
        with mock.patch.dict(os.environ, FETCH_PID_FILE=str(marker)):
            process = self.start('not_ready', mode='merged')
        result = self.receipt(process, originals=False)
        self.assertEqual(process.returncode, 1, result)
        self.assertEqual(result['error'], 'fetch_timeout')
        self.assertLess(result['finished_at'] - result['started_at'], 8)
        self.assertTrue(marker.exists())
        state = subprocess.run(['ps', '-p', marker.read_text(), '-o', 'stat='], capture_output=True).stdout.strip()
        self.assertTrue(not state or state.startswith(b'Z'), state)


if __name__=='__main__':unittest.main()
