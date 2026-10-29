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
    var playbackIsActive: (() -> Bool)? = nil
    var partialRecognition: (([Float], String?) async throws -> SpeechRecognitionUpdate)? = nil
    var commitRecognition: ((ConfirmedSpeechPrefix, String) -> Void)? = nil
    var resetRecognition: () -> Void = {}
    var resetRecognitionWindow: () -> Void = {}
    var prepareRecognition: ((String?) async throws -> Void)? = nil

    func prepare(language: String?) async throws {
        if let prepareRecognition { try await prepareRecognition(language) }
        else { try await prepareSpeech() }
    }

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
        let sherpa = SherpaSpeech()
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { samples, language, context in
                try await whisper.recognize(samples, language: language, context: context)
            },
            detect: { try await whisper.detectLanguage($0) },
            nativeFactory: { language in
                if SherpaSpeech.supports(language) {
                    try await sherpa.prepare()
                    return SherpaSpeechSession(service: sherpa, language: language)
                }
                return try await AppleSpeechSession.make(language: language)
            }
        )
        let prepare: @MainActor (String?) async throws -> Void = { language in
            recognizer.reset()
            sherpa.reset()
            if language == nil {
                // Detect language before selecting a bilingual decoder; otherwise every
                // unknown language would be forced through Chinese/English recognition.
                try await whisper.prepare()
                try await sherpa.prepare()
                return
            }
            if SherpaSpeech.supports(language) { try await sherpa.prepare(); return }
            if let language, await AppleSpeechSession.installedTranscriber(language: language) != nil { return }
            try await whisper.prepare()
        }
        return Self(
            prepareSpeech: { try await prepare(nil) },
            requestMicrophonePermission: { await AVAudioApplication.requestRecordPermission() },
            startCapture: { try capture.start() },
            recognition: { samples, language in
                if SherpaSpeech.supports(language) {
                    let update = try await sherpa.recognize(samples, language: language, final: true)
                    return (text: update.text, language: update.language)
                }
                let update = try await recognizer.recognize(samples, language: language, final: true)
                return (text: update.text, language: update.language)
            },
            translation: { text, source, target, mode, prepared in
                try await translator.translate(text, from: source, to: target,
                                               mode: mode, preparedSession: prepared)
            },
            partialRecognition: { samples, language in
                if SherpaSpeech.supports(language) { return try await sherpa.recognize(samples, language: language, final: false) }
                return try await recognizer.recognize(samples, language: language, final: false)
            },
            commitRecognition: { recognizer.commit($0, language: $1) },
            resetRecognition: { recognizer.reset(); sherpa.reset() },
            resetRecognitionWindow: { recognizer.resetWindow(); sherpa.reset() },
            prepareRecognition: { try await prepare($0) }
        )
    }
}
