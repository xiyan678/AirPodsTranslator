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
  async function call(path, token, extra = {}) {
    if (!configured) throw new Error('DeviceCheck not configured');
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = encode({ alg: 'ES256', kid: env.DEVICECHECK_KEY_ID, typ: 'JWT' }) + '.' +
      encode({ iss: env.APPLE_TEAM_ID, iat: Math.floor(now() / 1000) });
    const signature = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    const host = env.DEVICECHECK_ENVIRONMENT === 'development'
      ? 'https://api.development.devicecheck.apple.com' : 'https://api.devicecheck.apple.com';
    return fetchImpl(host + '/v1/' + path, {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${input}.${signature}` },
      body: JSON.stringify({ device_token: token, transaction_id: randomUUID(), timestamp: now(), ...extra }),
      signal: AbortSignal.timeout(10000)
    });
  }
  return {
    configured,
    async verify(token) {
      if (!configured) return false;
      const result = await call('validate_device_token', token);
      if (result.status !== 200 && result.status !== 400) throw new Error('DeviceCheck unavailable');
      return result.status === 200;
    },
    async queryBits(token) {
      const result = await call('query_two_bits', token);
      if (result.status !== 200) throw new Error('DeviceCheck unavailable');
      const text = await result.text();
      if (text.trim() === 'Bit State Not Found' || (!text.trim() && result.statusText === 'Bit State Not Found')) {
        return { bit0: false, bit1: false };
      }
      const bits = JSON.parse(text);
      if (typeof bits.bit0 !== 'boolean' || typeof bits.bit1 !== 'boolean') throw new Error('Invalid device bits');
      return bits;
    },
    async updateBits(token, bits) {
      const result = await call('update_two_bits', token, bits);
      if (result.status !== 200) throw new Error('DeviceCheck unavailable');
    }
  };
}
