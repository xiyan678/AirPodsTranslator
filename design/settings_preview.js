function settingsPreview(part) {
  const row = (label, value) => `<div class="settings-row"><span>${label}</span><span class="value">${value}</span></div>`;
  const section = (title, content, compact = false) => `<div class="settings-section">${title}</div><div class="settings-panel${compact ? ' compact' : ''}">${content}</div>`;
  const top = [
    section('语言',
      row('源语言', '自动识别 ›') + row('目标语言', '中文 ›') +
      row('交换源语言和目标语言', '<span class="link">⇄</span>') +
      row('自动朗读译文', '<span class="settings-switch"></span>') +
      row('离线语言包', '›')),
    section('翻译质量',
      row('处理模式', '低延迟 ›') +
      row('嘈杂环境：突出近处人声', '<span class="settings-switch"></span>')),
    section('显示和播放',
      row('字幕大小', '<span class="settings-slider"></span>') +
      row('播报速度', '<span class="settings-slider"></span>'))
  ].join('');
  const more = [
    section('记录', row('自动保存对话', '<span class="settings-switch off"></span>'), true),
    section('耳译 Pro',
      row('当前版本', '免费版') + row('查看月度与年度订阅', '›') +
      row('管理订阅', '›') + row('恢复购买', '›'), true),
    section('关于',
      row('联系作者（抖音）', '↗') + row('使用条款', '›') +
      row('隐私政策', '›') + row('发布者', '东莞市夕颜网络科技有限公司'), true),
    section('专有词汇',
      row('识别到的词', '输入词语') + row('希望显示的译词', '输入译词') +
      row('添加', '<span class="link">＋</span>'), true)
  ].join('');
  return `<div class="settings-screen ${part === 'more' ? 'more' : ''}"><h1 class="settings-title">设置</h1>${part === 'more' ? more : top}</div>${previewTabs('设置')}`;
}
