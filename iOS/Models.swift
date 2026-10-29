import Foundation
import NaturalLanguage

enum SpeechTextJoiner {
    static func join(_ parts: [String]) -> String {
        func compact(_ character: Character) -> Bool {
            character.unicodeScalars.contains {
                (0x3000...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
            }
        }
        var text = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let left = text.last, let right = part.first,
               !left.isWhitespace, !right.isWhitespace,
               right.isLetter || right.isNumber,
               !compact(left), !compact(right), left != "'", left != "’" {
                text += " "
            }
            text += part
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperLanguageConfidence {
    static func accepts(_ logProbability: Float?) -> Bool {
        guard let logProbability, logProbability.isFinite, logProbability <= 0 else { return false }
        return exp(logProbability) >= 0.6
    }
}

/// 相邻两次识别都一致的前缀才用于预览翻译，最终整句仍重新识别。
struct LiveTranscriptStabilizer {
    private var previous = ""
    private var language = ""

    mutating func update(_ text: String, language: String) -> String {
        if self.language != language { previous = "" }
        self.language = language
        let old = Array(previous), current = Array(text)
        previous = text
        let shared = zip(old, current).prefix { $0.0 == $0.1 }.count
        guard shared > 0 else { return "" }
        var prefix = String(current.prefix(shared))
        // increase / include 的共同前缀 inc 不是一个确认的单词；can / can't 也一样。
        func wordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "'" || character == "’"
        }
        let continues = (old.count > shared && wordCharacter(old[shared])) ||
            (current.count > shared && wordCharacter(current[shared]))
        if continues, let last = prefix.last, wordCharacter(last) {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = prefix
            var lastWord: Range<String.Index>?
            tokenizer.enumerateTokens(in: prefix.startIndex..<prefix.endIndex) { range, _ in
                lastWord = range
                return true
            }
            if let lastWord { prefix = String(prefix[..<lastWord.lowerBound]) }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func reset() { previous = ""; language = "" }
}

/// 仅在已有译文积压时温和追赶；不截断正在播的句子，也不删除待播内容。
enum SpeechBacklog {
    static func estimatedSeconds(_ text: String, rate: Float) -> Double {
        let eastern = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) ||
            (0xAC00...0xD7AF).contains($0.value)
        }.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let normalSeconds = eastern > 0 ? Double(eastern) / 4 : Double(words) / 2.7
        return normalSeconds * 0.5 / Double(max(0.1, rate))
    }

    static func adjustedRate(_ requested: Float, backlog: Double) -> Float {
        guard backlog.isFinite, requested.isFinite else { return 0.5 }
        let factor = 1 + min(0.2, max(0, backlog - 6) / 60)
        return min(1, max(0.1, requested * Float(factor)))
    }
}

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
    /// 可选字段兼容旧历史；失败时仍保存真实原文，错误提示不混入译文或总结。
    var translationIssue: String? = nil
}

struct SavedConversation: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var lines: [TranscriptLine]
    var summary: String
    var outline: SummaryOutline? = nil
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
    /// Whisper 在静音或环境声上常输出的“字幕标注”。只在整条结果都由这些标注
    /// 组成时才丢弃；句子里出现同样的词（如“请给他一点掌声”）会原样保留。
    private static let ignoredMarkers: [String] = [
        "blankaudio", "noaudio", "nospeech", "silence", "applause", "clapping", "music",
        "laughter", "cheering",
        "空白音频", "无音频", "无语音", "静音", "掌声", "鼓掌", "音乐", "笑声"
    ]

    /// 静音时 Whisper 常见的字幕署名类幻觉，正常对话中不会出现。
    private static let hallucinatedCredits: [String] = ["amaraorg", "明镜与点点"]

    static func cleaned(_ rawValue: String) -> String? {
        // 去掉 WhisperKit 未跳过的特殊标记，如 <|startoftranscript|>、<|0.00|>。
        let text = rawValue.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 去掉所有括号标注后，剩下的内容若为空或只是音效词，就不是有效语音。
        let withoutAnnotations = text.replacingOccurrences(of: #"[\[（(【][^\]）)】]*[\]）)】]"#, with: " ",
                                                           options: .regularExpression)
        let marker = normalized(withoutAnnotations)
        if marker.isEmpty || isMarkerSequence(marker) { return nil }
        if hallucinatedCredits.contains(where: { marker.contains($0) }) { return nil }
        return text
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// 判断整段文本是否只由音效词重复拼接而成，例如“掌声掌声”“applauseapplause”。
    private static func isMarkerSequence(_ value: String) -> Bool {
        let characters = Array(value)
        var reachable = Array(repeating: false, count: characters.count + 1)
        reachable[0] = true
        for start in 0..<characters.count where reachable[start] {
            for marker in ignoredMarkers {
                let end = start + marker.count
                if end <= characters.count, String(characters[start..<end]) == marker { reachable[end] = true }
            }
        }
        return reachable[characters.count]
    }
}

/// Whisper 单个识别段的质量指标，与 WhisperKit 的 TranscriptionSegment 字段对应。
struct RecognizedSegment {
    var text: String
    var avgLogprob: Float
    var compressionRatio: Float
    var noSpeechProb: Float
}

enum SpeechSegmentFilter {
    /// The decoder already retries low-confidence output. Apply confidence to the
    /// whole utterance, rather than deleting individual uncertain words from it.
    static let minimumAverageLogprob: Float = -1.0
    static let maximumCompressionRatio: Float = 2.4
    /// WhisperKit 1.1.0 的 noSpeechProb 恒为 0（TextDecoder 中标注为 TODO），
    /// 这一项目前不会生效；保留是为了升级到实现了该值的版本后自动起作用。
    static let maximumNoSpeechProb: Float = 0.6

    static func isSpeech(_ segment: RecognizedSegment) -> Bool {
        guard segment.avgLogprob.isFinite, segment.compressionRatio.isFinite else { return false }
        if segment.noSpeechProb > maximumNoSpeechProb && segment.avgLogprob < minimumAverageLogprob { return false }
        if segment.compressionRatio > maximumCompressionRatio { return false }
        return RecognizedSpeechText.cleaned(segment.text) != nil
    }

    static func joinedText(_ segments: [RecognizedSegment]) -> String {
        let candidates = segments.filter(isSpeech)
        let totalWeight = candidates.reduce(0) { $0 + max(1, $1.text.count) }
        guard totalWeight > 0 else { return "" }
        let confidence = candidates.reduce(Float(0)) {
            $0 + $1.avgLogprob * Float(max(1, $1.text.count))
        } / Float(totalWeight)
        guard confidence >= minimumAverageLogprob else { return "" }
        return SpeechTextJoiner.join(candidates.map(\.text))
    }
}
