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
    @Published private(set) var canUndoDelete = false
    private var deletedItems: [SavedConversation] = []
    private var summaryRevisions: [UUID: UUID] = [:]
    private let summarize: @MainActor ([TranscriptLine]) async -> String

    init(directory: URL? = nil,
         summarize: (@MainActor ([TranscriptLine]) async -> String)? = nil) {
        self.summarize = summarize ?? { lines in await ConversationSummarizer.summarize(lines) }
        let directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    func save(_ lines: [TranscriptLine], id: UUID? = nil, outline: SummaryOutline? = nil) async throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        guard !lines.isEmpty else { return }
        let lineIDs = lines.map(\.id)
        if let match = conversations.first(where: { Self.sameContent($0.lines, lines) && (id == nil || $0.id == id) }) {
            if let outline { try updateOutline(outline, id: match.id, lines: lines) }
            return
        }
        var updated = conversations
        let recordID: UUID
        if let index = updated.firstIndex(where: { id != nil ? $0.id == id : $0.lines.map(\.id) == lineIDs }) {
            recordID = updated[index].id
            updated[index].lines = lines
            updated[index].outline = outline
        } else {
            let record = SavedConversation(id: id ?? UUID(), lines: lines,
                                           summary: String((lines.first?.translated ?? "").prefix(200)), outline: outline)
            recordID = record.id
            updated.insert(record, at: 0)
        }
        try persist(updated)
        conversations = updated
        let revision = UUID()
        summaryRevisions[recordID] = revision
        let summarize = self.summarize
        Task { [weak self] in
            let summary = await summarize(lines)
            guard let self, self.summaryRevisions[recordID] == revision,
                  let index = self.conversations.firstIndex(where: { $0.id == recordID }),
                  Self.sameContent(self.conversations[index].lines, lines) else { return }
            var refreshed = self.conversations
            refreshed[index].summary = summary
            do {
                try self.persist(refreshed)
                self.conversations = refreshed
            } catch { /* 正文已保存，摘要失败不影响记录。 */ }
            self.summaryRevisions[recordID] = nil
        }
    }

    func updateOutline(_ outline: SummaryOutline, id: UUID, lines: [TranscriptLine]) throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              Self.sameContent(conversations[index].lines, lines) else { return }
        var updated = conversations
        updated[index].outline = outline
        try persist(updated)
        conversations = updated
    }

    private static func sameContent(_ left: [TranscriptLine], _ right: [TranscriptLine]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { pair in
            let (a, b) = pair
            return a.id == b.id && a.original == b.original && a.translated == b.translated &&
            a.sourceLanguage == b.sourceLanguage && a.targetLanguage == b.targetLanguage && a.isMine == b.isMine
        }
    }

    func delete(_ ids: Set<UUID>) throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        let updated = conversations.filter { !ids.contains($0.id) }
        try persist(updated)
        deletedItems = conversations.filter { ids.contains($0.id) }
        for id in ids { summaryRevisions[id] = nil }
        canUndoDelete = !deletedItems.isEmpty
        conversations = updated
    }

    func undoDelete() throws {
        guard loadError == nil else { throw ConversationStoreError.unreadableHistory }
        let existingIDs = Set(conversations.map(\.id))
        let restored = (conversations + deletedItems.filter { !existingIDs.contains($0.id) })
            .sorted { $0.date > $1.date }
        try persist(restored)
        conversations = restored
        deletedItems = []
        canUndoDelete = false
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
        let options = DecodingOptions(language: language, detectLanguage: language == nil,
                                      skipSpecialTokens: true, suppressBlank: true)
        let results = try await model.transcribe(audioArray: samples, decodeOptions: options)
        // 逐段按置信度过滤，不再直接拼接模型整段文本：静音和环境声产生的
        // “掌声”“空白音频”等低置信度或重复段落不会进入翻译和播报。
        let segments = results.flatMap(\.segments).map {
            RecognizedSegment(text: $0.text, avgLogprob: $0.avgLogprob,
                              compressionRatio: $0.compressionRatio, noSpeechProb: $0.noSpeechProb)
        }
        let text = SpeechSegmentFilter.joinedText(segments)
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
enum TranslationConfigurationFactory {
    static func make(source: String, target: String, mode: ProcessingMode) -> TranslationSession.Configuration {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            return TranslationSession.Configuration(
                source: sourceLanguage, target: targetLanguage,
                preferredStrategy: mode == .quality ? .highFidelity : .lowLatency
            )
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }
}

@MainActor
final class LocalTranslator {
    func translate(_ text: String, from source: String, to target: String,
                   mode: ProcessingMode, preparedSession: TranslationSession? = nil) async throws -> String {
        if source == target { return text }
        let session: TranslationSession
        if let preparedSession {
            session = preparedSession
        } else {
            let sourceLanguage = Locale.Language(identifier: source)
            let targetLanguage = Locale.Language(identifier: target)
            let availability: LanguageAvailability
            if #available(iOS 26.4, *) {
                let strategy: TranslationSession.Strategy = mode == .quality ? .highFidelity : .lowLatency
                availability = LanguageAvailability(preferredStrategy: strategy)
            } else {
                availability = LanguageAvailability()
            }
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            switch status {
            case .installed: break
            case .supported: throw TranslatorError.languagePackRequired(source, target)
            case .unsupported: throw TranslatorError.unsupportedPair
            @unknown default: throw TranslatorError.unsupportedPair
            }
            if #available(iOS 26.4, *) {
                let strategy: TranslationSession.Strategy = mode == .quality ? .highFidelity : .lowLatency
                session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage,
                                             preferredStrategy: strategy)
            } else {
                session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            }
        }
        let response = try await session.translate(text)
        return response.targetText
    }
}

