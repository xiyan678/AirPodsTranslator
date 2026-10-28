import AVFoundation
import Combine
import Foundation
import FoundationModels
import PhotosUI
import Translation
import Vision
import WatchConnectivity
import WhisperKit

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [SavedConversation] = []
    @Published private(set) var loadError: String?
    private let file: URL

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = directory.appendingPathComponent("conversations.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                conversations = try JSONDecoder().decode([SavedConversation].self, from: data)
            } catch {
                loadError = "对话记录无法读取，原文件已保留。"
            }
        }
    }

    func save(_ lines: [TranscriptLine]) async throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        guard !lines.isEmpty else { return }
        let lineIDs = lines.map(\.id)
        if conversations.contains(where: { Self.sameContent($0.lines, lines) }) { return }
        let summary = await ConversationSummarizer.summarize(lines)
        if conversations.contains(where: { Self.sameContent($0.lines, lines) }) { return }
        var updated = conversations
        if let index = updated.firstIndex(where: { $0.lines.map(\.id) == lineIDs }) {
            updated[index].lines = lines
            updated[index].summary = summary
        } else {
            updated.insert(SavedConversation(lines: lines, summary: summary), at: 0)
        }
        try persist(updated)
        conversations = updated
    }

    private static func sameContent(_ left: [TranscriptLine], _ right: [TranscriptLine]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { pair in
            let (a, b) = pair
            a.id == b.id && a.original == b.original && a.translated == b.translated &&
            a.sourceLanguage == b.sourceLanguage && a.targetLanguage == b.targetLanguage && a.isMine == b.isMine
        }
    }

    func delete(_ ids: Set<UUID>) throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        let updated = conversations.filter { !ids.contains($0.id) }
        try persist(updated)
        conversations = updated
    }

    private func persist(_ items: [SavedConversation]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: file, options: .atomic)
    }
}

enum ConversationStoreError: LocalizedError {
    case unreadableHistory
    var errorDescription: String? { "对话记录文件无法读取，请先备份原文件。" }
}

@MainActor
enum ConversationSummarizer {
    static func summarize(_ lines: [TranscriptLine]) async -> String {
        let transcript = lines.map { $0.translated }.joined(separator: "\n")
        if SystemLanguageModel.default.isAvailable {
            do {
                let characters = Array(transcript)
                var summary = ""
                for offset in stride(from: 0, to: characters.count, by: 2_500) {
                    let chunk = String(characters[offset..<min(offset + 2_500, characters.count)])
                    let prompt = summary.isEmpty ? chunk : "已有摘要：\n\(summary)\n新增对话：\n\(chunk)"
                    let session = LanguageModelSession(instructions: "用中文概括完整对话的主题、重要事实和待办事项。合并已有摘要与新增对话，只根据提供的内容总结，不编造信息，最多三句话。")
                    let response = try await session.respond(to: prompt)
                    summary = String(response.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
                }
                if !summary.isEmpty { return summary }
            } catch {}
        }
        return extractiveSummary(lines)
    }

    private static func extractiveSummary(_ lines: [TranscriptLine]) -> String {
        let sentences = lines.map(\.translated).filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return "" }
        let tokens = sentences.map { sentence in
            let characters = Array(sentence.lowercased().filter { $0.isLetter || $0.isNumber })
            return Set(zip(characters, characters.dropFirst()).map { String([$0.0, $0.1]) })
        }
        var frequency: [String: Int] = [:]
        for words in tokens { for word in words { frequency[word, default: 0] += 1 } }
        let ranked = sentences.indices.sorted { leftIndex, rightIndex in
            let leftScore = tokens[leftIndex].reduce(0) { score, word in score + frequency[word, default: 0] }
            let rightScore = tokens[rightIndex].reduce(0) { score, word in score + frequency[word, default: 0] }
            return leftScore > rightScore
        }
        let selected = Set(ranked.prefix(min(3, sentences.count)))
        return sentences.indices.filter { selected.contains($0) }
            .map { String(sentences[$0].prefix(120)) }.joined(separator: " · ")
    }
}

@MainActor
final class WhisperService: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadStage = "尚未下载语音模型"
    private var model: WhisperKit?

    func prepare() async throws {
        if model != nil { return }
        if loading {
            while loading { try await Task.sleep(for: .milliseconds(200)) }
            guard model != nil else { throw TranslatorError.modelUnavailable }
            return
        }
        loading = true
        defer { loading = false }
        downloadStage = "正在检查语音模型…"
        do {
            downloading = true
            let folder = try await WhisperKit.download(variant: "base") { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.downloading else { return }
                    self.downloadStage = "正在下载语音模型…"
                    self.downloadProgress = fraction.isFinite ? max(0, min(1, fraction)) : nil
                }
            }
            downloading = false
            downloadStage = "正在载入语音模型…"
            downloadProgress = nil
            model = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true, download: false))
            ready = true
            downloadStage = "语音模型已就绪"
        } catch {
            downloading = false
            downloadStage = "语音模型下载或载入失败"
            downloadProgress = nil
            throw error
        }
    }

    func recognize(_ samples: [Float], language: String? = nil) async throws -> (text: String, language: String) {
        try await prepare()
        guard let model else { throw TranslatorError.modelUnavailable }
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        let results = try await model.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = results.first?.language ?? ""
        return (text, language)
    }
}

