// Synthetic public SDK boundary; never reads an installation, store or gateway.
// API shape: OpenClaw v2026.9.6 secret-ref-runtime / secrets/resolve.ts.
import assert from 'node:assert/strict';

export function accessFixture({ scenario = 'store', mode = 'token', source = 'store', diagnostics = false, env: suppliedEnv } = {}) {
  const expected = `synthetic-private-${mode}-${scenario}`;
  const env = suppliedEnv ?? (scenario === 'environment' ? { [`OPENCLAW_GATEWAY_${mode.toUpperCase()}`]: expected } : {});
  const defaults = Object.freeze({ [source]: 'fixture-provider' });
  const ref = Object.freeze({ source, provider: 'default', id: 'GATEWAY_AUTH_FIXTURE' });
  const input = scenario === 'plaintext' ? expected : scenario === 'absent' ? undefined
    : scenario === 'shorthand' ? '$GATEWAY_AUTH_FIXTURE' : scenario === 'default-provider' ? Object.freeze({ source, id: ref.id }) : ref;
  const auth = Object.freeze({ mode, [mode]: input, [mode === 'token' ? 'password' : 'token']: 'unused-synthetic' });
  const config = Object.freeze({ gateway: Object.freeze({ mode: scenario === 'remote' ? 'remote' : 'local', auth }),
    secrets: Object.freeze({ defaults }) });
  const calls = { auth: 0, load: 0, coerce: 0, resolve: 0, connections: 0 };
  function diagnostic() {
    if (diagnostics) for (const method of ['log', 'warn', 'error', 'info', 'debug']) console[method](expected);
  }
  const configSdk = { async readConfigFileSnapshot(options) {
    diagnostic();
    assert.ok(options.observe === false && options.recoverSuspicious === false && options.pluginValidation === 'core-only', 'snapshot must remain read-only');
    if (scenario === 'snapshot-error') throw new Error(expected);
    return { valid: scenario !== 'invalid', config };
  } };
  const sdk = {
    resolveGatewayAuth({ authConfig, env: actualEnv }) {
      calls.auth++;
      assert.ok(authConfig === auth && actualEnv === env, 'auth resolver must receive original inputs');
      const literal = key => typeof authConfig[key] === 'string' && !authConfig[key].startsWith('$') ? authConfig[key].trim() : undefined;
      const token = literal('token') || actualEnv.OPENCLAW_GATEWAY_TOKEN;
      const password = literal('password') || actualEnv.OPENCLAW_GATEWAY_PASSWORD;
      return { mode: authConfig.mode ?? (password ? 'password' : 'token'), token, password };
    },
    isGatewayClientRequestError: error => typeof error.retryable === 'boolean',
    GatewayClient: class {
      constructor(options) {
        calls.connections++;
        // Boolean assertions cannot print the credential when a test fails.
        assert.ok(options[mode] === expected, 'connection must use the exact effective credential');
        assert.ok(options[mode === 'token' ? 'password' : 'token'] === undefined, 'only the selected credential is sent');
        assert.ok(options.sharedStateMode === 'read-only' && options.deviceIdentity === null, 'connection remains read-only');
        this.options = options;
      }
      start() { diagnostic(); this.options.onHelloOk({}); }
      stop() {}
      async request(method) {
        assert.equal(method, 'agents.list');
        if (scenario === 'request-error') throw Object.assign(new Error(expected), { gatewayCode: 'INVALID_REQUEST', retryable: false });
        return { agents: [] };
      }
    },
  };
  const secretSdk = {
    coerceSecretRef(value, actualDefaults) {
      calls.coerce++;
      diagnostic();
      assert.ok(value === input && actualDefaults === defaults, 'coercion must use the selected input and configured defaults');
      if (scenario === 'coerce-error') throw new Error(expected);
      if (scenario === 'invalid-ref') return null;
      if (scenario === 'shorthand') return { source: 'env', provider: defaults.env, id: ref.id };
      if (scenario === 'default-provider') return { ...value, provider: defaults[source] };
      return value === ref ? ref : null;
    },
    async resolveSecretRefValues(refs, options) {
      calls.resolve++;
      diagnostic();
      assert.ok(refs.length === 1 && refs[0].source === (scenario === 'shorthand' ? 'env' : source), 'only the selected reference is resolved');
      assert.ok(options.config === config && options.env === env, 'resolution must receive the snapshot and original environment');
      if (scenario === 'unresolved') throw new Error(expected);
      const key = `${refs[0].source}:${refs[0].provider}:${refs[0].id}`;
      const value = scenario === 'empty' ? '' : scenario === 'blank' ? '  ' : scenario === 'non-string' ? 42 : expected;
      return scenario === 'missing' ? new Map() : new Map([[key, value]]);
    },
  };
  const loadSecretsSdk = async () => {
    calls.load++;
    if (scenario === 'import-error') throw new Error(expected);
    return secretSdk;
  };
  return { sdk, configSdk, secretSdk, loadSecretsSdk, env, calls, expected, diagnostic };
}
