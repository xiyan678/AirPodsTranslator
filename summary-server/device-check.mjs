import { createPrivateKey, randomUUID, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

// The .p8 key belongs on the server only. Never include it in the iOS bundle.
export function createDeviceVerifier(env, fetchImpl = fetch, now = Date.now) {
  let key;
  if (env.DEVICECHECK_KEY_FILE) key = createPrivateKey(readFileSync(env.DEVICECHECK_KEY_FILE));
  const configured = Boolean(key && env.APPLE_TEAM_ID && env.DEVICECHECK_KEY_ID);
  if (key && (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1')) {
    throw new Error('DeviceCheck requires an ES256 private key');
  }
  return {
    configured,
    async verify(token) {
      if (!configured) return false;
      const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
      const input = encode({ alg: 'ES256', kid: env.DEVICECHECK_KEY_ID, typ: 'JWT' }) + '.' +
        encode({ iss: env.APPLE_TEAM_ID, iat: Math.floor(now() / 1000) });
      const signature = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      const host = env.DEVICECHECK_ENVIRONMENT === 'development'
        ? 'https://api.development.devicecheck.apple.com' : 'https://api.devicecheck.apple.com';
      const result = await fetchImpl(host + '/v1/validate_device_token', {
        method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${input}.${signature}` },
        body: JSON.stringify({ device_token: token, transaction_id: randomUUID(), timestamp: now() }),
        signal: AbortSignal.timeout(10000)
      });
      // Apple authentication failures are server configuration errors, not invalid clients.
      if (result.status !== 200 && result.status !== 400) throw new Error('DeviceCheck unavailable');
      return result.status === 200;
    }
  };
}
