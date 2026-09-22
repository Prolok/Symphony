"""Local runner protocol fixtures, explicitly not a Linear/Codex live acceptance."""
import importlib.util
import importlib.machinery
import hashlib
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
with (root/'stages').open('a') as stream: stream.write(stage+'\n')
if scenario=='compile_failed': sys.exit(1) # No compiled runtime or fixture intent.
fixtures=[dict(id=str(i),project=name,created=True,deleted=False,complete=True) for i,name in enumerate(capsule['manifest']['projects'],1)]
if json.loads((root/'plan.json').read_text()).get('scenario')=='delegation':
    fixtures=[dict(f,test_delegate_id='fixture-agent') if f['project']=='symphony-test' else f for f in fixtures]
if json.loads((root/'plan.json').read_text()).get('scenario') in ('po_incoming','po_aggregation'):
    base=next(f for f in fixtures if f['project']=='symphony-test')
    po=[dict(base,id='po-'+str(i),po_incoming=True,initial_state=name,
             po_receipt=dict(session_id='shared-po' if scenario!='split_po_session' else str(i),
                             sha='a'*40,workspace='owned-po'))
        for i,name in enumerate(('Backlog','Todo','Definiert'))]
    if scenario=='wrong_po_members': po[-1]['initial_state']='Backlog'
    fixtures=fixtures+po
if json.loads((root/'plan.json').read_text()).get('scenario') in ('po_handoff','po_followup'):
    base=next(f for f in fixtures if f['project']=='symphony-test')
    fixtures=fixtures+[
        dict(base,id='handoff-'+name,po_handoff=True,initial_state=name,
             handoff_receipt=dict(session_id='s-'+name,sha='a'*40,workspace='owned',report='actual test'))
        for name in (('BLOCKER','Yolo Review') if json.loads((root/'plan.json').read_text()).get('scenario')=='po_handoff' else ('Yolo Review',))]
    if scenario=='bad_handoff_receipt': fixtures[-1]['handoff_receipt'].pop('sha')
    if scenario=='bad_handoff_members': fixtures[-1]['initial_state']='BLOCKER'
derived=[]
if json.loads((root/'plan.json').read_text()).get('scenario') in ('po_aggregation','po_followup'):
    derived=[dict(input=dict(id='derived-one'),complete=scenario!='incomplete_derived',deleted=False)]
    if scenario=='missing_derived': derived=[]
if scenario=='duplicate_fixtures': fixtures *= 2
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
            if scenario=='missing_session': data['running']=[]
            if scenario=='duplicate_session': data['running'] *= 2
            self.send_response(200);self.end_headers();self.wfile.write(json.dumps(data).encode())
    http.server.HTTPServer(('127.0.0.1',int(sys.argv[sys.argv.index('--port')+1])),Handler).serve_forever()
elif stage=='prepare':
    (root/'fixtures.json').write_text(json.dumps(dict(fixtures=fixtures)))
    (root/'remote-fixtures.json').write_text(json.dumps(fixtures))
    if scenario=='prepare_lost': sys.exit(1)
else:
    if stage=='probe' and scenario in ('probe_failed', 'probe_transient', 'probe_503'):
        with (root/'probe-attempts').open('a') as stream: stream.write('attempt\n')
        if scenario=='probe_failed' or (root/'probe-attempts').read_text().count('attempt')==1:
            failure = dict(code='linear_http', status=503) if scenario=='probe_503' else dict(code='linear_app_request_unavailable')
            print('Test run failure='+json.dumps(dict(failure,provider='private payload')),flush=True)
            sys.exit(1)
    if stage in ('delegate','withdraw'):
        (root/'delegation-stage').write_text(stage)
    if stage=='probe' and (root/'delegation-stage').exists() and scenario!='no_delegation_event':
        fixtures=[dict(f,delegation_assigned={'cursor':1},**({'delegation_withdrawn':{'cursor':2}} if (root/'delegation-stage').read_text()=='withdraw' else {})) if f.get('test_delegate_id') else f for f in fixtures]
    if stage=='cleanup':
        if scenario=='cleanup_failed':sys.exit(1)
        (root/'remote-fixtures.json').unlink(missing_ok=True)
        fixtures=[dict(f,deleted=True) for f in fixtures]
        derived=[dict(f,deleted=scenario!='derived_cleanup_failed') for f in derived]
