import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { SignedDataVerifier, Environment } from '@apple/app-store-server-library';

export class ReferralError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export function createPurchaseVerifier(env) {
  let verifier;
  if (env.APPLE_ROOT_CERT_FILES && env.APPLE_BUNDLE_ID && Number(env.APPLE_APP_ID) > 0) {
    const roots = env.APPLE_ROOT_CERT_FILES.split(',').map(path => readFileSync(path.trim()));
    verifier = new SignedDataVerifier(roots, true, Environment.PRODUCTION, env.APPLE_BUNDLE_ID, Number(env.APPLE_APP_ID));
  }
  return { configured: Boolean(verifier), async verify(jws) {
    if (!verifier) throw new ReferralError(503, '订阅奖励核验尚未配置');
    return verifier.verifyAndDecodeTransaction(jws);
  }};
}
const DAY = 86400000;
const hash = value => createHash('sha256').update(value).digest('hex');

// Single-process ledger. Serialise activation and purchase operations across Apple awaits.
export function createReferralService({ file = null, now = Date.now, deviceVerifier,
  purchaseVerifier, bundleID = 'com.example.AirPodsTranslator' }) {
  let state = { version: 1, users: {}, transactions: {} };
  if (file && existsSync(file)) {
    state = JSON.parse(readFileSync(file, 'utf8'));
    if (state.version !== 1 || !state.users || !state.transactions) throw new Error('Invalid referral ledger');
  }
  let tail = Promise.resolve();
  function save() {
    if (!file) return;
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    writeFileSync(file + '.tmp', JSON.stringify(state), { mode: 0o600 });
    renameSync(file + '.tmp', file);
  }
  function commit(action) {
    const previous = structuredClone(state);
    try { action(); save(); } catch (error) { state = previous; throw error; }
  }
  function status(user) {
    return { code: user.code, activated: Boolean(user.inviter), friendsActivated: user.activations,
      friendsSubscribed: user.subscriptions, rewardDays: user.rewardDays,
      rewardExpiresAt: user.expires, serverTime: now() };
  }
  function award(user, days) {
    user.expires = Math.max(now(), user.expires) + days * DAY;
    user.rewardDays += days;
  }
  async function handle(action, body, token) {
    const id = body?.installationID?.toLowerCase(), secret = body?.installationSecret;
    if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id) ||
        typeof secret !== 'string' || !/^[a-zA-Z0-9-]{64,128}$/.test(secret)) {
      throw new ReferralError(400, '设备身份无效');
    }
    let user = state.users[id];
    if (user && !timingSafeEqual(Buffer.from(user.secretHash, 'hex'), Buffer.from(hash(secret), 'hex'))) {
      throw new ReferralError(401, '设备身份验证失败');
    }
    if (!user) {
      if (Object.keys(state.users).length >= 100000) throw new ReferralError(503, '服务繁忙');
      commit(() => { state.users[id] = { secretHash: hash(secret), code: null, inviter: null,
        activations: 0, subscriptions: 0, rewardDays: 0, expires: 0, createdAt: now(), pending: null }; });
      user = state.users[id];
    }
    if (action === 'status') return status(user);
    if (action === 'generate') {
      if (!user.code) {
        let code;
        do { code = randomBytes(5).toString('hex').toUpperCase(); }
        while (Object.values(state.users).some(value => value.code === code));
        commit(() => { user.code = code; });
      }
      return status(user);
    }
    if (action === 'activate') {
      const code = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
      const entry = Object.entries(state.users).find(([, value]) => value.code && value.code === code);
      if (!entry) throw new ReferralError(400, '邀请码不存在');
      const [inviterID, inviter] = entry;
      if (inviterID === id) throw new ReferralError(400, '不能激活自己的邀请码');
      if (user.inviter === inviterID) return status(user); // retry after a lost HTTP response
      if (user.inviter) throw new ReferralError(409, '你已经激活过邀请码');
      if (!deviceVerifier.queryBits || !deviceVerifier.updateBits) throw new ReferralError(503, '活动设备核验尚未配置');
      if (user.pending && user.pending !== inviterID) throw new ReferralError(409, '上次激活仍在处理中');
      const bits = await deviceVerifier.queryBits(token);
      if (bits.bit0 && !user.pending) throw new ReferralError(409, '此设备已领取过激活奖励');
      if (!user.pending) commit(() => { user.pending = inviterID; });
      if (!bits.bit0) await deviceVerifier.updateBits(token, { bit0: true });
      // Pending record is durable before the Apple update, so retries can finish an interrupted activation.
      commit(() => {
        user.inviter = inviterID; user.activatedAt = now(); user.pending = null;
        inviter.activations++;
        award(user, 1); award(inviter, 1);
      });
      return status(user);
    }
    if (action === 'purchase') {
      if (!user.inviter) return status(user);
      if (typeof body.signedTransaction !== 'string' || body.signedTransaction.length > 30000) {
        throw new ReferralError(400, '缺少苹果交易凭证');
      }
      let transaction;
      try { transaction = await purchaseVerifier.verify(body.signedTransaction); }
      catch (error) { if (error instanceof ReferralError) throw error; throw new ReferralError(400, '苹果交易验证失败'); }
      const tx = transaction;
      if (tx.environment !== 'Production' || tx.bundleId !== bundleID ||
          tx.appAccountToken?.toLowerCase() !== id || tx.type !== 'Auto-Renewable Subscription' ||
          ![bundleID + '.pro.monthly', bundleID + '.pro.yearly'].includes(tx.productId) ||
          !tx.originalTransactionId || !Number.isFinite(tx.purchaseDate) || tx.purchaseDate < user.activatedAt ||
          !Number.isFinite(tx.originalPurchaseDate) || tx.originalPurchaseDate < user.activatedAt ||
          !Number.isFinite(tx.expiresDate) || tx.expiresDate <= now() || tx.revocationDate != null ||
          !(tx.price > 0) || tx.offerDiscountType === 'FREE_TRIAL') {
        throw new ReferralError(400, '此交易不符合首次付费订阅奖励条件');
      }
      if (state.transactions[tx.originalTransactionId] || user.paidReward) return status(user);
      commit(() => {
        state.transactions[tx.originalTransactionId] = id;
        user.paidReward = true;
        const inviter = state.users[user.inviter];
        inviter.subscriptions++; award(inviter, 3);
      });
      return status(user);
    }
    throw new ReferralError(404, '活动接口不存在');
  }
  return { handle(action, body, token) {
    const work = tail.then(() => handle(action, body, token));
    tail = work.catch(() => {});
    return work;
  }};
}
