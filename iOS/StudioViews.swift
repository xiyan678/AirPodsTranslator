import SwiftUI

enum StudioStyle {
    static let ink = Color(red: 0.08, green: 0.13, blue: 0.23)
    static let muted = Color(red: 0.38, green: 0.44, blue: 0.54)
    static let cyan = Color(red: 0.0, green: 0.72, blue: 0.79)
    static let blue = Color(red: 0.13, green: 0.37, blue: 0.91)
    static let violet = Color(red: 0.39, green: 0.32, blue: 0.88)
    static let surface = Color.white.opacity(0.90)
}

struct StudioBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.94, green: 0.98, blue: 1),
                                    Color(red: 0.97, green: 0.96, blue: 1),
                                    Color(red: 0.95, green: 0.98, blue: 0.99)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(StudioStyle.cyan.opacity(0.10)).frame(width: 360)
                .blur(radius: 70).offset(x: -170, y: -260)
            Circle().fill(StudioStyle.violet.opacity(0.10)).frame(width: 400)
                .blur(radius: 80).offset(x: 180, y: 320)
        }
    }
}

struct LiveLanguagePicker: View {
    @ObservedObject var preferences: Preferences
    let fallback: String
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("自动识别") { preferences.sourceLanguage = "auto" }
                ForEach(AppLanguage.all.filter { $0.code != preferences.preferredLanguage }) { language in
                    Button(language.name) { preferences.sourceLanguage = language.code }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(preferences.sourceLanguage == "auto" ? "自动识别" :
                         AppLanguage.name(preferences.sourceLanguage)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            Spacer(minLength: 0)
            Button {
                let newTarget = preferences.sourceLanguage == "auto" ? fallback : preferences.sourceLanguage
                let oldTarget = preferences.preferredLanguage
                preferences.sourceLanguage = oldTarget
                preferences.preferredLanguage = newTarget == oldTarget ? "en" : newTarget
            } label: { Image(systemName: "arrow.left.arrow.right").foregroundStyle(StudioStyle.blue) }
                .accessibilityLabel("交换语言")
            Spacer(minLength: 0)
            Menu {
                ForEach(AppLanguage.all) { language in
                    Button(language.name) {
                        if preferences.sourceLanguage == language.code { preferences.sourceLanguage = "auto" }
                        preferences.preferredLanguage = language.code
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(AppLanguage.name(preferences.preferredLanguage)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.ink)
        .padding(.horizontal, 18).frame(height: 54)
        .background(.white, in: Capsule())
    }
}

struct DialogueLanguagePicker: View {
    @EnvironmentObject private var controller: ConversationController
    @ObservedObject var preferences: Preferences
    @Binding var otherLanguage: String
    var body: some View {
        HStack {
            Menu {
                ForEach(AppLanguage.all.filter { $0.code != otherLanguage }) { language in
                    Button(language.name) {
                        if controller.isRunning { controller.pause() }
                        preferences.preferredLanguage = language.code
                    }
                }
            } label: {
                Text("你说 · \(AppLanguage.name(preferences.preferredLanguage))")
            }
            Spacer()
            Button {
                if controller.isRunning { controller.pause() }
                let old = preferences.preferredLanguage
                preferences.preferredLanguage = otherLanguage
                otherLanguage = old
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(StudioStyle.violet)
            }
            .accessibilityLabel("交换对话语言")
            Spacer()
            Menu {
                ForEach(AppLanguage.all.filter { $0.code != preferences.preferredLanguage }) { language in
                    Button(language.name) {
                        if controller.isRunning { controller.pause() }
                        otherLanguage = language.code
                    }
                }
            } label: {
                Text("对方 · \(AppLanguage.name(otherLanguage))")
            }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.ink)
        .padding(.horizontal, 18).frame(height: 54)
        .background(.white, in: Capsule())
    }
}

private struct StudioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white).frame(height: 56)
            .background(LinearGradient(colors: [StudioStyle.blue, StudioStyle.violet],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct StudioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(StudioStyle.blue)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

struct TextTranslationView: View {
    @EnvironmentObject private var controller: ConversationController
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var preferences: Preferences
    @State private var original = ""
    @State private var source = "auto"
    @State private var target = "zh"
    @State private var translating = false

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("想说的话，轻松抵达")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(StudioStyle.ink)
                        HStack {
                            Menu {
                                Button("自动识别") { source = "auto" }
                                ForEach(AppLanguage.all) { language in
                                    Button(language.name) { source = language.code }
                                }
                            } label: { Text(source == "auto" ? "自动识别" : AppLanguage.name(source)) }
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(StudioStyle.violet)
                            Spacer()
                            Menu {
                                ForEach(AppLanguage.all) { language in
                                    Button(language.name) { target = language.code }
                                }
                            } label: { Text(AppLanguage.name(target)) }
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.blue)
                        .padding(18)
                        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                        TextEditor(text: $original)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .padding(14)
                            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                            .overlay(alignment: .topLeading) {
                                if original.isEmpty {
                                    Text("输入要翻译的文字…")
                                        .foregroundStyle(StudioStyle.muted)
                                        .padding(.top, 22).padding(.leading, 20)
                                        .allowsHitTesting(false)
                                }
                            }
                        Button {
                            translating = true
                            Task {
                                await controller.translateText(original, from: source, to: target)
                                translating = false
                            }
                        } label: {
                            Label(translating ? "正在翻译" : "翻译文字", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(StudioPrimaryButtonStyle())
                        .disabled(translating || original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source == target)
                        if !controller.textTranslation.isEmpty &&
                            controller.textOriginal == original && controller.textTargetLanguage == target {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("译文 · \(AppLanguage.name(controller.textDetectedLanguage)) → \(AppLanguage.name(controller.textTargetLanguage))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(StudioStyle.blue)
                                Text(controller.textTranslation)
                                    .font(.system(size: 22, weight: .medium, design: .rounded))
                                    .textSelection(.enabled)
                                ShareLink(item: controller.textTranslation) {
                                    Label("分享译文", systemImage: "square.and.arrow.up")
                                }
                                .font(.footnote).foregroundStyle(StudioStyle.blue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                        }
                    }
                    .padding(22)
                }
            }
            .navigationTitle("文本翻译")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .onAppear {
                target = preferences.preferredLanguage
                original = controller.textOriginal
            }
        }
    }
}