@MainActor
final class AudioCapture: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private(set) var recordingID: UUID?
    @Published private(set) var level: Float = 0
    var onPartial: (([Float]) -> Void)?
    var onUtterance: (([Float]) -> Void)?
    var nearField = true
    var quality = false
    /// 同传和对话均等待句末停顿；同传保留实时预览，并限制连续无停顿音频的窗口。
    var liveSegmentation = false
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var beganSpeaking = false
    private var voicedSampleCount = 0
    /// 当前句末尾连续非语音的样本数。按样本而不是按墙钟计时，
    /// 屏幕广播成批送来的音频也能得到正确的静音时长。
    private var silentSampleCount = 0
    /// samples 中最后一个语音帧结束的位置，用于裁掉句尾长静音。
    private var lastVoicedEnd = 0
    private var samplesSincePartial = 0
    /// 环境底噪估计（dB）。持续的风扇声、空调声会逐渐抬高底噪，不再被当成说话。
    private var noiseFloor: Float = -60

    private static let sampleRate = 16_000
    private static let frameLength = 320                 // 20 ms
    private static let minimumVoicedSamples = 3_200      // 累计至少 0.2 秒语音才算一句话
    private static let preRollSamples = 8_000            // 开口前保留 0.5 秒
    private static let trailingSilenceKept = 4_800       // 句尾保留 0.3 秒，避免模型在长静音上编造内容
    private static let noiseMargin: Float = 12           // 高于底噪 12 dB 才算语音
    private static let liveCutSearchWindow = 24_000      // 同传：达到上限时在最近 1.5 秒内找切点
    /// 当前句每帧的结束位置和音量，用于在连续讲话中找安静处切句。
    private var frameLevels: [(end: Int, decibels: Float)] = []

    func startExternal() {
        guard !isRecording else { return }
        recordingID = UUID()
        isRecording = true
        resetUtterance()
        samples = []
        noiseFloor = -60
    }

    private func resetUtterance() {
        beganSpeaking = false
        voicedSampleCount = 0
        silentSampleCount = 0
        lastVoicedEnd = 0
        samplesSincePartial = 0
        frameLevels = []
    }

    func feedExternal(_ chunk: [Float]) {
        guard let recordingID else { return }
        receive(chunk, recordingID: recordingID)
    }

    /// 录音线程已经排队的旧回调，不能在停止后重新启动时进入新录音。
    func receive(_ chunk: [Float], recordingID: UUID) {
        guard self.recordingID == recordingID else { return }
        append(chunk)
    }

    func start() throws {
        guard !isRecording else { return }
        let recordingID = UUID()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: nearField ? .voiceChat : .default,
                                options: [.allowBluetoothA2DP])
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
            Task { @MainActor [weak self] in self?.receive(chunk, recordingID: recordingID) }
        }
        do { try next.start() }
        catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = next
        resetUtterance()
        samples = []
        noiseFloor = -60
        self.recordingID = recordingID
        isRecording = true
    }

    func stop() {
        recordingID = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        level = 0
        samples = []
        resetUtterance()
    }

    func takePendingSpeech() -> [Float]? {
        guard beganSpeaking, voicedSampleCount >= Self.minimumVoicedSamples else { return nil }
        let utterance = trimmedUtterance()
        samples = []
        resetUtterance()
        return utterance
    }

    /// 去掉句尾超过 0.3 秒的静音。Whisper 在长静音上容易编造“谢谢观看”“掌声”等内容。
    private func trimmedUtterance() -> [Float] {
        let end = min(samples.count, lastVoicedEnd + Self.trailingSilenceKept)
        return Array(samples[..<end])
    }

    private func append(_ chunk: [Float]) {
        guard isRecording, !chunk.isEmpty else { return }
        let energy = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        level = max(0, min(1, (Self.decibels(energy) + 55) / 55))
        // 按 20 ms 帧判断，避免一个大块里的短促响声被整体算作语音。
        for start in stride(from: 0, to: chunk.count, by: Self.frameLength) {
            appendFrame(chunk[start..<min(start + Self.frameLength, chunk.count)])
        }
    }

    private func appendFrame(_ frame: ArraySlice<Float>) {
        let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
        let db = Self.decibels(rms)
        let absoluteThreshold: Float = nearField ? -35 : -42
        let voiced = db > max(absoluteThreshold, noiseFloor + Self.noiseMargin)
        // 底噪快速下降、缓慢上升（约 6 秒追上持续噪声），说话间隙会把它拉回真实底噪。
        let rate: Float = db < noiseFloor ? 0.3 : 0.003
        noiseFloor = min(-20, max(-90, noiseFloor + (db - noiseFloor) * rate))

        samples.append(contentsOf: frame)
        if voiced {
            if !beganSpeaking { beganSpeaking = true; samplesSincePartial = 0 }
            voicedSampleCount += frame.count
            silentSampleCount = 0
            lastVoicedEnd = samples.count
        } else if beganSpeaking {
            silentSampleCount += frame.count
        }
        guard beganSpeaking else {
            if samples.count > Self.preRollSamples { samples.removeFirst(samples.count - Self.preRollSamples) }
            return
        }
        samplesSincePartial += frame.count
        frameLevels.append((end: samples.count, decibels: db))
        let hasEnoughSpeech = voicedSampleCount >= Self.minimumVoicedSamples
        let silenceLimit = Int(Double(Self.sampleRate) * (quality ? 1.5 : 1.2))
        let maximumSamples = liveSegmentation
            ? Self.sampleRate * (quality ? 28 : 8)
            : Self.sampleRate * (quality ? 30 : 20)
        let partialInterval = Int(Double(Self.sampleRate) * (quality ? 1.8 : 1.2))
        // 换气不等于句末。预览可持续刷新，最终翻译和播报必须等完整停顿。
        // 质量档允许在 Whisper 的 30 秒音频窗口内保留更长的演讲句子。
        if silentSampleCount > silenceLimit {
            // 一句结束。累计语音不足 0.2 秒视为噪声（拍手、碰撞），直接丢弃，不送识别。
            let utterance = hasEnoughSpeech ? trimmedUtterance() : nil
            samples = []
            resetUtterance()
            if let utterance { onUtterance?(utterance) }
        } else if samples.count >= maximumSamples {
            guard hasEnoughSpeech else {
                samples = []
                resetUtterance()
                return
            }
            if liveSegmentation, let cut = quietestRecentCut() {
                splitUtterance(at: cut)
            } else {
                let utterance = samples
                samples = []
                resetUtterance()
                onUtterance?(utterance)
            }
        } else if hasEnoughSpeech, samplesSincePartial >= partialInterval {
            samplesSincePartial = 0
            onPartial?(samples)
        }
    }

    /// 连续讲话达到单句上限时，在最近 1.5 秒内最安静的一帧处切开，尽量不把一个词切成两半。
    private func quietestRecentCut() -> Int? {
        let earliest = samples.count - Self.liveCutSearchWindow
        let candidates = frameLevels.filter { $0.end >= max(earliest, Self.minimumVoicedSamples) && $0.end < samples.count }
        return candidates.min { $0.decibels < $1.decibels }?.end
    }

    /// 发出切点之前的部分，切点之后的音频留作下一句的开头。
    private func splitUtterance(at cut: Int) {
        let utterance = Array(samples[..<cut])
        let rest = Array(samples[cut...])
        let restLevels = frameLevels.filter { $0.end > cut }.map { (end: $0.end - cut, decibels: $0.decibels) }
        samples = rest
        resetUtterance()
        beganSpeaking = true
        voicedSampleCount = rest.count
        lastVoicedEnd = rest.count
        frameLevels = restLevels
        onUtterance?(utterance)
    }

    private static func decibels(_ rms: Float) -> Float {
        20 * log10(max(rms, 0.00001))
    }
}

