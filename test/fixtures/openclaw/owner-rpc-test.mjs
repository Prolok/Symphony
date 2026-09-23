import assert from 'node:assert/strict';
import { ownerRequest } from '../../../scripts/openclaw-owner-rpc.mjs';
import auth from './owner.cjs';

// The old two-CLI path has neither a common connection nor a device owner.
const old = { ownerConnId: 'first-connection' };
assert.equal(auth.canRequesterAbortChatRun(old, { connId: 'second-connection', isAdmin: false }), false);
assert.equal(auth.canRequesterAbortChatRun({ ...old, ownerDeviceId: 'own-device' }, { deviceId: 'own-device', connId: 'second', isAdmin: false }), true);
assert.equal(auth.canRequesterAbortChatRun({ ...old, ownerDeviceId: 'own-device' }, { deviceId: 'foreign', connId: 'second', isAdmin: false }), false);

const typed = (message, retryable = false) => Object.assign(new Error(message), { gatewayCode: 'INVALID_REQUEST', retryable });
for (const scenario of ['accepted', 'missing', 'reconnect', 'unauthorized', 'transient', 'connect', 'timeout', 'close', 'exception', 'unknown', 'preflight']) {
  let requests = 0, stopped = 0, started = 0;
  let observed;
  class Client {
    constructor(opts) {
      observed = opts;
      if (scenario === 'exception') throw new Error('SECRET');
      this.opts = opts;
    }
    getConnectionMetadata() { return { hasDeviceIdentity: scenario !== 'missing' }; }
    stop() { stopped++; }
    start() {
      started++;
      if (scenario === 'timeout') return;
      if (scenario === 'close') return this.opts.onClose(1006, 'SECRET');
      if (scenario === 'connect') return this.opts.onConnectError(typed('SECRET'));
      this.opts.onHelloOk({});
      if (scenario === 'reconnect') this.opts.onHelloOk({});
    }
    async request(method, params, opts) {
      requests++;
      assert.equal(method, 'agent');
      assert.deepEqual(params, { message: 'fixture' });
      assert.equal(opts.expectFinal, false);
      if (scenario === 'unauthorized') throw typed('unauthorized');
      if (scenario === 'transient') throw typed('SECRET', true);
      if (scenario === 'unknown') throw new Error('SECRET');
      if (scenario === 'preflight') throw typed('cwd is reserved for plugin-owned subagent runs');
      return { status: 'accepted' };
    }
  }
  const result = await ownerRequest({ GatewayClient: Client, isGatewayClientRequestError: e => typeof e.retryable === 'boolean' }, 'agent', { message: 'fixture' }, { timeoutMs: 5 });
  assert.deepEqual(observed.scopes, ['operator.write']);
  assert.equal(observed.sharedStateMode, 'read-only');
  assert.equal(observed.url, 'ws://127.0.0.1:18789');
  for (const key of ['token', 'password', 'deviceIdentity', 'deviceToken', 'hostDeps', 'preparedDeviceAuth']) assert.equal(observed[key], undefined);
  assert.ok(requests <= 1);
  assert.ok(!JSON.stringify(result).includes('SECRET'));
  assert.equal(result.ok, ['accepted', 'reconnect'].includes(scenario));
  if (scenario !== 'exception') assert.equal(stopped, 1);
  if (scenario === 'missing') assert.equal(started, 0);
  if (scenario === 'unauthorized') assert.deepEqual(result.error, { type: 'gateway_request_error', phase: 'request', code: 'INVALID_REQUEST', message: 'unauthorized', retryable: false });
  if (scenario === 'transient') assert.equal(result.error.retryable, true);
  if (scenario === 'connect') assert.equal(result.error.phase, 'connect');
  if (scenario === 'preflight') assert.equal(result.error.message, 'cwd is reserved for plugin-owned subagent runs');
}
console.log('PASS: owner boundary, fencing, retry classification and redaction');
