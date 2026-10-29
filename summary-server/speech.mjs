import WebSocket from 'ws';
import { randomUUID } from 'node:crypto';

const defaultVoice = 'cosyvoice-v3.5-plus-bailian-20fde1dbc7b04884862ee1b54a2c128f';

// Keep credentials and the chosen voice on the server. Clients supply text and rate only.
export function createSpeechSynthesizer(env, connect = (url, options) => new WebSocket(url, options)) {
  const workspace = env.DASHSCOPE_WORKSPACE_ID?.trim();
  const key = (env.COSYVOICE_API_KEY || env.DASHSCOPE_API_KEY)?.trim();
  const model = env.COSYVOICE_MODEL || 'cosyvoice-v3.5-plus';
  const voice = env.COSYVOICE_VOICE || defaultVoice;
  const configured = Boolean(key && workspace && /^ws-[a-zA-Z0-9-]+$/.test(workspace));
  return {
    configured,
    synthesize(text, rate, signal) {
      if (!configured) return Promise.reject(new Error('Speech service not configured'));
      return new Promise((resolve, reject) => {
        if (signal?.aborted) { reject(new Error('Speech request cancelled')); return; }
        const taskID = randomUUID();
        const socket = connect(`wss://${workspace}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`, {
          headers: { Authorization: `Bearer ${key}` }, maxPayload: 4 * 1024 * 1024,
          handshakeTimeout: 10000, perMessageDeflate: false
        });
        let settled = false, started = false, length = 0;
        const chunks = [];
        const timer = setTimeout(() => finish(new Error('Speech synthesis timed out')), 45000);
        const abort = () => finish(new Error('Speech request cancelled'));
        const finish = (error, audio) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          signal?.removeEventListener('abort', abort);
          // Leave error listener attached: terminate during CONNECTING emits an error.
          socket.terminate();
          if (error) reject(error); else resolve(audio);
        };
        const send = (action, payload) => {
          if (settled) return;
          try {
            socket.send(JSON.stringify({ header: { action, task_id: taskID, streaming: 'duplex' }, payload }),
              error => { if (error) finish(new Error('Speech send failed')); });
          } catch { finish(new Error('Speech send failed')); }
        };
        signal?.addEventListener('abort', abort, { once: true });
        socket.on('open', () => {
          if (settled) return;
          send('run-task', {
            task_group: 'audio', task: 'tts', function: 'SpeechSynthesizer', model,
            parameters: { text_type: 'PlainText', voice, format: 'mp3', sample_rate: 24000, volume: 50, rate, pitch: 1 }, input: {}
          });
        });
        socket.on('message', (data, isBinary) => {
          if (settled) return;
          if (isBinary) {
            if (!started) { finish(new Error('Unexpected audio')); return; }
            length += data.length;
            if (length > 16 * 1024 * 1024) { finish(new Error('Speech response too large')); return; }
            chunks.push(Buffer.from(data));
            return;
          }
          try {
            const event = JSON.parse(data.toString());
            if (event.header?.task_id !== taskID) { finish(new Error('Unexpected speech task')); return; }
            if (event.header.event === 'task-started' && !started) {
              started = true;
              send('continue-task', { input: { text } });
              send('finish-task', { input: {} });
            } else if (event.header.event === 'task-finished') {
              if (!started || !length) finish(new Error('Empty speech response'));
              else finish(null, Buffer.concat(chunks, length));
            } else if (event.header.event === 'task-failed') {
              // Upstream error messages may contain private account information.
              finish(new Error('Speech provider rejected the request'));
            }
          } catch { finish(new Error('Invalid speech response')); }
        });
        socket.on('error', () => finish(new Error('Speech connection failed')));
        if (signal?.aborted) abort();
        socket.on('close', () => { if (!settled) finish(new Error('Incomplete speech response')); });
      });
    }
  };
}
