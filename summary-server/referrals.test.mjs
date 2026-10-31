import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createReferralService, createPurchaseVerifier } from './referrals.mjs';
const identity = () => ({ installationID: randomUUID(), installationSecret: randomUUID() + randomUUID() });
function fixture(file = null) {
  let now = 1800000000000;
  const bits = new Map();
  const service = () => createReferralService({ file, now: () => now,
    deviceVerifier: {
      queryBits: async token => bits.get(token) || { bit0: false, bit1: true },
      updateBits: async (token, value) => { assert.equal(value.bit1, undefined); bits.set(token, { ...bits.get(token), ...value }); }
    }, purchaseVerifier: { verify: async tx => JSON.parse(tx) } });
  return { service, bits, advance: days => { now += days * 86400000; }, now: () => now };
}

test('malformed installation identity returns a client error and leaves the queue usable', async () => {
  const api = fixture().service();
  for (const installationID of [1, true, [], {}, null]) {
    await assert.rejects(api.handle('status', { ...identity(), installationID }),
      error => error.status === 400 && /身份无效/.test(error.message));
  }
  assert.equal((await api.handle('status', identity())).activated, false);
});
test('activation grants both one day; concurrent retries and restart do not duplicate rewards', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'referral-test-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture(join(dir, 'referrals.json')); let api = f.service();
  const inviter = identity(), friend = identity();
  const { code } = await api.handle('generate', inviter);
  assert.match(code, /^[A-F0-9]{10}$/);
  assert.equal((await api.handle('generate', inviter)).code, code);
  const results = await Promise.all([1, 2].map(() => api.handle('activate', { ...friend, code }, 'phone-one')));
  for (const result of results) assert.equal(result.rewardDays, 1);
  let stats = await api.handle('status', inviter);
  assert.equal(stats.friendsActivated, 1); assert.equal(stats.rewardDays, 1);
  assert.equal(stats.rewardExpiresAt, f.now() + 86400000);
  api = f.service();
  assert.equal((await api.handle('activate', { ...friend, code }, 'phone-one')).rewardDays, 1);
  assert.equal((await api.handle('status', inviter)).friendsActivated, 1);
  f.advance(2);
  stats = await api.handle('status', inviter);
  assert.ok(stats.rewardExpiresAt < stats.serverTime);
});
test('rejects self referral, invalid code, spoofed installation secret and second redemption on a phone', async () => {
  const f = fixture(); const api = f.service(); const owner = identity(), a = identity(), b = identity();
  const { code } = await api.handle('generate', owner);
  await assert.rejects(api.handle('activate', { ...owner, code }, 'owner'), /自己/);
  await assert.rejects(api.handle('activate', { ...a, code: 'NOPE' }, 'a'), /不存在/);
  await assert.rejects(api.handle('status', { ...owner, installationSecret: identity().installationSecret }), /身份验证/);
  await api.handle('activate', { ...a, code }, 'same-phone');
  await assert.rejects(api.handle('activate', { ...b, code }, 'same-phone'), /已领取/);
});
test('first real paid transaction awards three days once; sandbox, free trial, revoked and foreign proofs fail closed', async () => {
  const f = fixture(); const api = f.service(); const owner = identity(), friend = identity();
  const { code } = await api.handle('generate', owner);
  await api.handle('activate', { ...friend, code }, 'friend');
  const transaction = { environment: 'Production', bundleId: 'com.example.AirPodsTranslator',
    appAccountToken: friend.installationID, type: 'Auto-Renewable Subscription',
    productId: 'com.example.AirPodsTranslator.pro.monthly', originalTransactionId: 'apple-original-1',
    purchaseDate: f.now(), originalPurchaseDate: f.now(), expiresDate: f.now() + 30 * 86400000, price: 68000 };
  for (const invalid of [{ environment: 'Sandbox' }, { appAccountToken: owner.installationID }, { price: 0 },
    { originalPurchaseDate: f.now() - 1 }, { offerDiscountType: 'FREE_TRIAL' }, { revocationDate: f.now() }, { expiresDate: f.now() - 1 }, { bundleId: 'another.app' }]) {
    await assert.rejects(api.handle('purchase', { ...friend, signedTransaction: JSON.stringify({ ...transaction, ...invalid }) }), /条件/);
  }
  await Promise.all([1, 2].map(() => api.handle('purchase', { ...friend, signedTransaction: JSON.stringify(transaction) })));
  const stats = await api.handle('status', owner);
  assert.equal(stats.friendsSubscribed, 1); assert.equal(stats.rewardDays, 4);
  assert.equal(stats.rewardExpiresAt, f.now() + 4 * 86400000);
  assert.equal((await api.handle('status', friend)).rewardDays, 1);
  await assert.rejects(createPurchaseVerifier({}).verify('untrusted-proof'), /尚未配置/);
});
test('interrupted Apple activation can resume without losing or doubling reward', async () => {
  const f = fixture(); const owner = identity(), friend = identity(); let fails = true;
  const deviceVerifier = { queryBits: async () => ({ bit0: false, bit1: false }),
    updateBits: async () => { if (fails) throw new Error('Apple unavailable'); } };
  const api = createReferralService({ deviceVerifier, purchaseVerifier: {}, now: f.now });
  const { code } = await api.handle('generate', owner);
  await assert.rejects(api.handle('activate', { ...friend, code }, 'phone'), /unavailable/);
  assert.equal((await api.handle('status', owner)).rewardDays, 0);
  fails = false;
  await api.handle('activate', { ...friend, code }, 'phone');
  assert.equal((await api.handle('status', owner)).rewardDays, 1);
});
