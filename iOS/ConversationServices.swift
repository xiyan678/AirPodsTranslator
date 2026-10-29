import AVFoundation
import Translation

/// 系统边界集中在此处，控制器的排队、暂停和保存流程可用确定性服务验证。
@MainActor
struct ConversationServices {
    var prepareSpeech: () async throws -> Void
    var requestMicrophonePermission: () async -> Bool
    var startCapture: () throws -> Void
    var recognition: ([Float], String?) async throws -> (text: String, language: String)
    var translation: (String, String, String, ProcessingMode, TranslationSession?) async throws -> String

    func recognize(_ samples: [Float], language: String?) async throws -> (text: String, language: String) {
        try await recognition(samples, language)
    }

    func translate(_ text: String, from source: String, to target: String,
                   mode: ProcessingMode, preparedSession: TranslationSession? = nil) async throws -> String {
        try await translation(text, source, target, mode, preparedSession)
    }

    static func live(whisper: WhisperService, capture: AudioCapture) -> Self {
        let translator = LocalTranslator()
        return Self(
            prepareSpeech: { try await whisper.prepare() },
            requestMicrophonePermission: { await AVAudioApplication.requestRecordPermission() },
            startCapture: { try capture.start() },
            recognition: { samples, language in try await whisper.recognize(samples, language: language) },
            translation: { text, source, target, mode, prepared in
                try await translator.translate(text, from: source, to: target,
                                               mode: mode, preparedSession: prepared)
            }
        )
    }
}
