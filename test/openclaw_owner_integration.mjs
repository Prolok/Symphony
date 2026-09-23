// Opt-in SDK contract test. Only a loopback fixture server and synthetic device
// keys/tokens; never connect to an installed gateway or read an operator profile.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { generateKeyPairSync, createHash, createPublicKey, verify, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { ownerRequest } from '../scripts/openclaw-owner-rpc.mjs';
import authorization from './fixtures/openclaw/owner.cjs';

if (process.env.SYMPHONY_OPENCLAW_TEST_DENY === '1') throw new Error('SDK integration is opt-in');
const isChild = process.argv[3] === 'child';
const directory = isChild ? process.env.OPENCLAW_STATE_DIR : mkdtempSync(resolve('tmp/pro874-owner-contract-'));
process.env.OPENCLAW_STATE_DIR = directory;
process.env.OPENCLAW_CONFIG_PATH = join(directory, 'absent.json');
const packagePath = resolve(process.argv[2]);
const require = createRequire(packagePath);
assert.equal(JSON.parse(readFileSync(packagePath)).version, '2026.9.4');
const sdk = await import(pathToFileURL(require.resolve('openclaw/plugin-sdk/gateway-runtime')).href);

if (isChild) {
  const input = JSON.parse(await new Promise(r => process.stdin.once('data', r)));
  let reply;
  if (input.legacy) {
    try {
      const payload = await sdk.callGatewayFromCli(input.method,
        { url: input.url, token: 'synthetic-shared', json: true, timeout: '2000' }, input.params,
        { scopes: ['operator.write'], sharedStateMode: 'read-only' });
      reply = { ok: true, payload };
    } catch (e) {
      reply = { ok: false, code: e.gatewayCode, message: e.message };
    }
  } else {
    // Inject synthetic *credentials*, retaining the real public SDK client,
    // framing, signature, scope and connection lifecycle code unchanged.
    const fixtureSdk = { ...sdk, GatewayClient: class extends sdk.GatewayClient {
      constructor(opts) { super({ ...opts, deviceIdentity: input.identity,
        preparedDeviceAuth: { token: 'synthetic-device', role: 'operator', scopes: ['operator.write'] } }); }
    } };
    reply = await ownerRequest(fixtureSdk, input.method, input.params, { url: input.url, timeoutMs: 2000 });
  }
  process.stdout.write(JSON.stringify(reply));
  process.exit(0);
}

