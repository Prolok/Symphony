import asyncio
import io
import json
import os
import unittest
from contextlib import redirect_stdout
from dataclasses import replace
from unittest import mock

from test_land_app_gate import land

HEAD = 'a' * 40
BASE = 'c' * 40
PR = land.PrInfo(46, 'https://example.invalid/pull/46', HEAD, 'MERGEABLE', 'CLEAN', 'author', 'release/test', BASE)


def run(name='CI', conclusion='success', app=1, sha=HEAD, identity=1):
    return dict(id=identity, name=name, head_sha=sha, app={'id': app}, status='completed', conclusion=conclusion)


class CiApi:
    def __init__(self):
        self.ref = {'name': PR.base_branch, 'target': {'oid': BASE}, 'branchProtectionRule': None}
        self.graph = {'data': {'repository': {'ref': self.ref}}}
        self.rules = []
        self.runs = {HEAD: [], BASE: []}
        self.statuses = {HEAD: [], BASE: []}
        self.suites = {HEAD: [], BASE: []}
        self.suite_runs = {}
        self.status_history = None
        self.workflows = []
        self.app = {'id': 7, 'slug': 'external-ci'}
        self.bot = {'id': 70, 'login': 'external-ci[bot]', 'type': 'Bot'}
        self.trees = {sha: {'sha': 'e' * 40, 'truncated': False, 'tree': []} for sha in (HEAD, BASE)}
        self.overrides = {}
        self.calls = []

    async def __call__(self, *args):
        self.calls.append(args)
        if args[1] == 'graphql':
            return json.dumps(self.graph)
        if args[-1] == 'apps/external-ci':
            return json.dumps(self.app)
        if args[-1] == 'users/external-ci%5Bbot%5D':
            return json.dumps(self.bot)
        endpoint = next(arg for arg in args if arg.startswith('repos/'))
        if endpoint in self.overrides:
            result = self.overrides[endpoint]
            if isinstance(result, Exception):
                raise result
            return json.dumps(result)
        sha = BASE if BASE in endpoint else HEAD
        if '/rules/branches/' in endpoint:
            assert endpoint.endswith('release%2Ftest'), endpoint
            payload = self.rules
        elif '/check-suites/' in endpoint and endpoint.endswith('/check-runs'):
            runs = self.suite_runs.get(int(endpoint.split('/')[-2]), [])
            payload = dict(total_count=len(runs), check_runs=runs)
        elif '/check-runs' in endpoint:
            payload = dict(total_count=len(self.runs[sha]), check_runs=self.runs[sha])
        elif '/check-suites' in endpoint:
            payload = dict(total_count=len(self.suites[sha]), check_suites=self.suites[sha])
        elif endpoint.endswith('/status'):
            # The combined endpoint returns simple-commit-status, without creator.
            statuses = [{key: value for key, value in status.items() if key != 'creator'}
                        for status in self.statuses[sha]]
            payload = dict(sha=sha, total_count=len(statuses), statuses=statuses)
        elif endpoint.endswith('/statuses'):
            payload = self.status_history if self.status_history is not None else self.statuses[sha]
        elif '/actions/workflows' in endpoint:
            payload = dict(total_count=len(self.workflows), workflows=self.workflows)
        elif '/git/trees/' in endpoint:
            return json.dumps(self.trees[sha])
        else:
            raise AssertionError(args)
        return json.dumps([payload])


