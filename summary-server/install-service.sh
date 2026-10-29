#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
node_bin="${1:-$(command -v node || true)}"
if [[ "${EUID}" -ne 0 ]]; then
  echo '请在宝塔终端使用 root 运行此安装脚本。' >&2
  exit 1
fi
if [[ -z "$node_bin" || ! -x "$node_bin" ]]; then
  echo '请先安装 Node.js 22 或更新版本，再运行脚本。也可将 node 的绝对路径作为第一个参数。' >&2
  exit 1
fi
node_major="$("$node_bin" -p 'process.versions.node.split(".")[0]')"
if (( node_major < 22 )); then
  echo '当前 Node 版本过旧，请使用 22 或更新版本。' >&2
  exit 1
fi
if [[ ! -f "$project_dir/.env" ]]; then
  echo '请先复制 .env.example 为 .env，在文件编辑器中填写 DASHSCOPE_API_KEY。' >&2
  exit 1
fi
if [[ "$project_dir" == *[[:space:]]* || "$node_bin" == *[[:space:]]* ]]; then
  echo '请将项目和 Node 放在不含空格的目录。' >&2
  exit 1
fi
if ! getent passwd www >/dev/null; then
  echo '未找到宝塔的 www 用户，请检查服务器环境。' >&2
  exit 1
fi
chown www:www "$project_dir/.env"
chmod 600 "$project_dir/.env"
chmod 755 "$project_dir"
chmod 644 "$project_dir/server.mjs"
chmod 644 "$project_dir/device-check.mjs"
chmod 644 "$project_dir/speech.mjs" "$project_dir/referrals.mjs"
chmod 755 "$project_dir/certificates"
chmod 644 "$project_dir"/certificates/*.cer
if [[ ! -d "$project_dir/node_modules/ws" || ! -d "$project_dir/node_modules/@apple/app-store-server-library" ]]; then
  echo '请先在项目目录执行 npm ci --omit=dev --ignore-scripts，再安装服务。' >&2
  exit 1
fi
if ! runuser -u www -- "$node_bin" -v >/dev/null 2>&1; then
  echo 'www 无法执行 Node，请用 namei -l 检查各级目录的穿越权限。' >&2
  exit 1
fi
mkdir -p "$project_dir/data"
chown www:www "$project_dir/data"
chmod 700 "$project_dir/data"
cat > /etc/systemd/system/ear-yi-summary.service <<EOF
[Unit]
Description=EarYi Qwen summary API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www
Group=www
WorkingDirectory=$project_dir
ExecStart=$node_bin --env-file=$project_dir/.env $project_dir/server.mjs
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$project_dir/data

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ear-yi-summary
systemctl restart ear-yi-summary
systemctl --no-pager --full status ear-yi-summary
