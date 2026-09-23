// Opt-in: real public SDK/config resolution; loopback host and credentials are synthetic.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { generateKeyPairSync, createHash, randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import authorization from './fixtures/openclaw/owner.cjs';

if (process.env.SYMPHONY_OPENCLAW_TEST_DENY === '1') throw new Error('SDK integration is opt-in');
const packagePath = resolve(process.argv[2]);
const require = createRequire(packagePath);
assert.equal(JSON.parse(readFileSync(packagePath)).version, '2026.9.4');
const { WebSocketServer } = require('ws');
const directory = mkdtempSync(resolve('tmp/pro874-connection-contract-'));
const configPath = join(directory, 'openclaw.json');
mkdirSync(join(directory, 'identity'));
const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const identity = { version: 1, createdAtMs: Date.now(),
  deviceId: createHash('sha256').update(publicKey.export({ format: 'der', type: 'spki' }).subarray(-32)).digest('hex'),
  publicKeyPem: publicKey.export({ format: 'pem', type: 'spki' }), privateKeyPem: privateKey.export({ format: 'pem', type: 'pkcs8' }) };
const identityBytes = JSON.stringify(identity);
writeFileSync(join(directory, 'identity/device.json'), identityBytes);
// Same supported local endpoint as production. No installed gateway is contacted.
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
await new Promise(r => server.once('listening', r));
const url = `ws://127.0.0.1:${server.address().port}`;
writeFileSync(configPath, JSON.stringify({ gateway: { mode: 'local', auth: { mode: 'token', token: 'synthetic-shared' } } }));
const runs = new Map(), connects = [], calls = [], failures = [], children = [];
server.on('connection', socket => {
  const connId = randomUUID();
  let requester;
  socket.send(JSON.stringify({ type: 'event', event: 'connect.challenge', payload: { nonce: randomUUID(), ts: Date.now() } }));
  socket.on('message', bytes => {
    try {
      const { id, method, params } = JSON.parse(bytes);
      const respond = payload => socket.send(JSON.stringify({ type: 'res', id, ok: true, payload }));
      const reject = () => socket.send(JSON.stringify({ type: 'res', id, ok: false,
        error: { code: 'INVALID_REQUEST', message: 'unauthorized', retryable: false, details: 'SECRET' } }));
      if (method === 'connect') {
        if (params.auth?.token !== 'synthetic-shared') return reject();
        assert.equal(params.device, undefined);
        assert.deepEqual(params.scopes, ['operator.write']);
        assert.equal(params.role, 'operator');
        requester = authorization.resolveChatAbortRequester({ connId, connect: params });
        connects.push(requester);
        respond({ type: 'hello-ok', protocol: params.maxProtocol, server: { version: '2026.9.4', connId },
          features: { methods: ['agents.list', 'agent', 'agent.wait', 'sessions.abort'], events: [] }, snapshot: {},
          auth: { role: 'operator', scopes: params.scopes }, policy: { maxPayload: 2000000, maxBufferedBytes: 2000000, tickIntervalMs: 30000 } });
      } else {
        calls.push({ method, params, connId });
        if (method === 'agents.list') return respond({ agents: [{ id: 'fixture' }] });
        if (method === 'agent') {
          assert.ok(!runs.has(params.idempotencyKey));
          runs.set(params.idempotencyKey, { ownerConnId: connId, session: params.sessionKey });
          return respond({ runId: params.idempotencyKey, status: 'accepted' });
        }
        if (method === 'agent.wait') return respond({ runId: params.runId, status: 'running' });
        const entry = runs.get(params.runId);
        if (!entry || entry.session !== params.key || !authorization.canRequesterAbortChatRun(entry, requester)) return reject();
        respond({ ok: true, status: 'aborted', abortedRunId: params.runId });
      }
    } catch (e) { failures.push(e); socket.close(); }
  });
});
function client() {
  // Test-only wrapper injects the loopback fixture URL, not identity or credentials.
  const child = spawn(process.execPath, ['--input-type=module', '-e', `
    import * as transport from './scripts/openclaw-owner-rpc.mjs';
    if (transport.runTransport) {
      await transport.runTransport(${JSON.stringify(packagePath)}, { stream: true, url: ${JSON.stringify(url)} });
    } else {
      // Reproduce F6 on the pre-fix adapter, with the same real public SDK and profile.
      const { createRequire } = await import('node:module');
      const { pathToFileURL } = await import('node:url');
      const sdk = await import(pathToFileURL(createRequire(${JSON.stringify(packagePath)}).resolve('openclaw/plugin-sdk/gateway-runtime')).href);
      const result = await transport.ownerRequest(sdk, 'agents.list', {}, { url: ${JSON.stringify(url)}, timeoutMs: 2000 });
      console.log(JSON.stringify({ code: result.ok ? 0 : 1, output: JSON.stringify(result) }));
      process.exit(0);
    }
  `], { env: { PATH: process.env.PATH, HOME: directory, OPENCLAW_STATE_DIR: directory, OPENCLAW_CONFIG_PATH: configPath },
    stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child);
  let stderr = '';
  child.stderr.on('data', b => stderr += b);
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  return {
    async call(method, params = {}) {
      child.stdin.write(JSON.stringify(['gateway', 'call', method, '--params', JSON.stringify(params), '--json']) + '\n');
      const reply = await Promise.race([lines.next(), new Promise((_, reject) => {
        const timer = setTimeout(() => reject(new Error('fixture response timeout')), 15000); timer.unref();
      })]);
      assert.ok(!reply.done, stderr);
      assert.ok(!reply.value.includes('SECRET'));
      return JSON.parse(reply.value);
    },
    close() { child.stdin.end(); return new Promise(r => child.once('exit', r)); },
  };
}
async function legacy(method, params) {
  // The original per-RPC CLI transport has a different owner connection each time.
  const source = `
    import { createRequire } from 'node:module';
    import { pathToFileURL } from 'node:url';
    const sdk = await import(pathToFileURL(createRequire(${JSON.stringify(packagePath)}).resolve('openclaw/plugin-sdk/gateway-runtime')).href);
    try {
      const payload = await sdk.callGatewayFromCli(${JSON.stringify(method)},
        { url: ${JSON.stringify(url)}, token: 'synthetic-shared', json: true, timeout: '2000' },
        ${JSON.stringify(params)}, { scopes: ['operator.write'], sharedStateMode: 'read-only' });
      console.log(JSON.stringify({ ok: true, payload }));
    } catch (error) { console.log(JSON.stringify({ ok: false, unauthorized: error.message === 'unauthorized' })); }
  `;
  const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { PATH: process.env.PATH, HOME: directory, OPENCLAW_STATE_DIR: directory, OPENCLAW_CONFIG_PATH: configPath }, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  let output = '', errors = '';
  child.stdout.on('data', b => output += b);
  child.stderr.on('data', b => errors += b);
  assert.equal(await new Promise(r => child.once('exit', r)), 0, errors);
  return JSON.parse(output);
}
try {
  assert.equal((await legacy('agent', { agentId: 'fixture', sessionKey: 'old-session', idempotencyKey: 'old-run' })).ok, true);
  assert.deepEqual(await legacy('sessions.abort', { key: 'old-session', runId: 'old-run' }), { ok: false, unauthorized: true });
  const legacyCalls = calls.length;
  const afterLegacy = readdirSync(directory, { recursive: true }).sort();
  const storeBefore = afterLegacy.includes('state/openclaw.sqlite') ? createHash('sha256').update(readFileSync(join(directory, 'state/openclaw.sqlite'))).digest('hex') : null;
  const own = client();
  const preflight = await own.call('agents.list');
  assert.equal(preflight.code, 0, JSON.stringify(preflight));
  assert.deepEqual(JSON.parse(preflight.output), { agents: [{ id: 'fixture' }] });
  assert.equal((await own.call('agent', { agentId: 'fixture', sessionKey: 'session', idempotencyKey: 'original', message: 'fixture' })).code, 0);
  const foreign = client();
  const rejected = await foreign.call('sessions.abort', { key: 'session', runId: 'original' });
  assert.equal(JSON.parse(rejected.output).reason, 'owner_connection_lost');
  const mismatch = await own.call('sessions.abort', { key: 'other', runId: 'original' });
  assert.equal(JSON.parse(mismatch.output).reason, 'owner_mismatch');
  assert.equal(calls.slice(legacyCalls).filter(c => c.method === 'sessions.abort').length, 0);
  const aborted = await own.call('sessions.abort', { key: 'session', runId: 'original' });
  assert.deepEqual(JSON.parse(aborted.output), { ok: true, status: 'aborted', abortedRunId: 'original' });
  assert.equal(new Set(calls.slice(legacyCalls).map(c => c.connId)).size, 1);
  assert.equal((await own.call('agent', { sessionKey: 'session', idempotencyKey: 'duplicate' })).code, 1);
  const before = connects.length;
  for (const socket of server.clients) socket.terminate();
  await new Promise(r => setTimeout(r, 50));
  assert.equal((await own.call('agent.wait', { runId: 'original' })).code, 123);
  assert.equal(JSON.parse((await own.call('sessions.abort', { key: 'session', runId: 'original' })).output).reason, 'owner_connection_lost');
  assert.equal(connects.length, before);
  assert.equal(await own.close(), 0);
  assert.equal(await foreign.close(), 0);
  writeFileSync(configPath, JSON.stringify({ gateway: { mode: 'local', auth: { mode: 'token' } } }));
  const missing = client();
  assert.equal((await missing.call('agents.list')).code, 124);
  assert.equal(await missing.close(), 0);
  assert.equal(connects.length, before);
  writeFileSync(configPath, JSON.stringify({ gateway: { mode: 'local', auth: { mode: 'token', token: 'wrong-synthetic-token' } } }));
  const denied = client();
  assert.equal((await denied.call('agents.list')).code, 122);
  assert.equal((await denied.call('agents.list')).code, 122);
  assert.equal(await denied.close(), 0);
  assert.equal(connects.length, before);
  assert.deepEqual(readdirSync(join(directory, 'identity')), ['device.json']);
  assert.deepEqual(readdirSync(directory, { recursive: true }).sort(), afterLegacy);
  assert.deepEqual(afterLegacy, ['identity', 'identity/device.json', 'openclaw.json']);
  if (storeBefore) assert.equal(createHash('sha256').update(readFileSync(join(directory, 'state/openclaw.sqlite'))).digest('hex'), storeBefore);
  assert.equal(readFileSync(join(directory, 'identity/device.json'), 'utf8'), identityBytes);
  assert.ok(connects.every(c => !c.isAdmin && !c.deviceId));
  assert.deepEqual(failures, []);
  console.log('PASS: real public SDK/config path, existing unpaired identity and empty device cache; one shared-auth owner connection; own abort; foreign/mismatched/repeated requests and connection loss fenced; no state writes. Synthetic host, no live pass.');
} finally {
  for (const child of children) if (child.exitCode === null) child.kill();
  for (const socket of server.clients) socket.terminate();
  await new Promise(r => server.close(r));
  rmSync(directory, { recursive: true, force: true });
}