class CiEvidenceTest(unittest.IsolatedAsyncioTestCase):
    async def summary(self, api):
        with mock.patch.object(land, 'run_gh', api):
            return await land.collect_ci_summary(PR)

    async def test_no_ci_is_explicit_and_finishes_without_waiting(self):
        api = CiApi()
        api.rules = [dict(ruleset_id=1, type=kind) for kind in ('pull_request', 'deletion', 'non_fast_forward')]
        event = asyncio.Event()
        output = io.StringIO()
        with mock.patch.object(land, 'run_gh', api), redirect_stdout(output), \
             mock.patch.object(land.asyncio, 'sleep', mock.AsyncMock(side_effect=AssertionError('unexpected wait'))):
            await land.wait_for_checks(PR, event)
        self.assertTrue(event.is_set())
        self.assertIn('not configured and not required', output.getvalue())
        self.assertNotIn('checks passed', output.getvalue())
        self.assertNotIn('check CI configuration', output.getvalue())

    async def test_expected_ci_signals_never_become_no_ci(self):
        for signal in ('active', 'disabled_manually', 'head_files', 'base_files', 'suite', 'base_run', 'base_status', 'base_suite'):
            with self.subTest(signal=signal):
                api = CiApi()
                if signal in ('active', 'disabled_manually'):
                    api.workflows = [dict(id=1, state=signal)]
                elif signal.endswith('_files'):
                    sha = HEAD if signal == 'head_files' else BASE
                    api.trees[sha]['tree'] = [dict(path='.github/workflows/ci.yaml', type='blob', sha='f' * 40)]
                elif signal in ('suite', 'base_suite'):
                    sha = HEAD if signal == 'suite' else BASE
                    api.suites[sha] = [dict(id=1, head_sha=sha, status='queued', latest_check_runs_count=1, app={'id': 7, 'slug': 'external-ci'})]
                elif signal == 'base_run':
                    api.runs[BASE] = [run(sha=BASE)]
                else:
                    api.statuses[BASE] = [dict(id=1, context='external', state='success')]
                summary = await self.summary(api)
                self.assertTrue(summary.pending)
                self.assertFalse(summary.no_ci)
                self.assertIn('CI expected', summary.failures[0])

    async def test_required_checks_remain_missing_beside_other_green_checks(self):
        for classic in (False, True):
            for app in (None, 7):
                with self.subTest(classic=classic, app=app):
                    api = CiApi()
                    api.runs[HEAD] = [run('lint')]
                    if classic:
                        api.ref['branchProtectionRule'] = dict(requiresStatusChecks=True, requiredStatusChecks=[dict(context='required', app={'databaseId': app} if app else None)], requiresDeployments=False, requiredDeploymentEnvironments=[])
                    else:
                        api.rules = [dict(ruleset_id=7, ruleset_source_type='Organization', type='required_status_checks', parameters={'required_status_checks': [dict(context='required', integration_id=app)]})]
                    self.assertTrue((await self.summary(api)).pending)
                    api.runs[HEAD].append(run('required', app=8, identity=2))
                    self.assertEqual((await self.summary(api)).pending, app is not None)
                    api.runs[HEAD][-1]['app']['id'] = app or 1
                    self.assertFalse((await self.summary(api)).pending)

    async def test_status_only_ci_and_app_collisions_are_evaluated(self):
        for state, failed, pending in [('success', False, False), ('pending', False, True), ('failure', True, False), ('error', True, False)]:
            api = CiApi()
            api.statuses[HEAD] = [dict(id=1, context='CI', state=state)]
            summary = await self.summary(api)
            self.assertEqual((summary.failed, summary.pending, summary.no_ci), (failed, pending, False))
        api.runs[HEAD] = [run('CI')]
        self.assertTrue((await self.summary(api)).failed)
        api.statuses[HEAD] = []
        api.runs[HEAD] = [run(app=1), run(app=2, conclusion='failure', identity=2)]
        self.assertTrue((await self.summary(api)).failed)
        for conclusion in ('skipped', 'neutral', 'success'):
            api.runs[HEAD] = [run(conclusion=conclusion)]
            summary = await self.summary(api)
            self.assertFalse(summary.failed or summary.pending or summary.no_ci)
            self.assertEqual(summary.accepted_counts[conclusion], 1)

    async def test_pending_or_failed_suites_block_even_beside_green_checks(self):
        for checks in ([], [run()]):
            for status, conclusion, failed in [('queued', None, False), ('completed', 'failure', True), ('completed', None, True)]:
                api = CiApi()
                api.runs[HEAD] = checks
                api.suites[HEAD] = [dict(id=1, head_sha=HEAD, status=status, conclusion=conclusion, latest_check_runs_count=1, app={'id': 7, 'slug': 'external-ci'})]
                api.suite_runs[1] = [dict(run(app=7, conclusion=conclusion), check_suite={'id': 1}, status=status)]
                summary = await self.summary(api)
                self.assertFalse(summary.no_ci)
                self.assertEqual(summary.failed, failed)
                self.assertTrue(summary.failed or summary.pending)

    async def test_classic_protection_without_status_requirements_allows_no_ci(self):
        for checks in ([], None):
            api = CiApi()
            api.ref['branchProtectionRule'] = dict(requiresStatusChecks=False, requiredStatusChecks=checks, requiresDeployments=False, requiredDeploymentEnvironments=[])
            self.assertTrue((await self.summary(api)).no_ci)

    def rerun_api(self):
        api = CiApi()
        old = dict(run(conclusion='failure', app=7, identity=10), check_suite={'id': 1},
                   started_at='2026-09-12T19:00:00Z', completed_at='2026-09-12T19:01:00Z')
        new = dict(run(app=7, identity=20), check_suite={'id': 2},
                   started_at='2026-09-12T19:02:00Z', completed_at='2026-09-12T19:03:00Z')
        api.runs[HEAD] = [new]
        api.suite_runs[1] = [old]
        api.suites[HEAD] = [dict(id=1, head_sha=HEAD, status='completed', conclusion='failure',
                                latest_check_runs_count=1, app={'id': 7, 'slug': 'github-actions'}),
                            dict(id=2, head_sha=HEAD, status='completed', conclusion='success',
                                 latest_check_runs_count=1, app={'id': 7, 'slug': 'github-actions'})]
        return api

    async def test_replaced_failed_suite_does_not_block_successful_rerun(self):
        api = self.rerun_api()
        summary = await self.summary(api)
        self.assertFalse(summary.failed or summary.pending or summary.no_ci, summary.failures)
        self.assertEqual(summary.accepted_counts['success'], 1)
        # The commit endpoint may also return the older job; summary and suites
        # must agree about its replacement without counting its result twice.
        api.runs[HEAD].extend(api.suite_runs[1])
        summary = await self.summary(api)
        self.assertFalse(summary.failed or summary.pending)
        self.assertEqual(summary.accepted_counts['success'], 1)
        event = asyncio.Event()
        with mock.patch.object(land, 'run_gh', api), redirect_stdout(io.StringIO()), \
             mock.patch.object(land.asyncio, 'sleep', mock.AsyncMock(side_effect=AssertionError('replaced suite waited'))):
            await land.wait_for_checks(PR, event)
        self.assertTrue(event.is_set())

    async def test_unreplaced_or_uncertain_suites_still_block(self):
        for change in ('other_name', 'other_app', 'older_result', 'missing_time', 'missing_suite',
                       'pending_suite', 'pending_run', 'failed_run', 'pending_old_suite',
                       'unknown_conclusion', 'unreplaced_job', 'no_jobs'):
            with self.subTest(change=change):
                api = self.rerun_api()
                current = api.runs[HEAD][0]
                if change == 'other_name': current['name'] = 'unrelated'
                elif change == 'other_app': current['app']['id'] = 8
                elif change == 'older_result': current['completed_at'] = '2026-09-12T18:00:00Z'
                elif change == 'missing_time':
                    del current['completed_at']
                    del current['started_at']
                elif change == 'missing_suite': del current['check_suite']
                elif change == 'pending_suite': api.suites[HEAD][1]['status'] = 'in_progress'
                elif change == 'pending_run': current['status'] = 'in_progress'
                elif change == 'failed_run': current['conclusion'] = 'failure'
                elif change == 'pending_old_suite': api.suites[HEAD][0]['status'] = 'in_progress'
                elif change == 'unknown_conclusion': api.suites[HEAD][0]['conclusion'] = None
                elif change == 'unreplaced_job':
                    api.suite_runs[1].append(dict(api.suite_runs[1][0], id=11, name='other-job'))
                    api.suites[HEAD][0]['latest_check_runs_count'] = 2
                else:
                    api.suite_runs[1] = []
                    api.suites[HEAD][0]['latest_check_runs_count'] = 0
                summary = await self.summary(api)
                self.assertTrue(summary.failed or summary.pending)
                self.assertFalse(summary.no_ci)
        for change in ('wrong_head', 'wrong_app', 'wrong_suite', 'count_changed', 'partial_page', 'api_error'):
            with self.subTest(change=change):
                api = self.rerun_api()
                old = api.suite_runs[1][0]
                if change == 'wrong_head': old['head_sha'] = BASE
                elif change == 'wrong_app': old['app']['id'] = 8
                elif change == 'wrong_suite': old['check_suite']['id'] = 3
                elif change == 'count_changed': api.suites[HEAD][0]['latest_check_runs_count'] = 2
                else:
                    api.overrides['repos/{owner}/{repo}/check-suites/1/check-runs'] = (
                        RuntimeError('HTTP 403') if change == 'api_error' else [dict(total_count=1, check_runs=[])])
                with self.assertRaises(land.CiEvidenceError):
                    await self.summary(api)

    async def test_empty_automatic_suites_do_not_hold_green_jobs_open(self):
        api = CiApi()
        api.runs[HEAD] = [run()]
        api.suites[HEAD] = [dict(id=1, head_sha=HEAD, status='queued', conclusion=None,
                                latest_check_runs_count=0, app={'id': 7, 'slug': 'external-ci'})]
        event = asyncio.Event()
        with mock.patch.object(land, 'run_gh', api), redirect_stdout(io.StringIO()), \
             mock.patch.object(land.asyncio, 'sleep', mock.AsyncMock(side_effect=AssertionError('unused suite waited'))):
            await land.wait_for_checks(PR, event)
        self.assertTrue(event.is_set())
        self.assertFalse((await self.summary(api)).no_ci)
        api.runs[HEAD] = []
        self.assertTrue((await self.summary(api)).pending)
        self.assertFalse((await self.summary(api)).no_ci)
        api.runs[HEAD] = [run()]
        api.rules = [dict(ruleset_id=1, type='required_status_checks',
                         parameters={'required_status_checks': [dict(context='missing')]} )]
        self.assertTrue((await self.summary(api)).pending)
        api.rules = []
        api.suites[HEAD][0]['app'] = {'id': 15368, 'slug': 'github-actions'}
        self.assertTrue((await self.summary(api)).pending)
        self.assertTrue((await self.summary(api)).failures)
        for field in ('app', 'latest_check_runs_count'):
            broken = CiApi()
            broken.runs[HEAD] = [run()]
            broken.suites[HEAD] = [dict(api.suites[HEAD][0])]
            del broken.suites[HEAD][0][field]
            with self.assertRaises(land.CiEvidenceError):
                await self.summary(broken)

    async def test_app_bound_commit_status_uses_verified_bot_identity(self):
        for classic in (False, True):
            api = CiApi()
            if classic:
                api.ref['branchProtectionRule'] = dict(requiresStatusChecks=True,
                    requiredStatusChecks=[dict(context='external-ci', app={'databaseId': 7})],
                    requiresDeployments=False, requiredDeploymentEnvironments=[])
            else:
                api.rules = [dict(ruleset_id=7, type='required_status_checks',
                                 parameters={'required_status_checks': [dict(context='external-ci', integration_id=7)]})]
            api.statuses[HEAD] = [dict(id=1, context='external-ci', state='success', creator=dict(api.bot))]
            self.assertFalse((await self.summary(api)).pending)
            api.app['id'] = 8
            self.assertTrue((await self.summary(api)).pending)
            api.app['id'] = 7
            api.bot['id'] = 71
            with self.assertRaises(land.CiEvidenceError):
                await self.summary(api)
            api.bot['id'] = 70
            api.statuses[HEAD][0]['creator'] = {'id': 70, 'login': 'external-ci[bot]', 'type': 'User'}
            self.assertTrue((await self.summary(api)).pending)
            api.statuses[HEAD][0]['creator'] = dict(api.bot)
            api.app = {'id': 7}
            with self.assertRaises(land.CiEvidenceError):
                await self.summary(api)
        with mock.patch.object(land, 'run_gh', mock.AsyncMock(side_effect=RuntimeError('HTTP 403'))):
            with self.assertRaisesRegex(land.CiEvidenceError, 'lookup failed'):
                await land.attribute_status_apps(api.statuses[HEAD], [('external-ci', 7)], HEAD)

    async def test_classic_deployment_requirements_cannot_be_no_ci(self):
        for fields in ({}, {'requiresDeployments': True, 'requiredDeploymentEnvironments': ['staging']},
                       {'requiresDeployments': False, 'requiredDeploymentEnvironments': ['staging']},
                       {'requiresDeployments': False}, {'requiresDeployments': None, 'requiredDeploymentEnvironments': []}):
            api = CiApi()
            api.ref['branchProtectionRule'] = dict(requiresStatusChecks=False, requiredStatusChecks=[], **fields)
            with self.assertRaises(land.CiEvidenceError):
                await self.summary(api)

    async def test_status_history_is_paginated_and_bound_to_the_current_status(self):
        api = CiApi()
        api.rules = [dict(ruleset_id=7, type='required_status_checks',
                         parameters={'required_status_checks': [dict(context='external-ci', integration_id=7)]})]
        status = dict(id=101, context='external-ci', state='success', creator=dict(api.bot))
        api.statuses[HEAD] = [status]
        # Full history includes obsolete failures; only the current status may
        # supply the author. Exercise a matched status on the second API page.
        history = [dict(id=300 - i, context='other', state='failure') for i in range(100)] + [status,
                   dict(id=100, context='external-ci', state='failure', creator={'id': 99, 'type': 'User', 'login': 'human'})]
        endpoint = f'repos/{{owner}}/{{repo}}/commits/{HEAD}/statuses'
        api.overrides[endpoint] = [history[:100], history[100:]]
        self.assertFalse((await self.summary(api)).pending)
        call = next(call for call in api.calls if endpoint in call)
        self.assertIn('--paginate', call)
        self.assertIn('--slurp', call)
        for pages in ([[dict(status, id=102), status]], [[dict(status, context='other')]],
                      [[dict(status, state='failure')]], [[dict(status, creator=None)]],
                      [[status, status]], [[status], [history[-1]]], [], [{}], [[]],
                      RuntimeError('HTTP 403'), RuntimeError('HTTP 429 rate limit')):
            with self.subTest(pages=pages):
                api.overrides[endpoint] = pages
                with self.assertRaises(land.CiEvidenceError):
                    await self.summary(api)

    async def test_expected_ci_can_arrive_and_missing_ci_times_out_truthfully(self):
        api = CiApi()
        api.workflows = [dict(id=1)]
        async def arrives(_):
            api.runs[HEAD] = [run()]
        with mock.patch.object(land, 'run_gh', api), mock.patch.object(land.asyncio, 'sleep', arrives):
            event = asyncio.Event()
            await land.wait_for_checks(PR, event)
            self.assertTrue(event.is_set())
        api.runs[HEAD] = []
        with mock.patch.object(land, 'run_gh', api), mock.patch.object(land.asyncio, 'sleep', mock.AsyncMock()), redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as error:
                await land.wait_for_checks(PR, asyncio.Event())
            self.assertEqual(error.exception.code, 3)
        self.assertIn('Expected GitHub CI checks still missing', output.getvalue())

    async def test_unreadable_policy_or_inventory_is_not_absence(self):
        for change in ('errors', 'null_repo', 'missing_classic', 'missing_ref', 'moved_base', 'unknown_rule', 'workflows_rule', 'bad_classic', 'truncated_tree', 'bad_tree', 'wrong_check_sha', 'missing_app', 'bad_status', 'wrong_suite_sha'):
            with self.subTest(change=change):
                api = CiApi()
                if change == 'errors': api.graph['errors'] = [{'message': 'forbidden'}]
                elif change == 'null_repo': api.graph['data']['repository'] = None
                elif change == 'missing_classic': del api.ref['branchProtectionRule']
                elif change == 'missing_ref': del api.graph['data']['repository']['ref']
                elif change == 'moved_base': api.ref['target']['oid'] = 'd' * 40
                elif change in ('unknown_rule', 'workflows_rule'): api.rules = [dict(ruleset_id=1, type='workflows' if change == 'workflows_rule' else 'future_rule')]
                elif change == 'bad_classic': api.ref['branchProtectionRule'] = {'requiresStatusChecks': False}
                elif change == 'truncated_tree': api.trees[BASE]['truncated'] = True
                elif change == 'bad_tree': api.trees[BASE]['tree'] = [{}]
                elif change == 'wrong_check_sha': api.runs[HEAD] = [run(sha=BASE)]
                elif change == 'missing_app': api.runs[HEAD] = [dict(run(), app=None)]
                elif change == 'bad_status': api.statuses[HEAD] = [dict(id=1, context='CI', state='unknown')]
                elif change == 'wrong_suite_sha': api.suites[HEAD] = [dict(id=1, head_sha=BASE)]
                with self.assertRaises(land.CiEvidenceError):
                    await self.summary(api)
        for error in ('HTTP 401', 'HTTP 403', 'HTTP 404', 'HTTP 429 rate limit'):
            api = CiApi()
            api.overrides['repos/{owner}/{repo}/actions/workflows'] = RuntimeError(error)
            with self.assertRaisesRegex(land.CiEvidenceError, 'lookup failed'):
                await self.summary(api)

    async def test_all_counted_endpoints_reject_incomplete_and_duplicate_pages(self):
        for endpoint, key in [('actions/workflows', 'workflows'), (f'commits/{HEAD}/check-runs', 'check_runs'), (f'commits/{HEAD}/check-suites', 'check_suites'), (f'commits/{HEAD}/status', 'statuses')]:
            malformed = [[], [{}], [{'total_count': 0}], [{'total_count': True, key: []}], [{'total_count': 1, key: []}], [{'total_count': 0, key: [{}]}], [{'total_count': 2, key: [{'id': 1}, {'id': 1}]}], [{'total_count': 1, key: [{'id': 1}]}] * 2]
            for pages in malformed:
                with self.subTest(endpoint=endpoint, pages=pages), mock.patch.object(land, 'run_gh', mock.AsyncMock(return_value=json.dumps(pages))):
                    with self.assertRaises(land.CiEvidenceError):
                        await land.ci_pages(endpoint, key)
        items = [dict(id=i + 1) for i in range(101)]
        pages = [dict(total_count=101, workflows=items[:100]), dict(total_count=101, workflows=items[100:])]
        with mock.patch.object(land, 'run_gh', mock.AsyncMock(return_value=json.dumps(pages))):
            self.assertEqual(await land.ci_pages('actions/workflows', 'workflows'), items)
        for last in ({'total_count': 102, 'workflows': items[100:]}, {'total_count': 101, 'workflows': []}, {'message': 'API error'}):
            with mock.patch.object(land, 'run_gh', mock.AsyncMock(return_value=json.dumps([pages[0], last]))):
                with self.assertRaises(land.CiEvidenceError):
                    await land.ci_pages('actions/workflows', 'workflows')


