import assert from 'node:assert/strict';
import { localAccess, ownerConnection, wireReply } from '../../../scripts/openclaw-owner-rpc.mjs';
import { accessFixture } from './owner-access-fixture.mjs';

const args = ['gateway', 'call', 'agents.list', '--params', '{}', '--json'];
for (const mode of ['token', 'password']) {
  for (const scenario of ['plaintext', 'environment', 'store', 'default-provider', 'unresolved', 'missing', 'empty', 'blank', 'non-string',
    'import-error', 'coerce-error', 'invalid-ref', 'absent', 'invalid', 'remote', 'request-error']) {
    const fixture = accessFixture({ scenario, mode });
    const access = await localAccess(fixture.sdk, fixture.configSdk, fixture.env, fixture.loadSecretsSdk);
    const connection = ownerConnection(fixture.sdk, access);
    const result = await connection.request('agents.list', {});
    const wire = wireReply(args, result);
    connection.close();
    assert.ok(!JSON.stringify({ result, wire }).includes(fixture.expected), 'transport replies must not contain credentials');
    const available = ['plaintext', 'environment', 'store', 'default-provider', 'request-error'].includes(scenario);
    assert.equal(wire.code, available ? scenario === 'request-error' ? 1 : 0 : 124, `${mode}/${scenario}: credential result`);
    assert.equal(fixture.calls.connections, available ? 1 : 0);
    assert.equal(fixture.calls.auth, ['invalid', 'remote'].includes(scenario) ? 0 : 1);
    if (['plaintext', 'environment', 'invalid', 'remote', 'absent'].includes(scenario)) assert.equal(fixture.calls.load, 0);
    if (['unresolved', 'missing', 'empty', 'blank', 'non-string'].includes(scenario)) assert.equal(fixture.calls.resolve, 1);
    if (!available) { assert.equal(access, null); assert.equal(result.reason, 'credentials_unavailable'); assert.equal(wire.output, ''); }
  }
  for (const source of ['env', 'file', 'exec']) {
    const fixture = accessFixture({ source, mode });
    const access = await localAccess(fixture.sdk, fixture.configSdk, fixture.env, fixture.loadSecretsSdk);
    assert.ok(access?.[mode] === fixture.expected, 'all SDK reference sources are delegated');
  }
  const shorthand = accessFixture({ scenario: 'shorthand', mode, source: 'env' });
  const access = await localAccess(shorthand.sdk, shorthand.configSdk, shorthand.env, shorthand.loadSecretsSdk);
  assert.ok(access?.[mode] === shorthand.expected, 'SDK env shorthand is delegated');
}
for (const mode of ['none', 'trusted-proxy']) {
  const fixture = accessFixture({ mode });
  assert.equal(await localAccess(fixture.sdk, fixture.configSdk, fixture.env, fixture.loadSecretsSdk), null);
  assert.equal(fixture.calls.load, 0);
}
console.log('PASS: local SecretRefs, exact owner credential, environment precedence and fail-closed access');
