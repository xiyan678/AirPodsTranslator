import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDeviceVerifier } from './device-check.mjs';
import { createSummaryServer, parseOutline } from './server.mjs';

const outline = { keyPoints: ['周五发布新版本'], questions: [], nextSteps: ['小王周四完成测试'] };
const success = () => Response.json({ choices: [{ message: { content: JSON.stringify(outline) } }] });
async function start(t, options = {}) {
  const server = createSummaryServer({ deviceVerifier: { configured: true, verify: async () => true }, ...options,
    env: { DASHSCOPE_API_KEY: 'test-key', ...options.env } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return 'http://127.0.0.1:' + server.address().port;
}
const send = (url, body, headers = {}) => fetch(url + '/v1/summary', {
  method: 'POST', headers: { 'content-type': 'application/json', 'x-device-token': randomBytes(32).toString('base64'), ...headers }, body: JSON.stringify(body)
});

test('anonymous, invalid and replayed device credentials never reach the model', async t => {
  let calls = 0;
  const invalid = randomBytes(32).toString('base64');
  const url = await start(t, { deviceVerifier: { configured: true, verify: async token => token !== invalid },
    fetchImpl: async () => { calls++; return success(); } });
  assert.equal((await send(url, { transcript: 'anonymous' }, { 'x-device-token': '' })).status, 401);
  assert.equal((await send(url, { transcript: 'invalid' }, { 'x-device-token': invalid })).status, 401);
  const token = randomBytes(32).toString('base64');
  const replies = await Promise.all([1, 2].map(() => send(url, { transcript: 'hello' }, { 'x-device-token': token })));
  assert.deepEqual(replies.map(r => r.status).sort(), [200, 401]);
  assert.equal(calls, 1);
});

test('unconfigured or unavailable device verification fails closed', async t => {
  for (const verifier of [{ configured: false }, { configured: true, verify: async () => { throw new Error('private'); } }]) {
    const url = await start(t, { deviceVerifier: verifier, fetchImpl: async () => assert.fail('model called') });
    assert.equal((await send(url, { transcript: 'test' })).status, 503);
  }
});

test('restart preserves daily quotas and consumed device tokens', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'summary-limits-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const options = { stateFile: join(directory, 'limits.json'), env: { REQUESTS_PER_DAY: '2' }, fetchImpl: async () => success() };
  const first = await start(t, options);
  const token = randomBytes(32).toString('base64');
  assert.equal((await send(first, { transcript: 'first' }, { 'x-device-token': token })).status, 200);
  const restarted = await start(t, options);
  assert.equal((await send(restarted, { transcript: 'replayed' }, { 'x-device-token': token })).status, 401);
  assert.equal((await send(restarted, { transcript: 'second' })).status, 200);
  const third = await start(t, options);
  assert.equal((await send(third, { transcript: 'over cap' })).status, 429);
});

test('anonymous attempts do not drain the shared model quota', async t => {
  const url = await start(t, { env: { REQUESTS_PER_DAY: '1' }, fetchImpl: async () => success() });
  assert.equal((await send(url, { transcript: 'anonymous' }, { 'x-device-token': '' })).status, 401);
  assert.equal((await send(url, { transcript: 'valid user' })).status, 200);
  assert.equal((await send(url, { transcript: 'over quota' })).status, 429);
});

test('DeviceCheck sends a valid ES256 JWT and no transcript to Apple', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'device-check-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const keyFile = join(directory, 'key.p8');
  writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  let calls = 0;
  const validator = createDeviceVerifier({ DEVICECHECK_KEY_FILE: keyFile, APPLE_TEAM_ID: 'TESTTEAM', DEVICECHECK_KEY_ID: 'TESTKEY' },
    async (url, request) => {
      calls++;
      assert.equal(url, 'https://api.devicecheck.apple.com/v1/validate_device_token');
      const [header, payload, signature] = request.headers.authorization.slice(7).split('.');
      assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'ES256');
      assert.equal(JSON.parse(Buffer.from(payload, 'base64url')).iss, 'TESTTEAM');
      assert.ok(verify('sha256', Buffer.from(header + '.' + payload), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
      assert.deepEqual(Object.keys(JSON.parse(request.body)).sort(), ['device_token', 'timestamp', 'transaction_id']);
      return new Response('', { status: 200 });
    });
  assert.equal(await validator.verify('test-token'), true);
  assert.equal(calls, 1);
});

test('summarizes into three sections using only the server key and model', async t => {
  let upstream;
  const url = await start(t, { fetchImpl: async (url, request) => { upstream = request; return success(); } });
  const response = await send(url, { transcript: '周五发布，小王周四完成测试', model: 'evil', apiKey: 'client-key' });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), outline);
  assert.equal(upstream.headers.authorization, 'Bearer test-key');
  assert.equal(JSON.parse(upstream.body).model, 'qwen-plus');
  assert.equal(JSON.parse(upstream.body).messages.length, 2);
});