print('Test run result='+json.dumps(dict(fixtures=fixtures,derived=derived)),flush=True)
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
        for i, name in enumerate(('symphony-test',), 1):
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

    def start(self, scenario='success', checkout=None, mode='development', resume=False, cleanup=False, selected='bootstrap', yolo=False, recovery=False, probe=False):
        checkout = checkout or self.source
        spec = importlib.util.spec_from_file_location('test_instance', REPO / 'scripts/test-instance.py')
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        source = helper.source(checkout)
        self.result_dir = self.root / ('results-' + scenario)
        if cleanup and resume and not recovery:
            source = json.loads((self.result_dir/'plan.json').read_text())['source']
        capsule = dict(source=source, name='dev', manifest=dict(projects=self.bindings,project_root=str(self.collector),
                      main_instance=dict(pid=os.getpid(),started='fixture-main')))
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
        args = ['--checkout',str(checkout),'--test-instance','dev','--manifest',str(self.manifest),'--run-id','fixture',
                '--expected-sha',source['sha'],'--expected-source',source['source_sha256'],'--port',str(port),
                '--scenario',selected,'--result-dir',str(self.result_dir),'--timeout','2' if scenario in ('not_ready', 'missing_session') else '10','--source-mode',mode]
        if yolo:args+=['--yolo']
        if probe:args += ["--scenario", "failure-probe"]
        if resume:args+=['--resume']
        if cleanup:args+=['--cleanup-only']
        if recovery:
            plan_path = self.result_dir/'plan.json'
            plan = json.loads(plan_path.read_text())
            digest = hashlib.sha256(plan_path.read_bytes()).hexdigest()
            capsule['cleanup_recovery'] = dict(source=plan['source'], plan_path=str(plan_path), plan_sha256=digest)
            args += ['--cleanup-plan-sha256', digest]
        env=dict(os.environ,FIXTURE_CAPSULE=json.dumps(capsule),FIXTURE_SCENARIO="recovered" if cleanup else scenario,
                 PATH=str(self.fakebin)+os.pathsep+os.environ['PATH'])
        for key in ('SYMPHONY_SERVICE_GUARD_PID','SYMPHONY_SERVICE_OWNER_PID','SYMPHONY_PROJECT_CONTEXT'):
            env.pop(key,None)
        process=subprocess.Popen([sys.executable,'-c',BOOT,str(REPO/'scripts/test-instance-run'),*args],
                                 env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.children.append(process)
        return process


    def test_delegation_driver_assigns_withdraws_and_keeps_bootstrap_and_cleanup(self):
        result = self.receipt(self.start(selected='delegation'))
        self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['scenarios']['delegation']['passed'])
        self.assertTrue(result['scenarios']['bootstrap']['passed'])
        self.assertTrue(result['cleanup'])
        self.assertEqual((self.result_dir / 'delegation-stage').read_text(), 'withdraw')

    def test_missing_delegation_event_is_not_reported_as_live_success(self):
        result = self.receipt(self.start(scenario='no_delegation_event', selected='delegation'))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error'], 'delegation_assignment_unconfirmed')
        self.assertTrue(result['cleanup'])

    def test_po_incoming_requires_one_session_and_all_three_states(self):
        result = self.receipt(self.start(selected='po_incoming'))
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(len(result['scenarios']['po_incoming']['fixtures']), 3)
        self.assertEqual(len(set(result['sessions'].values())), 2)
        self.assertTrue(result['cleanup'])
        for scenario, error in [('split_po_session', 'po_shared_session_unconfirmed'),
                                ('wrong_po_members', 'invalid_fixture_mapping')]:
            with self.subTest(scenario=scenario):
                failed = self.receipt(self.start(scenario=scenario, selected='po_incoming'))
                self.assertEqual(failed['status'], 'failed')
                self.assertEqual(failed['error'], error)
                self.assertTrue(failed['cleanup'])

    def test_handoff_requires_blocker_review_and_actual_receipts(self):
        result = self.receipt(self.start(selected='po_handoff'))
        self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['scenarios']['po_handoff']['passed'])
        self.assertTrue(result['cleanup'])
        for scenario, error in [('bad_handoff_receipt', 'po_handoff_receipt_unconfirmed'),
                                ('bad_handoff_members', 'invalid_fixture_mapping')]:
            failed = self.receipt(self.start(scenario=scenario, selected='po_handoff'))
            self.assertEqual(failed['status'], 'failed')
            self.assertEqual(failed['error'], error)
            self.assertTrue(failed['cleanup'])

    def test_derived_proofs_require_creation_receipts_and_cleanup_in_both_start_modes(self):
        for selected, yolo in [('po_aggregation', False), ('po_followup', False), ('po_followup', True)]:
            with self.subTest(selected=selected, yolo=yolo):
                result = self.receipt(self.start(scenario=selected+str(yolo), selected=selected, yolo=yolo))
                self.assertEqual(result['status'], 'passed')
                self.assertTrue(result['scenarios'][selected]['passed'])
                self.assertTrue(result['derived'][0]['deleted'])
                self.assertEqual(json.loads((self.result_dir/'plan.json').read_text())['yolo'], yolo)
        for scenario in ['incomplete_derived', 'missing_derived', 'derived_cleanup_failed']:
            result = self.receipt(self.start(scenario=scenario, selected='po_aggregation'))
            self.assertEqual(result['status'], 'failed')
            if scenario == 'derived_cleanup_failed':
                self.assertFalse(result['cleanup'])
            else:
                self.assertEqual(result['error'], 'derived_fixture_unconfirmed')
                self.assertNotIn('po_aggregation', result['scenarios'])
                self.assertTrue(result['cleanup'])

    def test_transient_read_probe_recovers_in_same_run_and_cleans_up(self):
        result = self.receipt(self.start(scenario='probe_transient', selected='po_aggregation'))
        self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['scenarios']['po_aggregation']['passed'])
        self.assertEqual((self.result_dir / 'probe-attempts').read_text(), 'attempt\nattempt\n')
        self.assertEqual(result['probe_retries'], [dict(attempt=2, delay_seconds=2,
                         failure=dict(code='linear_app_request_unavailable'))])
        self.assertNotIn('runtime_failure', result)
        self.assertTrue(result['cleanup'])
        self.assertTrue(result['main_preserved'])
        stages = (self.result_dir / 'stages').read_text().splitlines()
        self.assertEqual(stages.count('prepare'), 1)
        self.assertEqual(stages.count('run'), 2)  # Initial service and the required restart proof.
        self.assertEqual(stages.count('cleanup'), 1)

    def test_failed_handoff_probe_exhausts_two_retries_and_cleans_up(self):
        process = self.start(scenario='probe_failed', selected='po_handoff')
        result = self.receipt(process)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error'], 'probe_failed')
        self.assertEqual(result['runtime_failure'], {'code': 'linear_app_request_unavailable'})
        self.assertNotIn('po_handoff', result['scenarios'])
        self.assertNotIn('bootstrap', result['scenarios'])
        self.assertEqual((self.result_dir / 'probe-attempts').read_text(), 'attempt\n' * 3)
        self.assertEqual([r['delay_seconds'] for r in result['probe_retries']], [2, 5])
        self.assertTrue(result['cleanup'])
        self.assertTrue(result['main_preserved'])
        self.assertFalse((self.result_dir / 'remote-fixtures.json').exists())
        recovered = self.receipt(self.start(scenario='probe_failed', selected='po_handoff', resume=True, cleanup=True))
        self.assertEqual(recovered['status'], 'failed')
        self.assertEqual(recovered['probe_retries'], result['probe_retries'])
        self.assertTrue(recovered['cleanup'])
        self.assertEqual((self.result_dir / 'probe-attempts').read_text(), 'attempt\n' * 3)
        archive = next(self.result_dir.glob('result-*.json'))
        self.assertEqual(json.loads(archive.read_text()), result)

    def test_http_503_probe_recovers_without_replaying_mutations(self):
        result = self.receipt(self.start(scenario='probe_503', selected='po_followup', yolo=True))
        self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['scenarios']['po_followup']['passed'])
        self.assertEqual((self.result_dir / 'probe-attempts').read_text(), 'attempt\nattempt\n')
        self.assertEqual(result['probe_retries'], [dict(attempt=2, delay_seconds=2,
                         failure=dict(code='linear_http', status=503))])
        self.assertNotIn('runtime_failure', result)
        self.assertTrue(result['cleanup'])
        self.assertTrue(result['main_preserved'])
        stages = (self.result_dir / 'stages').read_text().splitlines()
        self.assertEqual(stages.count('prepare'), 1)
        self.assertEqual(stages.count('run'), 2)  # Required restart proof, not error recovery.
        self.assertEqual(stages.count('cleanup'), 1)

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

    def test_fixture_and_session_assignments_are_complete_nonempty_and_unique(self):
        loader = importlib.machinery.SourceFileLoader('runner_mapping', str(REPO / 'scripts/test-instance-run'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        runner = importlib.util.module_from_spec(spec)
        loader.exec_module(runner)
        run = object.__new__(runner.Run)
        fixture = dict(id='one', project='symphony-test', created=True, deleted=False)
        self.assertEqual(run.fixture_ids([fixture], self.bindings), {'one': ('symphony-test', 'Todo (AI)')})
        for fixtures in ([], [fixture, fixture], [dict(fixture, id='')], [dict(fixture, project='unknown')],
                         [dict(fixture, created=False)], [dict(fixture, deleted=True)]):
            with self.subTest(fixtures=fixtures), self.assertRaises(runner.RunFailure):
                run.fixture_ids(fixtures, self.bindings)
        with self.assertRaises(runner.RunFailure):
            run.fixture_ids([], {})
        sessions = {}
        run.collect_sessions([dict(issue_id='one', session_id=None)], {'one': 'symphony-test'}, sessions)
        self.assertEqual(sessions, {})
        entry = dict(issue_id='one', session_id='session')
        run.collect_sessions([entry], {'one': 'symphony-test'}, sessions)
        self.assertEqual(sessions, {'one': 'session'})
        for running in ([entry, entry], [dict(entry, issue_id='foreign')], [dict(entry, session_id=' ')],
                        [entry, dict(entry, issue_id='two')]):
            with self.subTest(running=running), self.assertRaises(runner.RunFailure):
                run.collect_sessions(running, {'one': 'synthetic-a', 'two': 'synthetic-b'}, {})

    def test_po_mapping_keeps_bootstrap_and_shared_members_distinct(self):
        loader = importlib.machinery.SourceFileLoader('runner_po_mapping', str(REPO / 'scripts/test-instance-run'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        runner = importlib.util.module_from_spec(spec)
        loader.exec_module(runner)
        run = object.__new__(runner.Run)
        fixtures = [dict(id=str(i), project='symphony-test', initial_state=state, created=True, deleted=False)
                    for i, state in enumerate(('Todo (AI)', 'Backlog', 'Todo', 'Definiert'))]
        mapping = run.fixture_ids(fixtures, self.bindings, 'po_aggregation')
        sessions = {}
        run.collect_sessions([dict(issue_id=str(i), session_id='bootstrap' if i == 0 else 'po') for i in range(4)],
                             mapping, sessions, {'1', '2', '3'})
        self.assertEqual(set(sessions.values()), {'bootstrap', 'po'})
        for running in ([dict(issue_id='0', session_id='po')], [dict(issue_id='outside', session_id='extra')]):
            with self.assertRaises(runner.RunFailure):
                run.collect_sessions(running, mapping, dict(sessions), {'1', '2', '3'})
        for invalid in (fixtures[:-1], [dict(f, initial_state='Todo (AI)') for f in fixtures],
                        [*fixtures[:3], dict(fixtures[3], id=fixtures[2]['id'])]):
            with self.assertRaises(runner.RunFailure):
                run.fixture_ids(invalid, self.bindings, 'po_aggregation')

    def test_invalid_or_missing_assignments_never_pass_and_still_clean_up(self):
        for scenario, error in (('duplicate_fixtures', 'invalid_fixture_mapping'),
                                ('duplicate_session', 'invalid_session_mapping'), ('missing_session', 'timeout')):
            with self.subTest(scenario=scenario):
                process = self.start(scenario)
                result = self.receipt(process)
                self.assertEqual(process.returncode, 1)
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(result['error'], error)
                self.assertTrue(result['cleanup'])

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

    def test_corrected_cleanup_keeps_original_plan_and_failure_with_separate_build_receipt(self):
        failed = self.receipt(self.start('cleanup_failed', selected='po_aggregation'))
        original_plan = (self.result_dir/'plan.json').read_bytes()
        children = (self.result_dir/'children').read_bytes()
        (self.source/'correction').write_text('corrected cleanup')
        recovered = self.receipt(self.start('cleanup_failed', selected='po_aggregation', resume=True, cleanup=True, recovery=True))
        self.assertTrue(recovered['cleanup'])
        self.assertEqual(recovered['status'], 'failed')
        self.assertEqual(recovered['cleanup_recovery']['source'], failed['source'])
        self.assertNotEqual(recovered['source'], failed['source'])
        self.assertEqual((self.result_dir/'plan.json').read_bytes(), original_plan)
        self.assertEqual((self.result_dir/'children').read_bytes(), children)
        self.assertEqual(len(recovered['fixtures']) + len(recovered['derived']), 5)
        self.assertNotIn('po_aggregation', recovered['scenarios'])
        self.assertTrue(any(json.loads(path.read_text()) == failed for path in self.result_dir.glob('result-*.json')))

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


class ProbeRetryBudget(unittest.TestCase):
    def setUp(self):
        loader = importlib.machinery.SourceFileLoader('probe_runner', str(REPO / 'scripts/test-instance-run'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.runner = importlib.util.module_from_spec(spec)
        loader.exec_module(self.runner)
        self.run = self.runner.Run.__new__(self.runner.Run)
        self.run.result = {}
        self.run.deadline = 100
        self.run.service = mock.Mock()
        self.run.service.poll.return_value = None
        self.run.save = mock.Mock()
        self.now = 0
        self.clock = mock.patch.object(self.runner.time, 'monotonic', side_effect=lambda: self.now)
        self.sleep = mock.patch.object(self.runner.time, 'sleep', side_effect=self.advance)
        self.clock.start()
        self.sleeper = self.sleep.start()
        self.addCleanup(self.clock.stop)
        self.addCleanup(self.sleep.stop)

    def advance(self, seconds):
        self.now += seconds

    def fail(self, stage):
        self.assertEqual(stage, 'probe')
        self.run.result['runtime_failure'] = {'code': 'linear_app_request_unavailable'}
        raise self.runner.RunFailure('probe_failed')

    def test_success_does_not_reset_the_total_retry_budget(self):
        outcomes = iter([False, True, False, True, False])
        def invoke(stage):
            if not next(outcomes):
                return self.fail(stage)
            return {'fixtures': ['fresh']}
        self.run.invoke = mock.Mock(side_effect=invoke)
        self.assertEqual(self.run.probe(), {'fixtures': ['fresh']})
        self.assertEqual(self.run.probe(), {'fixtures': ['fresh']})
        with self.assertRaisesRegex(self.runner.RunFailure, '^probe_failed$'):
            self.run.probe()
        self.assertEqual(self.run.invoke.call_count, 5)
        self.assertEqual(self.sleeper.call_args_list, [mock.call(2), mock.call(5)])
        self.assertEqual(self.run.save.call_count, 2)

    def test_non_transport_errors_and_incomplete_receipts_are_not_retried(self):
        for failure in ({'code': 'linear_app_identity_unavailable'}, {'code': 'linear_app_identity_denied'},
                        {'code': 'linear_http', 'status': 401}, {'code': 'linear_http', 'status': 500},
                        {'code': 'linear_http', 'status': 502}, {'code': 'linear_http', 'status': '503'},
                        {'code': 'linear_http'}, {'code': 'test_fixture_changed_externally', 'status': 503},
                        {'code': 'linear_http', 'status': 403}, {'code': 'linear_http', 'status': 429},
                        {'code': 'linear_app_rate_limited'}, {'code': 'test_fixture_changed_externally'},
                        {'code': 'yolo_state_corrupt'}, None):
            with self.subTest(failure=failure):
                def invoke(_):
                    if failure:
                        self.run.result['runtime_failure'] = failure
                    raise self.runner.RunFailure('probe_failed')
                self.run.invoke = mock.Mock(side_effect=invoke)
                with self.assertRaisesRegex(self.runner.RunFailure, '^probe_failed$'):
                    self.run.probe()
                self.run.invoke.assert_called_once_with('probe')
                self.sleeper.assert_not_called()
        for error in ('probe_timeout', 'probe_missing_receipt', 'signal_15'):
            self.run.invoke = mock.Mock(side_effect=self.runner.RunFailure(error))
            with self.assertRaisesRegex(self.runner.RunFailure, '^' + error + '$'):
                self.run.probe()
            self.run.invoke.assert_called_once_with('probe')
            self.sleeper.assert_not_called()

    def test_deadline_prevents_sleep_or_another_probe(self):
        self.run.invoke = mock.Mock(side_effect=self.fail)
        self.run.deadline = 2
        with self.assertRaisesRegex(self.runner.RunFailure, '^timeout$'):
            self.run.probe()
        self.run.invoke.assert_called_once_with('probe')
        self.sleeper.assert_not_called()
        self.run.deadline = 3
        self.sleeper.side_effect = lambda _: self.advance(4)
        self.run.invoke.reset_mock()
        with self.assertRaisesRegex(self.runner.RunFailure, '^timeout$'):
            self.run.probe()
        self.run.invoke.assert_called_once_with('probe')

    def test_service_exit_and_cancellation_stop_retries(self):
        self.run.invoke = mock.Mock(side_effect=self.fail)
        self.run.service.poll.side_effect = [None, 1]
        with self.assertRaisesRegex(self.runner.RunFailure, '^service_exited$'):
            self.run.probe()
        self.run.invoke.assert_called_once_with('probe')
        self.run.service.poll.side_effect = None
        self.run.invoke.reset_mock()
        self.sleeper.side_effect = self.runner.RunFailure('signal_15')
        with self.assertRaisesRegex(self.runner.RunFailure, '^signal_15$'):
            self.run.probe()
        self.run.invoke.assert_called_once_with('probe')

    def test_expired_run_does_not_start_another_child(self):
        self.run.deadline = 0
        self.run.start = mock.Mock()
        with self.assertRaisesRegex(self.runner.RunFailure, '^timeout$'):
            self.run.invoke('prepare')
        self.run.start.assert_not_called()

    def test_unavailable_and_503_share_the_run_budget(self):
        failures = iter([{'code': 'linear_app_request_unavailable'},
                         {'code': 'linear_http', 'status': 503},
                         {'code': 'linear_app_request_unavailable'}])
        def invoke(stage):
            self.assertEqual(stage, 'probe')
            self.run.result['runtime_failure'] = next(failures)
            raise self.runner.RunFailure('probe_failed')
        self.run.invoke = mock.Mock(side_effect=invoke)
        with self.assertRaisesRegex(self.runner.RunFailure, '^probe_failed$'):
            self.run.probe()
        self.assertEqual(self.run.invoke.call_count, 3)
        self.assertEqual(self.sleeper.call_args_list, [mock.call(2), mock.call(5)])
        self.assertEqual(self.run.save.call_count, 2)


class ProbeHttp503RetryBudget(ProbeRetryBudget):
    """The same deadline, cancellation and whole-run budget apply to HTTP 503."""
    def fail(self, stage):
        self.assertEqual(stage, 'probe')
        self.run.result['runtime_failure'] = {'code': 'linear_http', 'status': 503}
        raise self.runner.RunFailure('probe_failed')


if __name__=='__main__':unittest.main()
