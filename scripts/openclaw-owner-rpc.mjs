// Public SDK only. One normal local CLI connection owns one Symphony run.
// No pairing, identity creation, credential fallback, reconnect or broader scope.
import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';

const messages = new Set(['unauthorized', 'cwd is reserved for plugin-owned subagent runs', 'cwd must be absolute']);
const localError = reason => ({ ok: false, reason });

export async function localAccess(sdk, configSdk, env) {
  // The supported read-only snapshot API resolves the existing profile/env.
  // Credentials remain in this child; never return them to Symphony or logs.
  const snapshot = await configSdk.readConfigFileSnapshot({ observe: false, recoverSuspicious: false, pluginValidation: 'core-only' });
  if (!snapshot.valid || snapshot.config?.gateway?.mode === 'remote') return null;
  const auth = sdk.resolveGatewayAuth({ authConfig: snapshot.config?.gateway?.auth, env });
  if (!['token', 'password'].includes(auth.mode) || typeof auth[auth.mode] !== 'string' || !auth[auth.mode].trim()) return null;
  return { [auth.mode]: auth[auth.mode] };
}

export function ownerConnection(sdk, access, options = {}) {
  const timeoutMs = options.timeoutMs ?? 10000;
  let client, connecting, ready = false, failure, owner, busy = false, pending;
  function close(reason = localError('owner_connection_lost')) {
    if (failure) return;
    failure = reason;
    ready = false;
    pending?.(reason);
    client?.stop();
  }
  function sanitized(error, phase) {
    if (!sdk.isGatewayClientRequestError(error)) return localError('owner_connection_lost');
    return { ok: false, error: { type: 'gateway_request_error', phase,
      code: ['INVALID_REQUEST', 'UNAVAILABLE', 'NOT_LINKED'].includes(error.gatewayCode) ? error.gatewayCode : 'OTHER',
      message: messages.has(error.message) ? error.message : 'request rejected', retryable: error.retryable } };
  }
  async function connect() {
    if (failure) return failure;
    if (ready) return { ok: true };
    if (connecting) return connecting;
    if (!access) { close(localError('credentials_unavailable')); return failure; }
    connecting = new Promise(resolve => {
      const timer = setTimeout(() => close(), timeoutMs);
      pending = result => { clearTimeout(timer); pending = undefined; resolve(result); };
      try {
        client = new sdk.GatewayClient({
          url: options.url ?? 'ws://127.0.0.1:18789', ...access,
          clientName: 'cli', mode: 'cli', role: 'operator', scopes: ['operator.write'],
          deviceIdentity: null, sharedStateMode: 'read-only', requestTimeoutMs: timeoutMs,
          onHelloOk: () => {
            if (failure || ready) { close(); return; }
            ready = true;
            pending?.({ ok: true });
          },
          onConnectError: error => close(sanitized(error, 'connect')),
          onClose: () => close(),
        });
        client.start();
      } catch (error) { close(sanitized(error, 'connect')); }
    });
    return connecting;
  }
  async function request(method, params) {
    if (!['agents.list', 'agent', 'agent.wait', 'sessions.abort'].includes(method) || busy) return localError('owner_mismatch');
    if (method === 'agent' && owner) return localError('owner_mismatch');
    if (['sessions.abort', 'agent.wait'].includes(method)) {
      if (!owner) return localError('owner_connection_lost');
      if (params.runId !== owner.id || (method === 'sessions.abort' && params.key !== owner.session)) return localError('owner_mismatch');
    }
    if (method === 'agent' && !['idempotencyKey', 'sessionKey', 'agentId'].every(k => typeof params[k] === 'string' && params[k])) return localError('owner_mismatch');
    busy = true;
    try {
      const connection = await connect();
      if (failure) return failure;
      if (!connection.ok) return connection;
      // Bind before sending: uncertain acceptance never permits a second start.
      if (method === 'agent') owner = { id: params.idempotencyKey, session: params.sessionKey };
      return await new Promise(resolve => {
        const timer = setTimeout(() => close(), timeoutMs);
        pending = result => { clearTimeout(timer); pending = undefined; resolve(result); };
        client.request(method, params, { timeoutMs, expectFinal: false }).then(
          payload => pending?.({ ok: true, payload }),
          error => {
            const result = sanitized(error, 'request');
            if (result.reason) close(result);
            else pending?.(result);
          },
        );
      });
    } finally { busy = false; }
  }
  return { request, close };
}

export function wireReply(args, reply) {
  const method = args[2], raw = args[4];
  if (reply.ok) return { code: 0, output: JSON.stringify(reply.payload) };
  const digest = () => createHash('sha256').update(raw).digest('hex');
  if (method === 'sessions.abort') {
    const error = reply.error;
    if (reply.reason || typeof error?.retryable === 'boolean') {
      return { code: 0, output: JSON.stringify({ symphony_openclaw_abort_error: 1, method,
        code: error?.code ?? 'NOT_LINKED', retryable: error?.retryable ?? false,
        reason: reply.reason ?? (error.message === 'unauthorized' ? 'unauthorized' : 'request_rejected'), request_sha256: digest() }) };
    }
  }
  const reasons = { 'cwd is reserved for plugin-owned subagent runs': 'cwd_reserved', 'cwd must be absolute': 'cwd_not_absolute' };
  if (method === 'agent' && reply.error?.phase === 'request' && reply.error.code === 'INVALID_REQUEST' && reply.error.retryable === false && reasons[reply.error.message]) {
    return { code: 0, output: JSON.stringify({ symphony_openclaw_rejection: 1, method, phase: 'pre_acceptance',
      code: 'INVALID_REQUEST', reason: reasons[reply.error.message], request_sha256: digest() }) };
  }
  const code = reply.reason === 'credentials_unavailable' ? 124 : reply.reason === 'owner_connection_lost' ? 123
    : reply.error?.phase === 'connect' && reply.error.retryable === false ? 122 : 1;
  return { code, output: '' };
}

export async function runTransport(packageEntry, options = {}) {
  const require = createRequire(realpathSync(packageEntry));
  const sdk = await import(pathToFileURL(require.resolve('openclaw/plugin-sdk/gateway-runtime')).href);
  const configSdk = await import(pathToFileURL(require.resolve('openclaw/plugin-sdk/health')).href);
  let access;
  try { access = await localAccess(sdk, configSdk, process.env); } catch { access = null; }
  const connection = ownerConnection(sdk, access, options);
  const lines = createInterface({ input: process.stdin });
  try {
    for await (const line of lines) {
      const args = JSON.parse(line);
      const reply = wireReply(args, await connection.request(args[2], JSON.parse(args[4])));
      if (options.stream) process.stdout.write(JSON.stringify(reply) + '\n');
      else { process.stdout.write(reply.output); return reply.code; }
    }
    return 0;
  } finally { connection.close(); lines.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.env.SYMPHONY_OPENCLAW_TEST_DENY === '1') process.exit(126);
  // SDK diagnostics may contain config/auth details; stdout is protocol only.
  console.log = console.warn = console.error = console.info = console.debug = () => {};
  runTransport(process.argv[2], { stream: process.argv[3] === '--stream' })
    .then(code => process.exit(code), () => process.exit(1));
}
