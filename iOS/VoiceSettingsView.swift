import AVFoundation
import SwiftUI

struct VoiceSettingsView: View {
    @EnvironmentObject private var controller: ConversationController
    @ObservedObject var preferences: Preferences
    @State private var language: String
    @State private var player = SpeechPlayer()
    @State private var showPreviewError = false

    init(preferences: Preferences) {
        self.preferences = preferences
        _language = State(initialValue: preferences.preferredLanguage)
    }

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { AppLanguage.normalizedCode($0.language) == language }
            .sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
    }

    private var canPreview: Bool {
        !controller.isRunning && !controller.isPreparing && !controller.isEnding &&
            !controller.isTranslatingText && !controller.isSpeechPlaying && controller.phase != .replaying
    }

    var body: some View {
        Form {
            Section {
                Picker("目标语言", selection: $language) {
                    ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                }
            }
            Section("朗读声音") {
                Button {
                    player.stop()
                    preferences.setVoiceIdentifier(nil, for: language)
                } label: {
                    HStack {
                        Text("跟随系统").foregroundStyle(.primary)
                        Spacer()
                        if preferences.voiceIdentifier(for: language) == nil {
                            Image(systemName: "checkmark").foregroundStyle(StudioStyle.blue)
                        }
                    }
                }
                .accessibilityIdentifier("voice-system-default")
                ForEach(voices, id: \.identifier) { voice in
                    HStack(spacing: 16) {
                        Button {
                            player.stop()
                            preferences.setVoiceIdentifier(voice.identifier, for: language)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(voice.name).foregroundStyle(.primary)
                                    Text(Locale(identifier: "zh_CN").localizedString(forIdentifier: voice.language) ?? voice.language)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preferences.voiceIdentifier(for: language) == voice.identifier {
                                    Image(systemName: "checkmark").foregroundStyle(StudioStyle.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { preview(voice.identifier) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .disabled(!canPreview)
                            .accessibilityLabel("试听 \(voice.name)")
                    }
                }
                if voices.isEmpty {
                    Text("手机上暂时没有这门语言的朗读声音。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("目标语言声音")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("试听") { preview(preferences.voiceIdentifier(for: language)) }
                .disabled(voices.isEmpty || !canPreview)
        }
        .onChange(of: language) { _, _ in player.stop() }
        .onChange(of: canPreview) { _, _ in
            if !canPreview { player.stop() }
        }
        .onDisappear { player.stop() }
        .alert("无法试听", isPresented: $showPreviewError) {
            Button("好", role: .cancel) {}
        } message: { Text("当前声音暂不可用，请选择其他声音。") }
    }

    private func preview(_ identifier: String?) {
        guard canPreview else { return }
        showPreviewError = !player.speak(VoicePreviewText.text(for: language), language: language,
            rate: preferences.speechRate, destination: .earphones, voiceIdentifier: identifier) {}
    }
}

enum VoicePreviewText {
    static func text(for language: String) -> String {
        switch language {
        case "zh": "你好，这是翻译后的朗读声音。"
        case "en": "Hello, this is the voice for your translations."
        case "ja": "こんにちは。翻訳をこの声で読み上げます。"
        case "ko": "안녕하세요. 번역을 이 목소리로 읽어 드립니다."
        case "fr": "Bonjour, voici la voix de vos traductions."
        case "de": "Hallo, so klingt die Stimme für Ihre Übersetzungen."
        case "es": "Hola, esta es la voz para tus traducciones."
        case "pt": "Olá, esta é a voz das suas traduções."
        case "ru": "Здравствуйте. Это голос для ваших переводов."
        case "it": "Ciao, questa è la voce delle tue traduzioni."
        case "ar": "مرحبًا، هذا هو صوت قراءة الترجمة."
        case "th": "สวัสดี นี่คือเสียงสำหรับอ่านคำแปลของคุณ"
        case "vi": "Xin chào, đây là giọng đọc bản dịch của bạn."
        case "id": "Halo, ini suara untuk terjemahan Anda."
        default: AppLanguage.name(language)
        }
    }
}
