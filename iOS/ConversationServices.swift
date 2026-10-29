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
    var headphonesConnected: () -> Bool = { SpeechPlayer.headphonesConnected }
    var enqueueSpeech: ((String, String, Float) -> Bool)? = nil
    var partialRecognition: (([Float], String?) async throws -> SpeechRecognitionUpdate)? = nil
    var commitRecognition: ((ConfirmedSpeechPrefix, String) -> Void)? = nil
    var resetRecognition: () -> Void = {}
    var resetRecognitionWindow: () -> Void = {}

    func recognize(_ samples: [Float], language: String?) async throws -> (text: String, language: String) {
        try await recognition(samples, language)
    }

    func recognizePartial(_ samples: [Float], language: String?) async throws -> SpeechRecognitionUpdate {
        if let partialRecognition { return try await partialRecognition(samples, language) }
        let result = try await recognition(samples, language)
        return SpeechRecognitionUpdate(text: result.text, language: result.language)
    }

    func translate(_ text: String, from source: String, to target: String,
                   mode: ProcessingMode, preparedSession: TranslationSession? = nil) async throws -> String {
        try await translation(text, source, target, mode, preparedSession)
    }

    static func live(whisper: WhisperService, capture: AudioCapture) -> Self {
        let translator = LocalTranslator()
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { samples, language, context in
                try await whisper.recognize(samples, language: language, context: context)
            },
            detect: { try await whisper.detectLanguage($0) }
        )
        return Self(
            prepareSpeech: {
                recognizer.reset()
                let selected = Preferences().sourceLanguage
                if selected != "auto", await AppleSpeechSession.installedTranscriber(language: selected) != nil { return }
                try await whisper.prepare()
            },
            requestMicrophonePermission: { await AVAudioApplication.requestRecordPermission() },
            startCapture: { try capture.start() },
            recognition: { samples, language in
                let update = try await recognizer.recognize(samples, language: language, final: true)
                return (text: update.text, language: update.language)
            },
            translation: { text, source, target, mode, prepared in
                try await translator.translate(text, from: source, to: target,
                                               mode: mode, preparedSession: prepared)
            },
            partialRecognition: { try await recognizer.recognize($0, language: $1, final: false) },
            commitRecognition: { recognizer.commit($0, language: $1) },
            resetRecognition: { recognizer.reset() },
            resetRecognitionWindow: { recognizer.resetWindow() }
        )
    }
}