test('merges prior points with new content without losing the original facts', async t => {
  let payload;
  const url = await start(t, { fetchImpl: async (_, request) => { payload = JSON.parse(request.body); return success(); } });
  await send(url, { transcript: '负责人是小王', previousSummary: '周五发布新版本' });
  assert.match(payload.messages[1].content, /周五发布新版本/);
  assert.match(payload.messages[1].content, /负责人是小王/);
});

test('invalid input never reaches the model', async t => {
  let calls = 0;
  const url = await start(t, { fetchImpl: async () => { calls++; return success(); } });
  for (const body of [null, {}, { transcript: ' ' }, { transcript: 42 }, { transcript: 'ok', previousSummary: {} }]) {
    assert.equal((await send(url, body)).status, 400);
  }
  assert.equal(calls, 0);
});

test('does not expose credentials or upstream error bodies', async t => {
  const url = await start(t, { fetchImpl: async () => new Response('credential test-key private-account', { status: 401 }) });
  const response = await send(url, { transcript: 'hello' });
  assert.equal(response.status, 502);
  assert.doesNotMatch(await response.text(), /test-key|private-account/);
});

test('rate limits requests; spoofing forwarded-for cannot bypass the limit', async t => {
  const url = await start(t, { env: { REQUESTS_PER_IP_HOUR: '1' }, fetchImpl: async () => success() });
  assert.equal((await send(url, { transcript: 'first' })).status, 200);
  assert.equal((await send(url, { transcript: 'second' }, { 'x-forwarded-for': '203.0.113.123' })).status, 429);
});

test('daily cap resets on the next UTC day', async t => {
  let time = Date.UTC(2026, 9, 29);
  const url = await start(t, { env: { REQUESTS_PER_DAY: '1' }, now: () => time, fetchImpl: async () => success() });
  assert.equal((await send(url, { transcript: 'first' })).status, 200);
  assert.equal((await send(url, { transcript: 'second' })).status, 429);
  time += 86400000;
  assert.equal((await send(url, { transcript: 'third' })).status, 200);
});

test('missing credentials reports unconfigured without contacting a model', async t => {
  const url = await start(t, { env: { DASHSCOPE_API_KEY: '' }, fetchImpl: async () => { assert.fail('unexpected model call'); } });
  assert.deepEqual(await (await fetch(url + '/health')).json(), { ok: true, configured: false });
  assert.equal((await send(url, { transcript: 'hello' })).status, 503);
});

test('parses fenced JSON, removes duplicate points, preserves absent tasks as empty arrays', () => {
  assert.deepEqual(parseOutline('```json\n' + JSON.stringify({ keyPoints: [' 要点 ', '要点'], questions: [], nextSteps: [] }) + '\n```'),
    { keyPoints: ['要点'], questions: [], nextSteps: [] });
  for (const bad of ['null', '{}', '{"keyPoints":[1]}', '{"keyPoints":[],"questions":[],"nextSteps":[]}']) {
    assert.throws(() => parseOutline(bad));
  }
});

test('DeviceCheck handles a new device with no bits and updates only the reserved activity bit', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'device-bits-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const keyFile = join(directory, 'key.p8');
  writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  let response = new Response('Bit State Not Found', { status: 200 });
  const verifier = createDeviceVerifier({ DEVICECHECK_KEY_FILE: keyFile, APPLE_TEAM_ID: 'TEAM', DEVICECHECK_KEY_ID: 'KEY' },
    async (url, request) => {
      if (url.endsWith('/update_two_bits')) {
        const body = JSON.parse(request.body);
        assert.equal(body.bit0, true); assert.equal(body.bit1, undefined);
        return new Response('', { status: 200 });
      }
      return response;
    });
  assert.deepEqual(await verifier.queryBits('phone'), { bit0: false, bit1: false });
  response = new Response('', { status: 200, statusText: 'Bit State Not Found' });
  assert.deepEqual(await verifier.queryBits('phone'), { bit0: false, bit1: false });
  response = Response.json({ bit0: true, bit1: true });
  assert.deepEqual(await verifier.queryBits('phone'), { bit0: true, bit1: true });
  await verifier.updateBits('phone', { bit0: true });
  response = new Response('unexpected error', { status: 200 });
  await assert.rejects(verifier.queryBits('phone'));
});

test('invitation API requires fresh Apple credentials and does not consume speech or summary daily quota', async t => {
  let calls = 0;
  const url = await start(t, { env: { REQUESTS_PER_DAY: '1' }, fetchImpl: async () => success(),
    referrals: { handle: async (action, body) => { calls++; assert.equal(action, 'status'); assert.equal(body.test, true); return { rewardDays: 0 }; } } });
  const request = token => fetch(url + '/v1/referrals/status', {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-device-token': token }, body: JSON.stringify({ test: true })
  });
  assert.equal((await request('')).status, 401);
  assert.equal(calls, 0);
  const token = randomBytes(32).toString('base64');
  assert.equal((await request(token)).status, 200);
  assert.equal((await request(token)).status, 401);
  assert.equal((await send(url, { transcript: 'still within model quota' })).status, 200);
  assert.equal((await request(randomBytes(32).toString('base64'))).status, 200);
  assert.equal(calls, 2);
});
