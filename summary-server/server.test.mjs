import test from 'node:test';
import assert from 'node:assert/strict';
import { createSummaryServer, parseOutline } from './server.mjs';

const outline = { keyPoints: ['周五发布新版本'], questions: [], nextSteps: ['小王周四完成测试'] };
const success = () => Response.json({ choices: [{ message: { content: JSON.stringify(outline) } }] });
async function start(t, options = {}) {
  const server = createSummaryServer({ ...options,
    env: { DASHSCOPE_API_KEY: 'test-key', ...options.env } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return 'http://127.0.0.1:' + server.address().port;
}
const send = (url, body, headers = {}) => fetch(url + '/v1/summary', {
  method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body)
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
