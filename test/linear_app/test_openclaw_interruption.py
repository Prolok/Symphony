"""Synthetic counterproofs for the explicit live runner; no gateway access."""
import copy
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / 'scripts' / name))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def evidence():
    def order(run, members, state):
        value = dict(id=run, group='incoming', agent='po', project_id='project',
                     session_id='session-' + run, workspace='/synthetic/' + run,
                     payload_sha256='hash-' + run, sha='sha', state=state,
                     members=[dict(id=i) for i in members], interruption_contract=1,
                     acceptance_observed=True, writable=state != 'completed')
        value['checkout_proof'] = {k: value[k] for k in ('id', 'project_id', 'session_id', 'workspace', 'payload_sha256', 'sha')}
        value['checkout_proof'].update(clean=True, cwd=value['workspace'], git_root=value['workspace'])
        if state == 'completed':
            value['terminal'] = dict(runId=run, status='ok', endedAt=3)
        return value
    before = order('old', ['a', 'b', 'c'], 'accepted')
    attempt = dict(id='old', members=['a', 'b', 'c'], completed={'a': 'Verworfen'})
    original = dict(before, state='retired', writable=False, abort_acknowledged=True,
                    retirement=dict(kind='fenced_interruption', retired_at='now', history_sha256='hash',
                                    physical_session_id='physical', retained_inputs=[], attempt=attempt))
    current = order('new', ['b', 'c'], 'completed')
    proof = dict(before=before, original=original, current=current, first_id='a', run_id='proof', source={'sha': 'source'},
                 active=dict(key=before['session_id'], sessionId='physical', lastRunId='old', hasActiveRun=True, activeRunIds=['old']),
                 active_checked_at='now', attempt=attempt, generation_ids=['old', 'new'],
                 current_attempt=dict(id='new', members=['b', 'c'], completed={'b': 'Verworfen', 'c': 'Verworfen'}))
    fixtures = []
    for member, state in zip(['a', 'b', 'c'], ['Backlog', 'Todo', 'Definiert']):
        target = original if member == 'a' else current
        receipt = {k: target[k] for k in ('session_id', 'workspace', 'sha')}
        if member != 'a':
            receipt['openclaw'] = target
        fixtures.append(dict(id=member, po_incoming=True, initial_state=state,
                             observed_state='Verworfen', complete=True, po_receipt=receipt))
    return proof, fixtures


class InterruptionProofTest(unittest.TestCase):
    def test_runner_requires_a_live_first_decision_and_two_distinct_generations(self):
        runner = load('test-instance-run')
        self.assertIn('--openclaw-interruption', runner.parser().format_help())
        run = object.__new__(runner.Run)
        run.args = type('Args', (), dict(openclaw_agent='po', openclaw_interruption=True, run_id='proof'))()
        proof, fixtures = evidence()
        run.result = dict(interruption=proof, source=proof['source'])
        run.verify_openclaw(fixtures)
        self.assertEqual(run.result['openclaw']['interruption']['original']['state'], 'retired')
        self.assertEqual({x['id'] for x in run.result['openclaw']['executions']}, {'new'})
        # A normal completed original is not a successful interruption proof.
        proof['original']['state'] = 'completed'
        with self.assertRaises(runner.RunFailure):
            run.verify_openclaw(fixtures)

    def test_interruption_requires_explicit_live_agent_and_rejects_changed_resume_mode(self):
        runner = load('test-instance-run')
        args = ['runner', '--checkout', '/synthetic/source', '--test-instance', 'proof',
                '--manifest', '/synthetic/manifest.json', '--run-id', 'proof', '--expected-sha', 'sha',
                '--expected-source', 'hash', '--port', '4099', '--result-dir', '/synthetic/result',
                '--scenario', 'po_incoming', '--openclaw-interruption']
        with mock.patch.object(runner.sys, 'argv', args):
            with self.assertRaisesRegex(SystemExit, 'Unterbrechungsnachweis verlangt OpenClaw'):
                runner.main()
        # These checks run before acquiring any lock, discovering credentials or starting processes.
        args += ['--openclaw-agent', 'po', '--resume']
        plan = dict(run_id='proof', instance='proof', source=dict(sha='sha', source_sha256='hash', checkout='/synthetic/source'),
                    scenario='po_incoming', yolo=False, openclaw_agent='po', openclaw_interruption=False)
        import json
        import os
        with mock.patch.object(runner.sys, 'argv', args), \
                mock.patch.dict(os.environ, SYMPHONY_OPENCLAW_TEST_DENY='0', SYMPHONY_SERVICE_OWNER_PID=str(os.getpid())), \
                mock.patch.object(Path, 'read_text', return_value=json.dumps(plan)):
            with self.assertRaisesRegex(SystemExit, 'Wiederaufnahme gehört nicht'):
                runner.main()

    def test_missing_active_evidence_repeated_decisions_and_foreign_bindings_fail_closed(self):
        verifier = load('openclaw-interruption.py')
        changes = [
            (('generation_ids',), ['old', 'unobserved', 'new']), (('source',), {'sha': 'foreign'}), (('run_id',), 'other'),
            (('before', 'acceptance_observed'), False), (('before', 'interruption_contract'), None),
            (('active', 'hasActiveRun'), False), (('active', 'activeRunIds'), ['old', 'new']),
            (('active', 'key'), 'foreign'), (('active_checked_at',), None),
            (('original', 'terminal'), {'runId': 'foreign'}), (('original', 'writable'), True), (('original', 'abort_acknowledged'), False),
            (('original', 'retirement', 'physical_session_id'), 'foreign'),
            (('current', 'members'), [dict(id=i) for i in ['a', 'b', 'c']]),
            (('current', 'session_id'), 'session-old'), (('current', 'id'), 'old'),
            (('current', 'state'), 'accepted'), (('current_attempt', 'completed'), {'a': 'duplicate', 'b': 'yes', 'c': 'yes'}),
            (('current_attempt', 'id'), 'foreign'),
            (('attempt', 'completed'), {}), (('original', 'checkout_proof', 'clean'), False),
        ]
        for keys, value in changes:
            with self.subTest(keys=keys):
                proof, fixtures = copy.deepcopy(evidence())
                target = proof
                for key in keys[:-1]:
                    target = target[key]
                target[keys[-1]] = value
                with self.assertRaises((ValueError, KeyError, TypeError)):
                    verifier.verify(proof, fixtures, {'sha': 'source'}, 'proof', 'po')
        for change in [dict(complete=False), dict(observed_state='Todo'), dict(po_receipt={}), dict(initial_state='Todo')]:
            proof, fixtures = evidence()
            fixtures[0].update(change)
            with self.assertRaises((ValueError, KeyError)):
                verifier.verify(proof, fixtures, proof['source'], 'proof', 'po')


if __name__ == '__main__':
    unittest.main()
