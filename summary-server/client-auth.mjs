import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

export class ClientAccessError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const hash = value => createHash('sha256').update(value).digest('hex');
function atomicWrite(file, value) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const temporary = file + '.' + randomBytes(8).toString('hex') + '.tmp';
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  renameSync(temporary, file);
}
// The administrative command writes a separate grant file, so a running server sees
// new codes without sharing mutable session state with another process.
export function mintPairingCode(file, now = Date.now) {
  const code = randomBytes(6).toString('hex').toUpperCase();
  const expiresAt = now() + 10 * 60000;
  atomicWrite(file, { codeHash: hash(code), expiresAt });
  return { code, expiresAt };
}
export function createClientAccess({ env = process.env, now = Date.now, stateFile = null, pairingFile = null } = {}) {
  const enabled = env.CLIENT_PAIRING_ENABLED === '1' && Boolean(stateFile && pairingFile);
  let state = { version: 1, sessions: {}, consumedCodes: {} };
  if (enabled && existsSync(stateFile)) {
    state = JSON.parse(readFileSync(stateFile, 'utf8'));
    if (state.version !== 1 || !state.sessions || !state.consumedCodes) throw new Error('Invalid paired client state');
    for (const [digest, session] of Object.entries(state.sessions)) {
      if (!/^[a-f0-9]{64}$/.test(digest) || !Number.isFinite(session.expiresAt) ||
          !Number.isSafeInteger(session.requests) || !Number.isSafeInteger(session.hour)) throw new Error('Invalid paired client');
    }
  }
  const limit = Number(env.CLIENT_REQUESTS_PER_HOUR || 600);
  const days = Number(env.CLIENT_TOKEN_DAYS || 90);
  if (!Number.isSafeInteger(limit) || limit < 1 || !Number.isSafeInteger(days) || days < 1 || days > 365) {
    throw new Error('Invalid client access limits');
  }
  function cleanup() {
    for (const [key, value] of Object.entries(state.sessions)) if (value.expiresAt <= now()) delete state.sessions[key];
    for (const [key, expiresAt] of Object.entries(state.consumedCodes)) if (expiresAt <= now()) delete state.consumedCodes[key];
  }
  function commit(action) {
    const previous = structuredClone(state);
    try { action(); atomicWrite(stateFile, state); }
    catch (error) { state = previous; throw error; }
  }
  return {
    enabled,
    pair(input) {
      if (!enabled) throw new ClientAccessError(503, '连接码功能尚未启用');
      const code = typeof input === 'string' ? input.trim().replaceAll('-', '').toUpperCase() : '';
      if (!/^[A-F0-9]{12}$/.test(code)) throw new ClientAccessError(401, '连接码无效或已过期');
      let grant;
      try { grant = JSON.parse(readFileSync(pairingFile, 'utf8')); }
      catch { throw new ClientAccessError(401, '请先在服务器生成连接码'); }
      const digest = hash(code);
      if (!/^[a-f0-9]{64}$/.test(grant.codeHash || '') || !Number.isFinite(grant.expiresAt) || grant.expiresAt <= now() ||
          !timingSafeEqual(Buffer.from(digest, 'hex'), Buffer.from(grant.codeHash, 'hex')) || state.consumedCodes[digest]) {
        throw new ClientAccessError(401, '连接码无效、已使用或已过期');
      }
      cleanup();
      if (Object.keys(state.sessions).length >= 128) throw new ClientAccessError(503, '测试设备数量已达到上限');
      const token = randomBytes(32).toString('base64url');
      const expiresAt = now() + days * 86400000;
      commit(() => {
        state.consumedCodes[digest] = grant.expiresAt;
        state.sessions[hash(token)] = { expiresAt, hour: Math.floor(now() / 3600000), requests: 0 };
      });
      return { token, expiresAt };
    },
    verify(token) {
      if (!enabled || typeof token !== 'string' || !/^[a-zA-Z0-9_-]{43}$/.test(token)) return false;
      const session = state.sessions[hash(token)];
      if (!session || session.expiresAt <= now()) return false;
      const hour = Math.floor(now() / 3600000);
      const count = session.hour === hour ? session.requests : 0;
      if (count >= limit) throw new ClientAccessError(429, '此设备请求较多，请稍后重试');
      commit(() => { session.hour = hour; session.requests = count + 1; });
      return true;
    }
  };
}
