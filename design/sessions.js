const tabIcons = {
    '同传': `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v4m-4 0h8"/></svg>`,
    '对话': `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="7" r="3"/><circle cx="17" cy="7" r="3"/><path d="M1 20c0-4 3-7 7-7s7 3 7 7H1Zm12 0c0-3-1-5-3-7 4-2 11 0 13 7H13Z"/></svg>`,
    '历史': `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/><path d="M12 5v7h-5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg>`,
    '设置': `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.7" stroke-linejoin="round"><path d="M10 2h4l.7 2.2 2 .9 2-.9 2.5 3.4-1.5 1.7.2 2.2 1.9 1.2-1.2 4-2.2.1-1.5 1.7.2 2.2-4 1.3-1.2-1.8h-2.2L8 22l-4-1.3.2-2.2-1.5-1.7-2.2-.1-1.2-4 1.9-1.2.2-2.2L0 7.6l2.5-3.4 2 .9 2-.9L7.2 2H10Z" transform="translate(1 0) scale(.92)"/><circle cx="12" cy="12" r="3"/></svg>`
};
function previewTabs(active) {
  return `<div class="session-tabs">${['同传','对话','历史','设置'].map(name => `<div class="session-tab ${name === active ? 'active' : ''}">${tabIcons[name]}<span>${name}</span></div>`).join('')}</div>`;
}
function sessionPreview(kind) {
  const live = kind === 'live';
  const waveform = `<svg width="51" height="51" viewBox="0 0 51 51" fill="none" stroke="currentColor" stroke-width="3.6" stroke-linecap="round"><path d="M9 24v5M16 17v19M23 10v31M30 16v21M37 23v10"/><path d="M42 33v9m-5-6a5 5 0 0 0 10 0M42 42v4m-4 0h8" stroke-width="2.5"/></svg>`;
  const mic = `<svg width="43" height="43" viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><rect x="18" y="6" width="12" height="27" rx="6" fill="currentColor"/><path d="M10 24a14 14 0 0 0 28 0M24 38v6m-9 0h18"/></svg>`;
  const screen = `<svg width="45" height="45" viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linejoin="round"><rect x="6" y="8" width="27" height="25" rx="3"/><rect x="15" y="16" width="27" height="25" rx="3" fill="#6151ec"/></svg>`;
  const bubbles = `<svg width="48" height="48" viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2.7" stroke-linejoin="round"><path d="M4 10h24a5 5 0 0 1 5 5v15a5 5 0 0 1-5 5H17l-8 7v-7a5 5 0 0 1-5-5V15a5 5 0 0 1 5-5Z"/><path d="M22 6h17a5 5 0 0 1 5 5v15a5 5 0 0 1-5 5h-4"/></svg>`;
  const header = live
    ? `<div class="session-head"><div class="session-mode"><span class="wave">${waveform}</span> 实时同传 <span>⌄</span></div></div>`
    : `<div class="session-dialogue-head"><div class="dialogue-source">中文 &nbsp;⇄&nbsp; 英语</div><div class="keyboard-pill">⌨ &nbsp;键盘</div></div>`;
  const center = live
    ? `<div class="session-center"><div class="session-orb">${waveform}</div><h1>准备翻译模型</h1><p>正在准备端侧翻译资源</p></div>`
    : `<div class="session-center"><div class="session-orb dialogue-orb">${bubbles}</div><h1>开始一段对话</h1><p>选择说话的人，译文会自动显示</p></div>`;
  const bottom = live
    ? `<div class="session-bottom"><div class="session-languages"><span>英语（美国）⌄</span><span class="exchange">⇄</span><span>英语（美国）⌄</span></div><div class="session-rounds"><div class="session-control"><div class="session-circle mic">${mic}</div>麦克风</div><div class="session-control"><div class="session-circle broadcast">${screen}</div>屏幕广播</div></div><div class="session-hint">选择麦克风，或广播其他 App 的屏幕音频</div></div>`
    : `<div class="session-bottom"><div class="session-dialogue-controls"><div class="session-speech">${mic}<span>说中文</span></div><div class="session-speech other">${mic}<span>说英语</span></div></div></div>`;
  return `<div class="session-screen">${header}${center}${bottom}</div>${previewTabs(live ? '同传' : '对话')}`;
}
