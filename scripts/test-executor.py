#!/usr/bin/env python3
"""Operator-provisioned Unix socket for the existing isolated test runner.

The operator binds one issue/worktree and owns manifest, credentials and results.
Workers can only submit fixed operations and source identities. A durable intent
and inherited run lock make a lost socket response safe to query/repeat.
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socketserver
import stat
import subprocess
import sys
import time

ERROR_CODES = {'intentional_failure_probe', 'preflight_or_runtime_failed', 'timeout', 'service_exited',
               'restart_exited', 'consumer_changed_on_restart', 'concurrent_start_not_rejected', 'merged_source_mismatch',
               'run_already_exists_or_changed', 'foreign_ticket_launcher', 'fetch_failed', 'fetch_timeout'}
ERROR_CODES.update(stage + suffix for stage in ('prepare', 'probe', 'cleanup') for suffix in ('_failed', '_timeout', '_missing_receipt'))
ERROR_CODES.update('signal_' + str(number) for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))

FIELDS = {'operation', 'issue_id', 'identifier', 'checkout', 'run_id', 'head_sha', 'source_sha256', 'scenario'}
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,47}\Z')


def helper():
    spec = importlib.util.spec_from_file_location('executor_test_instance', Path(__file__).with_name('test-instance.py'))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def atomic(path, value):
    temporary = path.with_suffix('.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as stream:
        if os.fstat(stream.fileno()).st_size > 1_048_576:
            raise ValueError('record_too_large')
        return json.load(stream)


def locked(path):
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return descriptor
    except BlockingIOError:
        os.close(descriptor)
        return None


def busy(directory):
    descriptor = locked(directory / 'executor.lock')
    if descriptor is None:
        return True
    os.close(descriptor)
    return False


class Executor:
    def __init__(self, config, launch=None):
        self.test = helper()
        self.config = dict(config)
        for field in ('checkout', 'manifest', 'result_root'):
            self.config[field] = str(self.test.canonical(config[field]))
        if (not re.fullmatch(r'[0-9a-f-]{36}', config['issue_id'])
                or not re.fullmatch(r'[A-Z][A-Z0-9]*-[0-9]+', config['identifier'])
                or Path(self.config['checkout']).name != config['identifier']
                or not NAME.fullmatch(config['instance'])
                or type(config['port']) is not int or not 0 < config['port'] <= 65535
                or type(config['timeout']) is not int or not 0 < config['timeout'] <= 3600):
            raise ValueError('invalid_operator_binding')
        self.root = Path(self.config['result_root'])
        checkout = Path(self.config['checkout'])
        if self.root.is_relative_to(checkout) or checkout.is_relative_to(self.root):
            raise ValueError('results_must_be_outside_source')
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.launch = launch or self.spawn
        self.children = []

    def spawn(self, directory, descriptor, cleanup):
        # No shell, source-controlled executable or worker environment is used
        # to supervise the run. The existing runner alone starts source builds.
        command = [sys.executable, str(Path(__file__).resolve()), '--supervise', str(directory),
                   '--lock-fd', str(descriptor)]
        if cleanup:
            command.append('--cleanup')
        child = subprocess.Popen(command, pass_fds=(descriptor,), start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children = [entry for entry in self.children if entry.poll() is None] + [child]

    def validate(self, request):
        if not isinstance(request, dict) or set(request) != FIELDS:
            raise ValueError('invalid_request')
        if any(not isinstance(value, str) for value in request.values()):
            raise ValueError('invalid_request')
        if (request['operation'] not in ('start', 'result', 'cancel', 'cleanup')
                or request['scenario'] not in ('bootstrap', 'failure-probe')
                or not NAME.fullmatch(request['run_id'])
                or not re.fullmatch(r'[0-9a-f]{40}', request['head_sha'])
                or not re.fullmatch(r'[0-9a-f]{64}', request['source_sha256'])):
            raise ValueError('invalid_request')
        if any(request[key] != self.config[key] for key in ('issue_id', 'identifier', 'checkout')):
            raise ValueError('test_owner_mismatch')

    def handle(self, request):
        try:
            self.validate(request)
            # Serializes all request mutations, including independent servers.
            descriptor = locked(self.root / 'requests.lock')
            if descriptor is None:
                return {'error': 'executor_busy_retry_same_run'}
            try:
                return self.handle_locked(request)
            finally:
                os.close(descriptor)
        except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
            # Never expose exception strings containing operator paths/provider data.
            return {'error': 'test_request_rejected_check_binding_or_journal'}

    def handle_locked(self, request):
        directory = self.test.canonical(self.root / request['run_id'])
        identity = {key: value for key, value in request.items() if key != 'operation'}
        path = directory / 'request.json'
        if path.exists():
            record = read(path)
            if record['request'] != identity or record['config'] != self.config:
                raise ValueError('test_run_identity_mismatch')
        elif request['operation'] == 'start':
            for previous in self.root.iterdir():
                if previous.is_dir():
                    previous = self.test.canonical(previous)
                    if not (previous / 'request.json').exists():
                        raise ValueError('unknown_run_directory')
                    if busy(previous) or not self.receipt(previous).get('cleanup'):
                        return {'error': 'test_environment_needs_cleanup'}
            source = self.test.source(self.config['checkout'])
            if source['sha'] != request['head_sha'] or source['source_sha256'] != request['source_sha256']:
                return {'error': 'test_source_changed'}
            directory.mkdir(mode=0o700)
            # Persist intent before launching. Existing intents are never blindly relaunched.
            atomic(path, {'request': identity, 'config': self.config})
            self.start(directory, False)
        else:
            return {'error': 'test_run_not_found'}
        if request['operation'] == 'cancel' and busy(directory):
            atomic(directory / 'cancel.json', {'cancel': True})
        if request['operation'] == 'cleanup' and not busy(directory) and not self.receipt(directory).get('cleanup'):
            self.start(directory, True)
        return self.receipt(directory)

    def start(self, directory, cleanup):
        descriptor = locked(directory / 'executor.lock')
        if descriptor is None:
            return
        try:
            self.launch(directory, descriptor, cleanup)
        finally:
            os.close(descriptor)

    def receipt(self, directory):
        record = read(directory / 'request.json')
        request = record['request']
        running = busy(directory)
        result = read(directory / 'result.json') if (directory / 'result.json').exists() else {}
        completion = read(directory / 'executor-result.json') if (directory / 'executor-result.json').exists() else {}
        if not isinstance(result, dict) or not isinstance(completion, dict):
            raise ValueError('invalid_receipt')
        actual = result.get('source', {})
        if not isinstance(actual, dict) or not isinstance(result.get('scenarios', {}), dict):
            raise ValueError('invalid_receipt')
        source_matches = (actual.get('sha') == request['head_sha']
                          and actual.get('source_sha256') == request['source_sha256']
                          and actual.get('checkout') == request['checkout']
                          and result.get('run_id') == request['run_id'])
        passed = (not running and completion.get('exit_code') == 0 and completion.get('cleanup_only') is False
                  and source_matches and result.get('status') == 'passed' and result.get('cleanup') is True
                  and result.get('main_preserved') is True and result.get('originals_preserved') is True)
        return {'run_id': request['run_id'], 'head_sha': request['head_sha'], 'source_sha256': request['source_sha256'],
                'scenario': request['scenario'], 'running': running,
                'status': 'running' if running else 'passed' if passed else 'failed',
                'cleanup': not running and (source_matches and result.get('cleanup') is True
                                           or completion.get('never_started') is True),
                'failure': result.get('error') if result.get('error') in ERROR_CODES else None,
                'cleanup_unconfirmed': result.get('cleanup_error') == 'cleanup_unconfirmed_journal_retained',
                'evidence': result.get('evidence') if result.get('evidence') in ('live', 'fixture') else 'none',
                'main_preserved': source_matches and result.get('main_preserved') is True,
                'originals_preserved': source_matches and result.get('originals_preserved') is True,
                'scenarios': {key: value.get('passed') is True for key, value in result.get('scenarios', {}).items()
                              if key in ('readiness', 'bootstrap', 'resume', 'exclusive_access') and isinstance(value, dict)}}


def supervise(directory, descriptor, cleanup=False):
    record = read(directory / 'request.json')
    config, request = record['config'], record['request']
    # Inherited exclusive descriptor remains held across supervisor/server restarts.
    os.fstat(descriptor)
    runner = Path(__file__).with_name('test-instance-run')
    command = [sys.executable, str(runner), '--checkout', config['checkout'], '--manifest', config['manifest'],
               '--test-instance', config['instance'], '--run-id', request['run_id'],
               '--expected-sha', request['head_sha'], '--expected-source', request['source_sha256'],
               '--port', str(config['port']), '--timeout', str(config['timeout']),
               '--result-dir', str(directory), '--scenario', request['scenario']]
    if cleanup:
        if not (directory / 'plan.json').exists():
            atomic(directory / 'executor-result.json', {'exit_code': 1, 'cleanup_only': True, 'never_started': True})
            return
        command += ['--resume', '--cleanup-only']
    env = dict(os.environ)
    # Retain the operator's auth context; discard any inherited worker/service binding.
    for key in list(env):
        if key.startswith('SYMPHONY_') and key not in ('SYMPHONY_LINEAR_SECRET_ACCESS',):
            env.pop(key)
    child = None
    code = 1
    try:
        with os.fdopen(os.open(directory / 'executor.log', os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600), 'ab') as log:
            child = subprocess.Popen(command, env=env, pass_fds=(descriptor,), start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + config['timeout'] + 90
            cancelled_at = None
            while child.poll() is None:
                if ((directory / 'cancel.json').exists() and not cleanup or time.monotonic() >= deadline) and cancelled_at is None:
                    child.terminate()
                    cancelled_at = time.monotonic()
                if cancelled_at is not None and time.monotonic() - cancelled_at > 75:
                    child.kill()  # Existing runner guardian reaps only its own descendants.
                time.sleep(0.1)
            code = child.returncode
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=75)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        atomic(directory / 'executor-result.json', {'exit_code': code, 'cleanup_only': cleanup})
        os.close(descriptor)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        try:
            raw = self.rfile.readline(16_385)
            result = self.server.executor.handle(json.loads(raw)) if len(raw) <= 16_384 else {'error': 'request_too_large'}
            self.wfile.write(json.dumps(result).encode() + b'\n')
        except (OSError, ValueError):
            pass  # A lost reply never starts a second run.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--socket', type=Path)
    parser.add_argument('--supervise', type=Path)
    parser.add_argument('--lock-fd', type=int)
    parser.add_argument('--cleanup', action='store_true')
    args = parser.parse_args()
    if args.supervise is not None:
        supervise(args.supervise, args.lock_fd, args.cleanup)
        return
    if args.config is None or args.socket is None:
        parser.error('--config and --socket required')
    # Provisioning must be deliberate; a worker with secret access denied cannot
    # promote itself into an operator by invoking this entrypoint.
    if os.environ.get('SYMPHONY_LINEAR_SECRET_ACCESS') == 'denied':
        parser.error('Operatorbereitstellung erforderlich')
    executor = Executor(read(args.config))
    endpoint = helper().canonical(args.socket)
    endpoint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if endpoint.parent.stat().st_uid != os.getuid() or endpoint.parent.stat().st_mode & 0o077:
        parser.error('Socketverzeichnis muss dem Betreiber gehören und Modus 0700 haben')
    descriptor = locked(endpoint.with_suffix('.lock'))
    if descriptor is None:
        parser.error('Executor läuft bereits')
    if endpoint.exists():
        if not stat.S_ISSOCK(endpoint.lstat().st_mode):
            parser.error('Fremde Socketdatei')
        endpoint.unlink()
    try:
        with socketserver.UnixStreamServer(str(endpoint), Handler) as server:
            os.chmod(endpoint, 0o600)
            server.executor = executor
            server.serve_forever()
    finally:
        endpoint.unlink(missing_ok=True)
        os.close(descriptor)


if __name__ == '__main__':
    main()
