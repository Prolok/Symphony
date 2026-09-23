// Public SDK boundary for owner-correlated RPCs. No identity creation, pairing,
// shared-secret fallback, private dist imports, or broader operator scopes.
import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';

export async function ownerRequest(sdk, method, params, options = {}) {
  const timeoutMs = options.timeoutMs ?? 10000;
  let client;
  let timer;
  let dispatched = false;
  const reply = await new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      client?.stop();
      resolve(value);
    };
    const fail = (error) => {
      if (sdk.isGatewayClientRequestError(error)) {
        // Do not forward details, diagnostics, credentials or arbitrary messages.
        finish({ ok: false, error: {
          type: 'gateway_request_error',
          phase: dispatched ? 'request' : 'connect',
          code: ['INVALID_REQUEST', 'UNAVAILABLE', 'NOT_LINKED'].includes(error.gatewayCode)
            ? error.gatewayCode : 'OTHER',
          message: ['unauthorized', 'cwd is reserved for plugin-owned subagent runs', 'cwd must be absolute'].includes(error.message)
            ? error.message : 'request rejected',
          retryable: error.retryable,
        } });
      } else {
        finish({ ok: false });
      }
    };
    try {
      client = new sdk.GatewayClient({
        url: options.url ?? 'ws://127.0.0.1:18789',
        clientName: 'cli',
        mode: 'cli',
        role: 'operator',
        scopes: ['operator.write'],
        sharedStateMode: 'read-only',
        requestTimeoutMs: timeoutMs,
        onHelloOk: () => {
          if (settled || dispatched) return;
          dispatched = true;
          client.request(method, params, { timeoutMs, expectFinal: false })
            .then((payload) => finish({ ok: true, payload }), fail);
        },
        onConnectError: fail,
        onClose: () => finish({ ok: false }),
      });
      if (!client.getConnectionMetadata().hasDeviceIdentity) {
        finish({ ok: false, ownerIdentityMissing: true, error: { type: 'gateway_request_error', phase: 'connect',
          code: 'NOT_LINKED', message: 'request rejected', retryable: false } });
        return;
      }
      timer = setTimeout(() => finish({ ok: false }), timeoutMs);
      client.start();
    } catch (error) {
      fail(error);
    }
  });
  return reply;
}

async function main() {
  if (process.env.SYMPHONY_OPENCLAW_TEST_DENY === '1') return 126;
  const lines = createInterface({ input: process.stdin });
  const line = await new Promise((resolve) => lines.once('line', resolve));
  lines.close();
  const args = JSON.parse(line);
  const method = args[2];
  if (!['agents.list', 'agent', 'sessions.abort'].includes(method)) return 1;
  // Resolve the public export from the same existing CLI package, not NODE_PATH
  // or a second installation. Node enforces the package's export map.
  const require = createRequire(realpathSync(process.argv[2]));
  const sdk = await import(pathToFileURL(require.resolve('openclaw/plugin-sdk/gateway-runtime')).href);
  const reply = await ownerRequest(sdk, method, JSON.parse(args[4]));
  if (reply.ok) {
    process.stdout.write(JSON.stringify(reply.payload));
    return 0;
  }
  if (reply.ownerIdentityMissing && method !== 'sessions.abort') return 125;
  if (reply.error) process.stdout.write(JSON.stringify(reply));
  return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then((code) => process.exit(code), () => process.exit(1));
}
