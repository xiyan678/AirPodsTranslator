import Foundation

enum ConversationMode: String, CaseIterable, Identifiable, Codable {
    case listen = "耳机听译"
    case dialogue = "面对面对话"
    var id: String { rawValue }
}

enum ConversationPhase: Equatable {
    case idle, preparing, listening, recognizing, translating
    case waitingForLanguagePack, speaking, replaying, paused

    var isActive: Bool {
        switch self {
        case .listening, .recognizing, .translating, .waitingForLanguagePack, .speaking, .replaying: true
        case .idle, .preparing, .paused: false
        }
    }

    func canTransition(to next: Self) -> Bool {
        if self == next || next == .paused { return true }
        switch self {
        case .idle: return next == .preparing || next == .replaying
        case .preparing: return next == .listening || next == .idle
        case .listening: return next == .recognizing || next == .replaying
        case .recognizing: return next == .listening || next == .translating
        case .translating: return next == .speaking || next == .waitingForLanguagePack || next == .listening
        case .waitingForLanguagePack: return next == .translating || next == .listening
        case .speaking: return next == .listening
        case .replaying: return next == .listening || next == .idle
        case .paused: return next == .preparing || next == .replaying
        }
    }
}

enum ProcessingMode: String, CaseIterable, Identifiable {
    case fast = "低延迟"
    case quality = "高质量"
    var id: String { rawValue }
}

enum AudioDestination: String, CaseIterable, Identifiable {
    case earphones = "耳机"
    case speaker = "手机扬声器"
    var id: String { rawValue }
}

struct TranscriptLine: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var sourceLanguage: String
    var targetLanguage: String
    var original: String
    var translated: String
    var isMine: Bool
}

struct SavedConversation: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var lines: [TranscriptLine]
    var summary: String
    var outline: SummaryOutline? = nil
}

struct Term: Identifiable, Codable {
    var id = UUID()
    var source: String
    var replacement: String
}

struct LanguageOption: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

enum AppLanguage {
    static let all: [LanguageOption] = [
        .init(code: "zh", name: "中文"), .init(code: "en", name: "英语"),
        .init(code: "ja", name: "日语"), .init(code: "ko", name: "韩语"),
        .init(code: "es", name: "西班牙语"), .init(code: "fr", name: "法语"),
        .init(code: "de", name: "德语"), .init(code: "pt", name: "葡萄牙语"),
        .init(code: "it", name: "意大利语"), .init(code: "ru", name: "俄语"),
        .init(code: "ar", name: "阿拉伯语"), .init(code: "th", name: "泰语"),
        .init(code: "vi", name: "越南语"), .init(code: "id", name: "印尼语")
    ]

    static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    static func normalizedCode(_ code: String) -> String {
        code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
    }
}

enum RecognizedSpeechText {
    private static let ignoredMarkers: Set<String> = [
        "blankaudio", "noaudio", "nospeech", "空白音频", "无音频"
    ]

    static func cleaned(_ rawValue: String) -> String? {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let marker = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !ignoredMarkers.contains(marker) else { return nil }
        // Whisper can emit caption annotations for non-speech sounds. Only reject
        // complete annotation-only results, preserving spoken text around them.
        let annotationPattern = #"^(?:\s*[\[（(【][^\]）)】]*[\]）)】]\s*[.,，。!?！？]*\s*)+$"#
        if text.range(of: annotationPattern, options: .regularExpression) != nil { return nil }
        return text
    }
}
