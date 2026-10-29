import { resolve, dirname } from 'node:path';
import { mintPairingCode } from './client-auth.mjs';
const stateFile = resolve(process.env.CLIENT_AUTH_STATE_FILE || dirname(resolve(process.env.RATE_STATE_FILE || 'data/limits.json')) + '/client-access.json');
const file = resolve(process.env.CLIENT_PAIRING_FILE || dirname(stateFile) + '/client-pairing.json');
const { code } = mintPairingCode(file);
console.log('App 服务连接码（10 分钟有效，仅可使用一次）：');
console.log(code.slice(0, 4) + '-' + code.slice(4, 8) + '-' + code.slice(8));
console.log('在新版 App 的 设置 → 服务连接 中输入。不要发送 API Key 或 .p8。');
