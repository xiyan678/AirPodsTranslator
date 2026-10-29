#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
node_bin="${1:-/www/server/nodejs/v26.13.0/bin/node}"
if [[ "$EUID" -ne 0 ]]; then
  echo '请使用宝塔 root 终端运行。' >&2
  exit 1
fi
if [[ ! -x "$node_bin" ]]; then
  echo '找不到指定的 Node，请将正确的 node 路径作为第一个参数。' >&2
  exit 1
fi
node_major="$("$node_bin" -p 'process.versions.node.split(".")[0]')"
if (( node_major < 22 )); then
  echo '需要 Node.js 22 或更新版本。' >&2
  exit 1
fi
cd -- "$project_dir"
if [[ ! -f .env ]]; then
  echo '未找到现有 .env，请先按部署说明配置百炼及 DeviceCheck。' >&2
  exit 1
fi
backup_file=".env.before-anna-$(date +%Y%m%d%H%M%S)"
cp -p -- .env "$backup_file"
chmod 600 -- "$backup_file"
"$node_bin" --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
let text = readFileSync('.env', 'utf8');
const settings = {
  DASHSCOPE_WORKSPACE_ID: 'ws-3vtghkxq6gkuap9d',
  COSYVOICE_MODEL: 'cosyvoice-v3.5-plus',
  COSYVOICE_VOICE: 'cosyvoice-v3.5-plus-bailian-20fde1dbc7b04884862ee1b54a2c128f'
};
for (const [name, value] of Object.entries(settings)) {
  const pattern = new RegExp('^[ \t]*(?:export[ \t]+)?' + name + '[ \t]*=.*$', 'gm');
  if (pattern.test(text)) text = text.replace(pattern, name + '=' + value);
  else text += '\n' + name + '=' + value + '\n';
}
writeFileSync('.env', text, { mode: 0o600 });
NODE
chmod 600 .env
# npm's launcher must use the same Node as the service.
export PATH="$(dirname -- "$node_bin"):$PATH"
npm ci --omit=dev --ignore-scripts
npm test
bash install-service.sh "$node_bin"
# A healthy local module must exist before checking the reverse proxy.
curl --fail --silent --show-error --retry 5 --retry-connrefused --retry-delay 1 http://127.0.0.1:3001/v1/speech/health
printf '\n'
curl --fail --silent --show-error https://ai.duwang.win/v1/speech/health
printf '\n'
echo '语音模块已更新。configured 必须为 true；随后在新版 App 内测试实际安娜播报。'
echo '若 configured 为 false，请检查原有百炼和 DeviceCheck 配置；不需要向聊天发送密钥。'
