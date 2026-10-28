# 声译（AirPodsTranslator）

独立 iPhone 翻译 App 源码。适配 iOS 26+，使用 iPhone 麦克风、AirPods 输出、端侧 WhisperKit 语种识别与转写、Apple Translation、Foundation Models 摘要、Vision OCR、WatchConnectivity。首次使用需要下载语音模型；遇到尚未安装的翻译语言包时，App 会请求系统弹出下载许可。

## 在 Mac 上打开

1. 安装 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。
2. 在本目录执行 `xcodegen generate`，打开生成的 `AirPodsTranslator.xcodeproj`。
3. 将 `project.yml` 的主 App、BroadcastUpload、Watch 三个 Bundle ID 换成自己的标识；同步修改 `Shared/BroadcastStorage.swift` 的广播扩展 ID、App Group ID，以及两个 `.entitlements` 中的 App Group ID。到 Apple Developer 后台给主 App 和 BroadcastUpload 启用同一个 App Group，再配置签名。
4. 连接 iPhone 真机，编译运行。首次启动允许麦克风，并下载模型。

## Codemagic 云编译

仓库根目录的 `codemagic.yaml` 提供 `ios-simulator` 工作流：安装 XcodeGen、生成项目、用 Xcode 26.6 无签名编译 iOS 模拟器版本，并输出 `AirPodsTranslator-simulator.zip`。此构建用于发现编译错误；模拟器包不能安装到 iPhone。生成可安装的 IPA 还需 Apple Developer 签名证书、主 App 与广播扩展的 App Group 配置，以及对应的描述文件。

## App 内订阅

在 App Store Connect 的同一个自动续订订阅群组中创建两个商品：`<主 App Bundle ID>.pro.monthly` 和 `<主 App Bundle ID>.pro.yearly`。中国区价格分别配置为 ¥68/月和 ¥498/年；其他地区的价格由 App Store Connect 设置，App 会显示商店的实际价格。完成付费协议、税务、银行资料和订阅所需的隐私政策及条款信息后，用 StoreKit 沙盒账号验证购买、续订、过期与恢复购买。

免费版每天可使用 10 分钟同传和 20 句对话，Pro 不限时。额度保存在设备本地；此源码不含账号同步或服务器防篡改。购买资格由 StoreKit 已验证交易决定。

## 联系与法律页面

设置页“联系作者（抖音）”打开发布者提供的抖音主页；“使用条款”和“隐私政策”可在 App 内阅读。`legal/terms.html` 与 `legal/privacy.html` 是可公开托管的网页版本。发布到 App Store 前，需要将隐私政策网页放在公开可访问的 HTTPS 地址，并在 App Store Connect 填写该 URL；订阅商品也应配置相应的条款和隐私链接。发布者为东莞市夕颜网络科技有限公司。若实际的数据处理方式或商店信息变化，应同步更新 App 内及网页文案。

## 范围

- 同传、对话、历史和设置四页；文本翻译、图片翻译、双语对话按钮、源语言与目标语言切换。
- 持续收音、说话过程中的实时识别字幕、自动语种识别、双语字幕、显示当前音频输出与播放状态、AirPods 播报、手机外放、重播与语速。
- 可修改上一句的原文和语种并重新翻译；会话过程使用明确状态切换管理。
- 近场收音开关、低延迟/高质量模式、语音模型下载百分比、语言包下载状态、专有词汇表。Apple Translation 不提供语言包下载百分比，系统负责展示其下载流程。
- 同传页的“屏幕广播”使用 iOS 26 ReplayKit 上传扩展接收其他 App 的音频，通过 App Group 传给主 App。广播时仅显示字幕，不自动朗读，避免译文再次被录入。需在真机确认目标 App 是否允许采集音频，以及切到其他 App 后主 App 的后台处理是否持续；两者受 iOS 和目标 App 限制。
- 本地对话摘要、记录、搜索和导出、拍照 OCR 翻译、Apple Watch 暂停/继续/重播。支持 Apple Intelligence 的设备使用端侧模型总结；其他设备使用重点句提取。

## 设备验证清单

此仓库是在 Windows 上编写的，当前环境没有 Xcode，尚不能编译或真机测试。发布前需要在 Mac 上验证 Swift 编译、WhisperKit 版本 API、ReplayKit 扩展与 App Group 签名、语言包下载、长时间收音、AirPods 与手机扬声器切换、Watch 配对及后台行为。离线语言对取决于 Apple Translation 在设备上的实际支持情况；不支持的语言对会显示不可用，不会伪造翻译。

## 隐私

语音转写、文字翻译与图片识别优先在设备上处理。记录默认不保存，用户主动保存后写入 App 本地文档目录。不要在未取得交谈对象同意时录音或保存对话。

## 本次更新

- 名称“声译”，图标为翻译与喇叭双气泡；保留 Bundle ID、签名、历史文件与钥匙串标识。
- 同传页可开启字幕画中画，显示最新原文和译文；浮窗的播放/暂停联动同传，结束同传关闭浮窗。不使用静音音轨保活。
- 语言包恢复翻译期间结束会等待结果；暂停保留待翻译原文，继续后重新处理。
- AI 三组要点随历史保存，结束后可从菜单再次打开；键盘翻译失败或下载语言包时保留输入。
- 默认 AI 总结接口需要 Apple DeviceCheck；部署前按 summary-server/宝塔部署说明.md 配置签名团队对应密钥。旧 App 不兼容新版接口。

验证：Windows 上可运行服务端 Node 测试及 Swift/YAML 静态解析；画中画、蓝牙音频、后台收音、语言包下载与签名设备校验需云端 Xcode 构建后在 iPhone 验证。
