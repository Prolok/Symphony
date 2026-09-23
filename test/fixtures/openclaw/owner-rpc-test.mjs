import assert from 'node:assert/strict';
import { ownerConnection, localAccess, wireReply } from '../../../scripts/openclaw-owner-rpc.mjs';
import auth from './owner.cjs';

const old = { ownerConnId: 'first-connection' };
assert.equal(auth.canRequesterAbortChatRun(old, { connId: 'second-connection', isAdmin: false }), false);
assert.equal(auth.canRequesterAbortChatRun(old, { connId: 'first-connection', isAdmin: false }), true);
const typed = (message, retryable = false) => Object.assign(new Error(message), { gatewayCode: 'INVALID_REQUEST', retryable });
const params = { agentId: 'fixture', idempotencyKey: 'run', sessionKey: 'session', message: 'fixture' };
for (const scenario of ['accepted', 'missing', 'reconnect', 'unauthorized', 'transient', 'connect', 'timeout', 'close', 'exception', 'unknown', 'preflight', 'request-timeout']) {
  let requests = 0, stopped = 0, started = 0, observed;
  class Client {
    constructor(opts) {
      observed = opts;
      if (scenario === 'exception') throw new Error('SECRET');
      this.opts = opts;
    }
    stop() { stopped++; }
    start() {
      started++;
      if (scenario === 'timeout') return;
      if (scenario === 'close') return this.opts.onClose(1006, 'SECRET');
      if (scenario === 'connect') return this.opts.onConnectError(typed('SECRET'));
      this.opts.onHelloOk({});
      if (scenario === 'reconnect') this.opts.onHelloOk({});
    }
    async request(method, input, opts) {
      requests++;
      assert.equal(method, 'agent');
      assert.deepEqual(input, params);
      assert.equal(opts.expectFinal, false);
      if (scenario === 'request-timeout') return new Promise(() => {});
      if (scenario === 'unauthorized') throw typed('unauthorized');
      if (scenario === 'transient') throw typed('SECRET', true);
      if (scenario === 'unknown') throw new Error('SECRET');
      if (scenario === 'preflight') throw typed('cwd is reserved for plugin-owned subagent runs');
      return { status: 'accepted' };
    }
  }
  const sdk = { GatewayClient: Client, isGatewayClientRequestError: e => typeof e.retryable === 'boolean' };
  const connection = ownerConnection(sdk, scenario === 'missing' ? null : { token: 'synthetic-shared' }, { timeoutMs: 5 });
  const result = await connection.request('agent', params);
  if (observed) {
    assert.deepEqual(observed.scopes, ['operator.write']);
    assert.equal(observed.sharedStateMode, 'read-only');
    assert.equal(observed.deviceIdentity, null);
    assert.equal(observed.token, 'synthetic-shared');
    for (const key of ['password', 'deviceToken', 'hostDeps', 'preparedDeviceAuth']) assert.equal(observed[key], undefined);
  }
  assert.ok(!JSON.stringify(result).includes('SECRET'));
  assert.equal(result.ok, scenario === 'accepted');
  assert.equal((await connection.request('agent', params)).ok, false);
  const count = requests;
  assert.equal((await connection.request('sessions.abort', { key: 'foreign', runId: 'run' })).ok, false);
  assert.equal(requests, count);
  connection.close();
  assert.equal((await connection.request('agent.wait', { runId: 'run' })).ok, false);
  assert.ok(requests <= 1);
  if (!['exception', 'missing'].includes(scenario)) assert.equal(stopped, 1);
  if (scenario === 'missing') { assert.equal(started, 0); assert.equal(result.reason, 'credentials_unavailable'); }
  if (scenario === 'unauthorized') assert.deepEqual(result.error, { type: 'gateway_request_error', phase: 'request', code: 'INVALID_REQUEST', message: 'unauthorized', retryable: false });
  if (scenario === 'transient') assert.equal(result.error.retryable, true);
  if (scenario === 'connect') assert.equal(result.error.phase, 'connect');
  const args = ['gateway', 'call', scenario === 'preflight' ? 'agent' : 'sessions.abort', '--params', JSON.stringify(params)];
  const wire = wireReply(args, result);
  assert.ok(!JSON.stringify(wire).includes('SECRET'));
  if (scenario === 'preflight') assert.equal(JSON.parse(wire.output).symphony_openclaw_rejection, 1);
}
for (const mode of ['token', 'password', 'none', 'trusted-proxy']) {
  const sdk = { resolveGatewayAuth: ({ authConfig, env }) => { assert.equal(env, 'fixture-env'); return { ...authConfig, [mode]: 'synthetic' }; } };
  const config = { readConfigFileSnapshot: async opts => { assert.equal(opts.observe, false); assert.equal(opts.recoverSuspicious, false); return { valid: true, config: { gateway: { mode: 'local', auth: { mode } } } }; } };
  assert.deepEqual(await localAccess(sdk, config, 'fixture-env'), ['token', 'password'].includes(mode) ? { [mode]: 'synthetic' } : null);
  assert.equal(await localAccess(sdk, { readConfigFileSnapshot: async () => ({ valid: false }) }, 'fixture-env'), null);
  assert.equal(await localAccess(sdk, { readConfigFileSnapshot: async () => ({ valid: true, config: { gateway: { mode: 'remote' } } }) }, 'fixture-env'), null);
}
console.log('PASS: owner connection, no reconnect or credential fallback, failure classification and redaction');