class BoundNoCiTest(unittest.IsolatedAsyncioTestCase):
    async def test_bound_merge_rechecks_ci_and_all_remaining_gates(self):
        for failure in (None, 'valid_approval', 'ci_changed', 'head_changed', 'base_changed', 'policy_changed', 'dirty', 'remote', 'missing_remote', 'missing_pr', 'closed', 'conflict', 'unknown_merge', 'feedback', 'manual', 'stale_approval', 'self_approval', 'bot_approval', 'labels', 'comment', 'labels_changed'):
            with self.subTest(failure=failure):
                api = CiApi()
                current = PR
                if failure == 'head_changed': current = replace(PR, head_sha=BASE)
                if failure == 'closed': current = replace(PR, state='CLOSED')
                if failure == 'conflict': current = replace(PR, mergeable='CONFLICTING', merge_state='DIRTY')
                if failure == 'unknown_merge': current = replace(PR, mergeable='UNKNOWN')
                evidence = land.MergePreflightEvidence('symphony/PRO-1', current.head_sha, True, current)
                if failure == 'missing_remote': evidence.remote_branch_exists = False
                if failure == 'missing_pr': evidence.pr = None
                requests = []
                async def git(*args):
                    if args[0] == 'status': return ' M changed' if failure == 'dirty' else ''
                    return (BASE if failure == 'remote' else HEAD) + '\trefs/heads/symphony/PRO-1'
                async def gh(*args):
                    if args[:2] == ('pr', 'merge'):
                        requests.append(args)
                        return ''
                    if args[:2] == ('pr', 'view'):
                        return json.dumps({'state': 'MERGED', 'mergeCommit': {'oid': BASE}})
                    return await api(*args)
                async def watch():
                    self.assertTrue((await land.collect_ci_summary(PR)).no_ci)
                    if failure == 'ci_changed': api.workflows = [dict(id=1)]
                    if failure == 'policy_changed': api.rules = [dict(ruleset_id=1, type='workflows')]
                    if failure == 'base_changed': api.ref['target']['oid'] = 'd' * 40
                labels = ['Requires Manual Review'] if failure in ('manual', 'stale_approval', 'self_approval', 'bot_approval', 'valid_approval') else []
                def checkpoint(operation):
                    if failure == 'labels' and operation == 'labels': return {'ok': False}
                    return dict(ok=failure != 'comment' or operation != 'merge', labels=['changed'] if failure == 'labels_changed' and operation == 'merge' else labels)
                comments = [dict(body='Please fix', user={'login': 'human'})] if failure == 'feedback' else []
                reviews = []
                if failure in ('stale_approval', 'self_approval', 'bot_approval', 'valid_approval'):
                    reviews = [dict(state='APPROVED', commit_id=BASE if failure == 'stale_approval' else HEAD,
                                    user={'login': 'author' if failure == 'self_approval' else 'ci[bot]' if failure == 'bot_approval' else 'human'})]
                output = io.StringIO()
                with mock.patch.dict(os.environ, {'SYMPHONY_ISSUE_IDENTIFIER': 'PRO-1'}), redirect_stdout(output), \
                     mock.patch.object(land, 'run_gh', gh), mock.patch.object(land, 'run_git', git), \
                     mock.patch.object(land, 'watch_pr', watch), mock.patch.object(land, 'bound_request', None), \
                     mock.patch.object(land, 'request_bound_checkpoint', checkpoint), \
                     mock.patch.object(land, 'collect_merge_preflight_evidence', mock.AsyncMock(return_value=evidence)), \
                     mock.patch.object(land, 'fetch_review_context', mock.AsyncMock(return_value=(comments, [], reviews, None))):
                    if failure not in (None, 'valid_approval'):
                        with self.assertRaises((RuntimeError, SystemExit)):
                            await land.merge_bound(HEAD, 'test')
                        self.assertEqual(requests, [])
                        self.assertNotIn('SYMPHONY_MERGE_RESULT', output.getvalue())
                    else:
                        await land.merge_bound(HEAD, 'test')
                        self.assertEqual(len(requests), 1)
                        self.assertIn('SYMPHONY_MERGE_RESULT', output.getvalue())