const { WebSocketServer } = require('ws');
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
await new Promise(r => server.once('listening', r));
const url = `ws://127.0.0.1:${server.address().port}`;
const runs = new Map();
const connects = [];
const failures = [];
server.on('connection', socket => {
  const connId = randomUUID(), nonce = randomUUID();
  let requester;
  socket.send(JSON.stringify({ type: 'event', event: 'connect.challenge', payload: { nonce, ts: Date.now() } }));
  socket.on('message', bytes => {
    try {
      const { id, method, params } = JSON.parse(bytes);
      const respond = (payload) => socket.send(JSON.stringify({ type: 'res', id, ok: true, payload }));
      if (method === 'connect') {
        assert.deepEqual(params.scopes, ['operator.write']);
        assert.equal(params.role, 'operator');
        if (params.device) {
          assert.equal(params.auth.deviceToken, 'synthetic-device');
          assert.equal(params.auth.token, undefined);
          const device = params.device;
          const pub = Buffer.from(device.publicKey, 'base64url');
          assert.equal(device.id, createHash('sha256').update(pub).digest('hex'));
          assert.equal(device.nonce, nonce);
          const key = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pub]), type: 'spki', format: 'der' });
          const payload = ['v3', device.id, params.client.id, params.client.mode, params.role, params.scopes.join(','), String(device.signedAt), 'synthetic-device', nonce,
            params.client.platform.trim().toLowerCase(), (params.client.deviceFamily ?? '').trim().toLowerCase()].join('|');
          assert.ok(verify(null, Buffer.from(payload), key, Buffer.from(device.signature, 'base64url')));
        } else {
          assert.equal(params.auth.token, 'synthetic-shared');
        }
        requester = authorization.resolveChatAbortRequester({ connId, connect: params });
        connects.push({ connId, device: requester.deviceId, admin: requester.isAdmin });
        respond({ type: 'hello-ok', protocol: params.maxProtocol, server: { version: '2026.9.4', connId }, features: { methods: ['agent', 'sessions.abort'], events: [] }, snapshot: {},
          auth: { role: 'operator', scopes: params.scopes }, policy: { maxPayload: 2000000, maxBufferedBytes: 2000000, tickIntervalMs: 30000 } });
      } else if (method === 'agent') {
        assert.ok(requester);
        assert.ok(!runs.has(params.idempotencyKey));
        runs.set(params.idempotencyKey, { ownerConnId: requester.connId, ownerDeviceId: requester.deviceId, session: params.sessionKey });
        respond({ runId: params.idempotencyKey, status: 'accepted' });
      } else if (method === 'sessions.abort') {
        const entry = runs.get(params.runId);
        if (!entry || entry.session !== params.key || !authorization.canRequesterAbortChatRun(entry, requester)) {
          socket.send(JSON.stringify({ type: 'res', id, ok: false, error: { code: 'INVALID_REQUEST', message: 'unauthorized', retryable: false, details: 'PRIVATE' } }));
        } else {
          respond({ ok: true, status: 'aborted', abortedRunId: params.runId });
        }
      } else throw new Error('unexpected method');
    } catch (e) { failures.push(e); socket.close(); }
  });
});
function identity() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  return { deviceId: createHash('sha256').update(raw).digest('hex'),
    publicKeyPem: publicKey.export({ format: 'pem', type: 'spki' }), privateKeyPem: privateKey.export({ format: 'pem', type: 'pkcs8' }) };
}
function call(data) {
  return new Promise((resolveReply, reject) => {
    const child = spawn(process.execPath, [process.argv[1], packagePath, 'child'], {
      env: { PATH: process.env.PATH, OPENCLAW_STATE_DIR: directory, OPENCLAW_CONFIG_PATH: join(directory, 'absent.json') }, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', b => stdout += b);
    child.stderr.on('data', b => stderr += b);
    child.once('error', reject);
    child.once('exit', code => {
      try { assert.equal(code, 0, stderr); resolveReply(JSON.parse(stdout)); } catch (e) { reject(e); }
    });
    child.stdin.end(JSON.stringify({ url, ...data }));
  });
}
try {
  const missing = await ownerRequest(sdk, 'agents.list', {}, { url, timeoutMs: 1000 });
  assert.equal(missing.ownerIdentityMissing, true);
  assert.deepEqual(readdirSync(directory), []);
  assert.equal(connects.length, 0);
  const params = { sessionKey: 'session', idempotencyKey: 'legacy' };
  assert.equal((await call({ legacy: true, method: 'agent', params })).ok, true);
  const oldAbort = await call({ legacy: true, method: 'sessions.abort', params: { key: 'session', runId: 'legacy' } });
  assert.equal(oldAbort.ok, false);
  assert.equal(oldAbort.message, 'unauthorized');
  const own = identity(), other = identity();
  assert.equal((await call({ identity: own, method: 'agent', params: { ...params, idempotencyKey: 'own' } })).ok, true);
  const foreign = await call({ identity: other, method: 'sessions.abort', params: { key: 'session', runId: 'own' } });
  assert.equal(foreign.error.message, 'unauthorized');
  assert.equal(foreign.error.retryable, false);
  assert.ok(!JSON.stringify(foreign).includes('PRIVATE'));
  const abort = await call({ identity: own, method: 'sessions.abort', params: { key: 'session', runId: 'own' } });
  assert.equal(abort.ok, true);
  assert.deepEqual(abort.payload, { ok: true, status: 'aborted', abortedRunId: 'own' });
  assert.equal((await call({ identity: own, method: 'sessions.abort', params: { key: 'foreign-session', runId: 'own' } })).ok, false);
  assert.equal(new Set(connects.map(c => c.connId)).size, 6);
  assert.equal(connects[0].device, undefined);
  assert.equal(connects[1].device, undefined);
  assert.equal(connects[2].device, connects[4].device);
  assert.ok(connects.every(c => !c.admin));
  assert.deepEqual(failures, []);
  console.log('PASS: public SDK; separate CLI connections rejected; same device across processes accepted; foreign device/session rejected; signed operator.write only. Synthetic server, no live product pass.');
} finally {
  for (const socket of server.clients) socket.terminate();
  await new Promise(r => server.close(r));
  rmSync(directory, { recursive: true, force: true });
}