enum TranslatorError: LocalizedError {
    case modelUnavailable, unsupportedPair, emptyImageText, recordingFailed
    case languagePackRequired(String, String)
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "语音模型尚未就绪"
        case .unsupportedPair: "当前设备不支持这组离线翻译语言，请在语言包中查看"
        case .emptyImageText: "图片中没有识别到文字"
        case .recordingFailed: "录音启动失败"
        case .languagePackRequired: "需要下载对应的离线语言包"
        }
    }
}

@MainActor
final class LocalTranslator {
    private var translatedTerms: [String: String] = [:]

    func translate(_ text: String, from source: String, to target: String,
                   mode: ProcessingMode, terms: [Term]) async throws -> String {
        if source == target { return text }
        if let exact = terms.first(where: { $0.source.localizedCaseInsensitiveCompare(text) == .orderedSame }) {
            return exact.replacement
        }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let strategy: TranslationSession.Strategy = mode == .quality ? .highFidelity : .lowLatency
        let status = await LanguageAvailability(preferredStrategy: strategy)
            .status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed: break
        case .supported: throw TranslatorError.languagePackRequired(source, target)
        case .unsupported: throw TranslatorError.unsupportedPair
        @unknown default: throw TranslatorError.unsupportedPair
        }
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage,
                                         preferredStrategy: strategy)
        let response = try await session.translate(text)
        var translated = response.targetText
        for term in terms where !term.source.isEmpty &&
            text.range(of: term.source, options: .caseInsensitive) != nil {
            let key = "\(source)|\(target)|\(mode.rawValue)|\(term.source.lowercased())"
            let outputTerm: String
            if let cached = translatedTerms[key] {
                outputTerm = cached
            } else {
                guard let termTranslation = try? await session.translate(term.source) else { continue }
                outputTerm = termTranslation.targetText
                translatedTerms[key] = outputTerm
            }
            guard !outputTerm.isEmpty else { continue }
            translated = translated.replacingOccurrences(of: outputTerm, with: term.replacement,
                                                          options: .caseInsensitive)
        }
        return translated
    }
}

@MainActor
final class AudioCapture: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    var onPartial: (([Float]) -> Void)?
    var onUtterance: (([Float]) -> Void)?
    var nearField = true
    var quality = false
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var beganSpeaking = false
    private var silenceSince: Date?
    private var startedAt = Date()
    private var lastPartial = Date()

    func startExternal() {
        guard !isRecording else { return }
        isRecording = true
        samples = []
        beganSpeaking = false
        silenceSince = nil
    }

    func feedExternal(_ chunk: [Float]) { append(chunk) }

    func start() throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: nearField ? .voiceChat : .default,
                                options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let next = AVAudioEngine()
        let input = next.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TranslatorError.recordingFailed
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, output.frameLength > 0,
                  let channel = output.floatChannelData?.pointee else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            Task { @MainActor [weak self] in self?.append(chunk) }
        }
        do { try next.start() }
        catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = next
        isRecording = true
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        level = 0
        samples = []
        beganSpeaking = false
        silenceSince = nil
    }

    private func append(_ chunk: [Float]) {
        guard isRecording, !chunk.isEmpty else { return }
        let energy = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        let decibels = 20 * log10(max(energy, 0.00001))
        level = max(0, min(1, (decibels + 55) / 55))
        let audible = decibels > (nearField ? -35 : -42)
        samples.append(contentsOf: chunk)
        let now = Date()
        if audible {
            if !beganSpeaking { startedAt = now; lastPartial = now }
            beganSpeaking = true
            silenceSince = nil
        } else if beganSpeaking && silenceSince == nil {
            silenceSince = now
        }
        if !beganSpeaking {
            if samples.count > 8_000 { samples.removeFirst(samples.count - 8_000) }
            return
        }
        let silence = silenceSince.map { now.timeIntervalSince($0) } ?? 0
        let finished = (now.timeIntervalSince(startedAt) > 0.6 && silence > (quality ? 0.9 : 0.55))
            || samples.count >= 16_000 * (quality ? 15 : 10)
        if finished {
            let utterance = samples
            samples = []
            beganSpeaking = false
            silenceSince = nil
            onUtterance?(utterance)
        } else if now.timeIntervalSince(lastPartial) >= (quality ? 1.8 : 1.2) {
            lastPartial = now
            onPartial?(samples)
        }
    }
}

@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var activeUtteranceID: ObjectIdentifier?
    override init() { super.init(); synthesizer.delegate = self }

    @discardableResult
    func speak(_ text: String, language: String, rate: Float, destination: AudioDestination,
               done: @escaping () -> Void) -> Bool {
        finish()
        synthesizer.stopSpeaking(at: .immediate)
        guard let voice = AVSpeechSynthesisVoice(language: language) ??
                AVSpeechSynthesisVoice.speechVoices().first(where: {
                    AppLanguage.normalizedCode($0.language) == language
                }) else {
            done()
            return false
        }
        completion = done
        let session = AVAudioSession.sharedInstance()
        if destination == .speaker {
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            try? session.overrideOutputAudioPort(.none)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        activeUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        return true
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate); finish() }

    private func finish() {
        activeUtteranceID = nil
        let callback = completion
        completion = nil
        callback?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if activeUtteranceID == id { finish() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if activeUtteranceID == id { finish() }
        }
    }
}

enum PhotoOCR {
    static func recognize(_ data: Data) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: data)
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    var onCommand: ((String) -> Void)?
    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func publish(running: Bool, latest: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["running": running, "latest": latest])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        Task { @MainActor in onCommand?(command) }
    }
}
