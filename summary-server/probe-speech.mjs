import { mkdir, writeFile } from 'node:fs/promises';
import { createSpeechSynthesizer } from './speech.mjs';

const speech = createSpeechSynthesizer(process.env);
if (!speech.configured) {
  console.error('安娜语音配置缺失：检查服务器 .env 中的百炼 Key 和业务空间 ID。');
  process.exitCode = 1;
} else {
  try {
    const audio = await speech.synthesize('你好，我是安娜，这是声音测试。', 1);
    await mkdir('data', { recursive: true });
    await writeFile('data/anna-test.mp3', audio, { mode: 0o600 });
    console.log(`安娜语音合成成功：${audio.length} 字节，文件 data/anna-test.mp3`);
  } catch (error) {
    console.error(`安娜语音合成失败：${error.message}`);
    process.exitCode = 1;
  }
}
