import SwiftUI

struct LegalSection: Identifiable {
    let title: String
    let body: String
    var id: String { title }
}

struct LegalDocument {
    let title: String
    let updated: String
    let introduction: String
    let sections: [LegalSection]
}

enum AppLegal {
    static let publisher = "东莞市夕颜网络科技有限公司"
    static let authorProfileURL = URL(string: "https://www.douyin.com/user/MS4wLjABAAAAYImL2h_F25C_Z-EtpUYULY14g6utfK5yO8-QfAKNXqW67os8G5t5zG2LJ_yQ3G0R")!

    static let privacy = LegalDocument(
        title: "隐私政策",
        updated: "2026 年 10 月 29 日",
        introduction: "声译尊重你的隐私。以下说明当前版本如何处理语音、文字、图片、对话记录和订阅信息。",
        sections: [
            .init(title: "1. 我们处理的信息", body: "麦克风语音用于实时识别和翻译；你选择的图片或拍摄的照片用于文字识别；输入的文字用于翻译；语言偏好、语速、术语和免费额度保存在设备上。你主动保存的对话会写入 App 的本地存储。"),
            .init(title: "2. 本地处理与网络下载", body: "语音转写、图片文字识别、已安装语言包的翻译和对话记录处理在设备上完成。首次使用语音模型时，App 会从模型提供方下载模型文件；离线翻译语言包由苹果系统下载和管理。相关服务可能处理下载请求所需的网络信息，例如 IP 地址。打开实时总结或手动刷新时，对话原文和译文将通过 HTTPS 发送给声译总结接口，并由阿里云百炼 Qwen 生成总结。接口不主动保存对话正文，也不接收原始音频或图片。默认总结请求会生成 Apple DeviceCheck 设备凭证并交由 Apple 验证，用于防止接口滥用。服务器保存限流计数、来源 IP 和已使用凭证的哈希；IP 按小时重置，凭证哈希最多保留七天，不保存原始设备凭证。若你在设置中开启自己的模型 API 并填写密钥，总结文字会直接发送给你选择的模型服务，不经过默认总结接口。自定义 API Key 保存在本机钥匙串，可在设置中清空；第三方服务的数据处理规则以对应平台政策为准。关闭实时总结刷新或关闭总结面板会停止后续自动请求。"),
            .init(title: "3. 苹果服务与订阅", body: "购买、续订、恢复购买和订阅管理由 Apple StoreKit 与 App Store 处理。App 读取苹果验证过的订阅资格，用于解锁 Pro 功能；我们不在 App 内取得银行卡完整信息。苹果的翻译服务可能收集 API 使用及性能信息，具体以苹果的隐私政策为准。"),
            .init(title: "4. 设备间传递与主动分享", body: "如果你使用配对的 Apple Watch，App 会将当前运行状态和最新译文发送到手表。只有在你主动点按分享时，所选内容才会交给系统分享面板及你选择的目标 App。"),
            .init(title: "5. 保存、删除与权限", body: "对话记录默认不自动保存；你可以在设置中开启自动保存，也可以手动保存。已保存的对话可在历史页删除，术语可在设置中删除。卸载 App 会移除其本地数据；系统语言包由 iOS 管理。你可以在 iOS 设置中关闭麦克风、相机或照片访问权限，关闭后相应功能无法使用。"),
            .init(title: "6. 联系与政策更新", body: "如对数据处理有疑问，可通过设置页的“联系作者”入口联系我们。若将来加入云端翻译、账号、分析或广告等功能，我们会先更新本政策，并按要求更新 App Store 隐私信息。")
        ]
    )

    static let terms = LegalDocument(
        title: "使用条款",
        updated: "2026 年 10 月 29 日",
        introduction: "欢迎使用声译。使用本 App 前，请阅读以下条款。",
        sections: [
            .init(title: "1. 服务内容", body: "声译提供语音同传、双语对话、文本与图片翻译、对话记录等功能。部分功能依赖设备支持、麦克风或相机权限、离线模型和苹果翻译语言包；可用语言对以设备实际支持情况为准。"),
            .init(title: "2. 免费额度与 Pro", body: "免费版每天提供 10 分钟同传和 20 句对话，按设备本地日期重置。Pro 订阅期间解除这两项额度限制。文本、图片翻译和已保存记录的使用规则以 App 内显示为准。"),
            .init(title: "3. 购买、续订与取消", body: "Pro 提供月度和年度自动续订方案。实际价格、币种、试用或优惠以 App Store 购买页显示为准；购买前请确认。订阅由 Apple 处理并按其条款续订。你可以在 App 的“管理订阅”或 iOS 的 Apple 账户订阅设置中管理和取消，也可以在 App 中恢复购买。退款申请由 Apple 处理。"),
            .init(title: "4. 使用责任", body: "你应确保自己有权录制、翻译、保存或分享相关内容，并遵守所在地法律及交谈对象的意愿。请勿将本 App 用于违法、侵权或侵犯他人隐私的活动。"),
            .init(title: "5. 翻译准确性", body: "语音识别和机器翻译可能出现遗漏或错误。医疗、法律、财务、安全等重要场景请由具备资质的人员核对，不应只依赖自动译文作决定。"),
            .init(title: "6. 服务变更与联系", body: "我们可能修复问题、更新模型或调整功能。若订阅权益或重要条款发生变化，我们会按适用规则通知。你可以通过设置页的“联系作者”入口提出问题。")
        ]
    )
}

struct LegalPageView: View {
    let document: LegalDocument

    var body: some View {
        ZStack {
            StudioBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(document.title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(StudioStyle.ink)
                        Text("更新日期：\(document.updated)")
                            .font(.footnote).foregroundStyle(StudioStyle.muted)
                        Text(document.introduction)
                            .font(.body).foregroundStyle(StudioStyle.ink)
                            .padding(.top, 8)
                    }
                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.headline).foregroundStyle(StudioStyle.ink)
                            Text(section.body)
                                .font(.body).foregroundStyle(StudioStyle.muted)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                    }
                    Text("发布者：\(AppLegal.publisher)")
                        .font(.footnote).foregroundStyle(StudioStyle.muted)
                }
                .padding(22)
            }
        }
        .navigationTitle(document.title)
    }
}
