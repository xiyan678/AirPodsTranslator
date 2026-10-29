import test from 'node:test';
import assert from 'node:assert/strict';
import { createSummaryServer } from './server.mjs';

test('a paired test phone can use Anna without Apple team credentials; anonymous callers cannot', async t => {
  const server = createSummaryServer({ env: { DASHSCOPE_API_KEY: 'fixture-key' },
    deviceVerifier: { configured: false },
    clientAccess: { enabled: true, pair: code => {
      assert.equal(code, '123456ABCDEF'); return { token: 'fixture-client-token', expiresAt: Date.now() + 10000 };
    }, verify: token => token === 'fixture-client-token' },
    speech: { configured: true, synthesize: async () => Buffer.from('anna-mp3') } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const url = 'http://127.0.0.1:' + server.address().port;
  const send = (path, body, token) => fetch(url + path, { method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: JSON.stringify(body) });
  const pair = await send('/v1/client/pair', { code: '123456ABCDEF' });
  assert.equal(pair.status, 200);
  assert.equal((await pair.json()).token, 'fixture-client-token');
  const audio = await send('/v1/speech', { text: '你好', rate: 1 }, 'fixture-client-token');
  assert.equal(audio.status, 200); assert.equal(await audio.text(), 'anna-mp3');
  assert.equal((await send('/v1/speech', { text: '你好', rate: 1 })).status, 401);
  assert.equal((await send('/v1/referrals/status', {}, 'fixture-client-token')).status, 503);
});
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClientAccess, mintPairingCode } from './client-auth.mjs';

function fixture(t, extra = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'paired-client-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  let current = 1800000000000;
  const stateFile = join(directory, 'client-access.json'), pairingFile = join(directory, 'client-pairing.json');
  const options = { env: { CLIENT_PAIRING_ENABLED: '1', ...extra }, stateFile, pairingFile, now: () => current };
  return { options, stateFile, pairingFile, access: () => createClientAccess(options),
    mint: () => mintPairingCode(pairingFile, options.now), advance: time => { current += time; } };
}

test('pairing code is single-use across restart; disk stores credential hashes only', t => {
  const f = fixture(t); let access = f.access();
  const { code } = f.mint();
  const granted = access.pair(code.slice(0, 4) + '-' + code.slice(4, 8) + '-' + code.slice(8));
  assert.match(granted.token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(access.verify(granted.token), true);
  access = f.access();
  assert.equal(access.verify(granted.token), true);
  assert.throws(() => access.pair(code), /已使用/);
  assert.equal(readFileSync(f.stateFile, 'utf8').includes(granted.token), false);
  assert.equal(readFileSync(f.pairingFile, 'utf8').includes(code), false);
});

test('live server sees administrator-generated codes; new code replaces old unused code', t => {
  const f = fixture(t); const access = f.access();
  const first = f.mint(), second = f.mint();
  assert.throws(() => access.pair(first.code), /无效/);
  const granted = access.pair(second.code);
  assert.equal(access.verify(granted.token), true);
});

test('expired codes and client tokens fail closed; per-client hourly budget survives restart', t => {
  const f = fixture(t, { CLIENT_REQUESTS_PER_HOUR: '2', CLIENT_TOKEN_DAYS: '1' });
  let access = f.access(); const first = f.mint();
  f.advance(600001); assert.throws(() => access.pair(first.code), /过期/);
  const { code } = f.mint(); const { token } = access.pair(code);
  assert.equal(access.verify(token), true);
  access = f.access(); assert.equal(access.verify(token), true);
  assert.throws(() => access.verify(token), error => error.status === 429);
  f.advance(3600000); assert.equal(access.verify(token), true);
  f.advance(86400000); assert.equal(access.verify(token), false);
  assert.equal(access.verify('forged-token'), false);
});

test('pairing mode is opt-in and cannot use a valid code while disabled', t => {
  const f = fixture(t); const { code } = f.mint();
  const access = createClientAccess({ ...f.options, env: {} });
  assert.equal(access.enabled, false);
  assert.throws(() => access.pair(code), error => error.status === 503);
  assert.equal(access.verify('x'.repeat(43)), false);
});

test('real HTTP pairing authorizes summary and speech, never anonymous upstream calls or referral rewards', async t => {
  const f = fixture(t); let audioCalls = 0, summaryCalls = 0;
  const { code } = f.mint();
  const server = createSummaryServer({ env: { CLIENT_PAIRING_ENABLED: '1', DASHSCOPE_API_KEY: 'fixture-upstream-key', REQUESTS_PER_DAY: '2' },
    now: f.options.now, stateFile: join(f.stateFile, '../limits.json'), deviceVerifier: { configured: false },
    speech: { configured: true, synthesize: async () => { audioCalls++; return Buffer.from('anna-audio'); } },
    fetchImpl: async (_url, request) => {
      summaryCalls++; assert.equal(request.headers.authorization, 'Bearer fixture-upstream-key');
      return Response.json({ choices: [{ message: { content: '{"keyPoints":["测试要点"],"questions":[],"nextSteps":[]}' } }] });
    } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const base = 'http://127.0.0.1:' + server.address().port;
  const post = (path, body, token) => fetch(base + path, { method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) }, body: JSON.stringify(body) });
  assert.equal((await post('/v1/speech', { text: '你好', rate: 1 })).status, 401);
  assert.equal(audioCalls, 0);
  assert.equal((await post('/v1/client/pair', { code: 'wrong-code' })).status, 401);
  const grant = await post('/v1/client/pair', { code }); assert.equal(grant.status, 200);
  const { token } = await grant.json();
  const audio = await post('/v1/speech', { text: '你好', rate: 1 }, token);
  assert.equal(audio.status, 200); assert.equal(await audio.text(), 'anna-audio');
  assert.equal((await post('/v1/summary', { transcript: '演示内容' }, token)).status, 200);
  assert.equal((await post('/v1/referrals/activate', { code: 'FAKE' }, token)).status, 503);
  assert.equal((await post('/v1/speech', { text: 'over budget', rate: 1 }, token)).status, 429);
  assert.equal(audioCalls, 1); assert.equal(summaryCalls, 1);
  assert.equal((await (await fetch(base + '/v1/speech/health')).json()).configured, true);
});