@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completions: [() -> Void] = []
    private(set) var isPlaying = false
    private var activeUtteranceID: ObjectIdentifier?
    private var queuedUtteranceIDs = Set<ObjectIdentifier>()
    override init() { super.init(); synthesizer.delegate = self }

    /// 当前输出是否为耳机类设备（AirPods、蓝牙耳机、有线耳机）。
    static var headphonesConnected: Bool {
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    /// 沿用正在收音的耳机会话，把译文加入系统朗读队列，保留原有句子的播放顺序。
    @discardableResult
    func enqueue(_ text: String, language: String, rate: Float) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(language: language) ??
                AVSpeechSynthesisVoice.speechVoices().first(where: {
                    AppLanguage.normalizedCode($0.language) == language
                }) else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        queuedUtteranceIDs.insert(ObjectIdentifier(utterance))
        isPlaying = true
        synthesizer.speak(utterance)
        return true
    }

    /// - Parameter keepInputActive: 为 true 时沿用录音中的 playAndRecord 会话，不切换音频类别，
    ///   这样播报译文的同时麦克风继续收音。只应在输出到耳机时使用，外放会把译文录回去。
    @discardableResult
    func speak(_ text: String, language: String, rate: Float, destination: AudioDestination,
               keepInputActive: Bool = false, done: @escaping () -> Void) -> Bool {
        // 替换播放时保留完成回调，等最后一条语音结束才恢复收音。
        isPlaying = true
        activeUtteranceID = nil
        queuedUtteranceIDs.removeAll()
        completions.append(done)
        synthesizer.stopSpeaking(at: .immediate)
        guard let voice = AVSpeechSynthesisVoice(language: language) ??
                AVSpeechSynthesisVoice.speechVoices().first(where: {
                    AppLanguage.normalizedCode($0.language) == language
                }) else {
            finish()
            return false
        }
        let session = AVAudioSession.sharedInstance()
        if keepInputActive {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = rate
            activeUtteranceID = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
            return true
        }
        do {
            if destination == .earphones {
                // Playback follows the system's selected headphones / AirPods route.
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            } else {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.allowBluetoothA2DP, .defaultToSpeaker])
            }
            try session.setActive(true)
        } catch {
            finish()
            return false
        }
        do {
            if destination == .speaker { try session.overrideOutputAudioPort(.speaker) }
        } catch {
            finish()
            return false
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
        queuedUtteranceIDs.removeAll()
        isPlaying = false
        let callbacks = completions
        completions = []
        for callback in callbacks { callback() }
    }

    private func completed(_ id: ObjectIdentifier) {
        if queuedUtteranceIDs.remove(id) != nil {
            isPlaying = activeUtteranceID != nil || !queuedUtteranceIDs.isEmpty
        } else if activeUtteranceID == id {
            activeUtteranceID = nil
            isPlaying = !queuedUtteranceIDs.isEmpty
            let callbacks = completions
            completions = []
            for callback in callbacks { callback() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            completed(id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            completed(id)
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
