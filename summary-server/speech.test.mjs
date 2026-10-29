import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { randomBytes } from 'node:crypto';
import { createSpeechSynthesizer } from './speech.mjs';
import { createSummaryServer } from './server.mjs';

const env = { DASHSCOPE_API_KEY: 'private-test-key', DASHSCOPE_WORKSPACE_ID: 'ws-test' };
function fixture() {
  const socket = new EventEmitter();
  const sent = [];
  socket.send = data => sent.push(JSON.parse(data));
  socket.terminate = () => {};
  const speech = createSpeechSynthesizer(env, (url, options) => {
    assert.equal(url, 'wss://ws-test.workspace.dashscope.aliyuncs.com/api-ws/v1/inference');
    assert.equal(options.headers.Authorization, 'Bearer private-test-key');
    return socket;
  });
  const event = name => socket.emit('message', Buffer.from(JSON.stringify({ header: { event: name, task_id: sent[0].header.task_id } })), false);
  return { speech, socket, sent, event };
}
test('speech waits for final completion and keeps all audio chunks in order', async () => {
  const f = fixture();
  const result = f.speech.synthesize('你好，欢迎使用声译。', 1);
  f.socket.emit('open');
  assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].payload.model, 'cosyvoice-v3.5-plus');
  assert.equal(f.sent[0].payload.parameters.voice, 'cosyvoice-v3.5-plus-bailian-20fde1dbc7b04884862ee1b54a2c128f');
  f.event('task-started');
  assert.deepEqual(f.sent.map(v => v.header.action), ['run-task', 'continue-task', 'finish-task']);
  assert.equal(f.sent[1].payload.input.text, '你好，欢迎使用声译。');
  f.socket.emit('message', Buffer.from('first'), true);
  let resolved = false; result.then(() => { resolved = true; });
  await Promise.resolve(); assert.equal(resolved, false);
  f.socket.emit('message', Buffer.from('last'), true);
  f.event('task-finished');
  assert.equal((await result).toString(), 'firstlast');
});
test('speech rejects empty, truncated, malformed or failed responses', async () => {
  for (const failure of ['empty', 'close', 'invalid', 'failed', 'early-audio', 'wrong-task']) {
    const f = fixture(); const pending = f.speech.synthesize('test', 1);
    const rejected = assert.rejects(pending, error => !error.message.includes('private-test-key'));
    f.socket.emit('open');
    if (failure === 'early-audio') f.socket.emit('message', Buffer.from('audio'), true);
    else if (failure === 'wrong-task') f.socket.emit('message', Buffer.from('{"header":{"task_id":"wrong"}}'), false);
    else {
      f.event('task-started');
      if (failure === 'empty') f.event('task-finished');
      if (failure === 'close') f.socket.emit('close');
      if (failure === 'invalid') f.socket.emit('message', Buffer.from('not json'), false);
      if (failure === 'failed') f.event('task-failed');
    }
    await rejected;
  }
});
test('cancel prevents later cloud audio from completing the request', async () => {
  const f = fixture(); const controller = new AbortController();
  const result = f.speech.synthesize('test', 1, controller.signal);
  const rejected = assert.rejects(result, /cancelled/);
  f.socket.emit('open'); controller.abort();
  f.event('task-started'); f.socket.emit('message', Buffer.from('late'), true); f.event('task-finished');
  await rejected;
  assert.equal(f.sent.length, 1);
});
test('speech HTTP endpoint authenticates and validates before invoking the provider', async t => {
  let calls = 0;
  const server = createSummaryServer({ env: {}, deviceVerifier: { configured: true, verify: async () => true },
    speech: { configured: true, synthesize: async (text, rate) => { calls++; assert.equal(text, '你好'); assert.equal(rate, 1); return Buffer.from('mp3-test'); } } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const send = (body, token = randomBytes(32).toString('base64')) => fetch('http://127.0.0.1:' + server.address().port + '/v1/speech', {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-device-token': token }, body: JSON.stringify(body)
  });
  assert.equal((await send({ text: '你好', rate: 1 }, '')).status, 401);
  for (const body of [{ text: '', rate: 1 }, { text: '你好', rate: 5 }, { text: '你好', rate: '1' }, { text: 'x'.repeat(2001), rate: 1 }]) {
    assert.equal((await send(body)).status, 400);
  }
  assert.equal(calls, 0);
  const reply = await send({ text: '你好', rate: 1, voice: 'untrusted-voice' });
  assert.equal(reply.status, 200); assert.equal(reply.headers.get('content-type'), 'audio/mpeg');
  assert.equal(await reply.text(), 'mp3-test'); assert.equal(calls, 1);
});

test('synchronous socket send failure rejects instead of crashing the server', async () => {
  const f = fixture(); f.socket.send = () => { throw new Error('private transport failure'); };
  const result = f.speech.synthesize('test', 1);
  const rejected = assert.rejects(result, /Speech send failed/);
  f.socket.emit('open');
  await rejected;
});
