import AVFoundation
import Foundation
import Speech

struct ConfirmedSpeechPrefix: Equatable, Sendable {
    let text: String
    let sampleCount: Int
}

struct SpeechRecognitionUpdate: Sendable {
    let text: String
    let language: String
    var confirmedPrefix: ConfirmedSpeechPrefix? = nil
}

/// 按音频时间替换临时假设；最终结果不会与它之前的临时结果重复拼接。
struct RecognitionTimeline {
    struct Piece {
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool
    }
    private(set) var pieces: [Piece] = []

    mutating func receive(_ piece: Piece) {
        guard piece.start.isFinite, piece.end.isFinite,
              piece.start >= 0, piece.end > piece.start, !piece.text.isEmpty else { return }
        if !piece.isFinal, pieces.contains(where: {
            $0.isFinal && $0.start < piece.end && $0.end > piece.start
        }) { return }
        pieces.removeAll { $0.start < piece.end && $0.end > piece.start }
        pieces.append(piece)
        pieces.sort { $0.start < $1.start }
    }

    var text: String { Self.join(pieces.map(\.text)) }

    /// 只提交系统已确认、且有句末标点的前缀。临时字幕绝不作为最终译文播出。
    var confirmedPrefix: ConfirmedSpeechPrefix? {
        let confirmed = Array(pieces.prefix { $0.isFinal })
        guard let boundary = confirmed.lastIndex(where: {
            guard let last = $0.text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
            return ".!?。！？".contains(last)
        }) else { return nil }
        let prefix = Array(confirmed[...boundary])
        guard let end = prefix.last?.end, end >= 0.2,
              let text = RecognizedSpeechText.cleaned(Self.join(prefix.map(\.text))) else { return nil }
        return ConfirmedSpeechPrefix(text: text, sampleCount: Int(ceil(end * 16_000)))
    }

    static func join(_ parts: [String]) -> String {
        SpeechTextJoiner.join(parts)
    }
}

@MainActor
protocol IncrementalSpeechSession: AnyObject {
    func update(_ samples: [Float], final: Bool) async throws -> SpeechRecognitionUpdate
    func cancel()
}

/// 累积窗口只发送新增样本；结束时冲刷重采样器，避免遗漏仍在滤波缓冲中的尾音。
@MainActor
final class StreamingPCMInput {
    struct Packet {
        let buffer: AVAudioPCMBuffer
        let startTime: CMTime
    }
    private let sourceFormat: AVAudioFormat
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private var submittedSamples = 0
    private var emittedFrames: Int64 = 0
    private var ended = false

    init(format: AVAudioFormat) throws {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else { throw TranslatorError.recordingFailed }
        sourceFormat = source
        self.format = format
        if source == format { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: source, to: format) else { throw TranslatorError.recordingFailed }
            self.converter = converter
        }
    }

    func append(_ samples: [Float], final: Bool) throws -> [Packet] {
        guard !ended, samples.count >= submittedSamples else { throw TranslatorError.recordingFailed }
        let count = samples.count - submittedSamples
        let added = samples[submittedSamples...]
        guard added.allSatisfy(\.isFinite) else { throw TranslatorError.recordingFailed }
        var buffer: AVAudioPCMBuffer?
        if count > 0 {
            guard let next = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = next.floatChannelData?[0] else { throw TranslatorError.recordingFailed }
            next.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + submittedSamples, count: count)
            }
            buffer = next
        }
        var packets: [Packet] = []
        func emit(_ next: AVAudioPCMBuffer) {
            guard next.frameLength > 0 else { return }
            packets.append(Packet(buffer: next,
                startTime: CMTime(value: emittedFrames, timescale: Int32(format.sampleRate))))
            emittedFrames += Int64(next.frameLength)
        }
        if let converter, count > 0 || final {
            var supplied = false
            while true {
                let capacity = AVAudioFrameCount(ceil(Double(count) * format.sampleRate / 16_000)) + 256
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw TranslatorError.recordingFailed
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    if !supplied, let buffer {
                        supplied = true
                        state.pointee = .haveData
                        return buffer
                    }
                    state.pointee = final ? .endOfStream : .noDataNow
                    return nil
                }
                if let conversionError { throw conversionError }
                if status == .error { throw TranslatorError.recordingFailed }
                emit(output)
                if status != .haveData { break }
                guard output.frameLength > 0 else { throw TranslatorError.recordingFailed }
            }
        } else if let buffer { emit(buffer) }
        submittedSamples = samples.count
        ended = final
        return packets
    }
}

/// 每个录音窗口只增量送入新增音频。系统资源未安装或引擎出错时，用完整原音频回退。
@MainActor
final class AdaptiveSpeechRecognizer {
    typealias NativeFactory = (String) async throws -> (any IncrementalSpeechSession)?
    private let fallback: ([Float], String?, String) async throws -> (text: String, language: String)
    private let detect: ([Float]) async throws -> String?
    private let nativeFactory: NativeFactory
    private var native: (any IncrementalSpeechSession)?
    private var nativeLanguage: String?
    private var triedLanguage: String?
    private var detectedLanguage: String?
    private var configuredLanguage: String?
    private var languageConfigured = false
    private var lastDetectionSamples = 0
    private var generation = UUID()
    private var context = ""
    private var contextLanguage: String?

    init(fallback: @escaping ([Float], String?, String) async throws -> (text: String, language: String),
         detect: @escaping ([Float]) async throws -> String?,
         nativeFactory: @escaping NativeFactory = { try await AppleSpeechSession.make(language: $0) }) {
        self.fallback = fallback
        self.detect = detect
        self.nativeFactory = nativeFactory
    }

    func recognize(_ samples: [Float], language: String?, final: Bool) async throws -> SpeechRecognitionUpdate {
        if languageConfigured, configuredLanguage != language { resetWindow() }
        configuredLanguage = language
        languageConfigured = true
        let activeGeneration = generation
        if language == nil, detectedLanguage == nil, samples.count >= 12_800,
           lastDetectionSamples == 0 || samples.count - lastDetectionSamples >= 16_000 {
            lastDetectionSamples = samples.count
            let detected = try? await detect(samples)
            guard generation == activeGeneration else { throw CancellationError() }
            detectedLanguage = detected
        }
        let selected = language ?? detectedLanguage
        if let selected, triedLanguage != selected {
            triedLanguage = selected
            do {
                let candidate = try await nativeFactory(selected)
                guard generation == activeGeneration else { candidate?.cancel(); throw CancellationError() }
                native = candidate
                nativeLanguage = candidate == nil ? nil : selected
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard generation == activeGeneration else { throw CancellationError() }
                native = nil
            }
        }
        let update: SpeechRecognitionUpdate
        if let native {
            do {
                update = try await AsyncDeadline<SpeechRecognitionUpdate>.run(timeout: .seconds(final ? 8 : 3)) {
                    try await native.update(samples, final: final)
                }
                guard generation == activeGeneration else { throw CancellationError() }
                // 最终没有可用文本时，原音频仍在，允许回退识别而不是直接丢弃。
                if final && RecognizedSpeechText.cleaned(update.text) == nil {
                    native.cancel()
                    self.native = nil
                    return try await recognizeFallback(samples, language: language, final: true,
                                                       generation: activeGeneration)
                }
            } catch {
                guard generation == activeGeneration, !(error is CancellationError) else { throw CancellationError() }
                native.cancel()
                self.native = nil
                return try await recognizeFallback(samples, language: language, final: final,
                                                   generation: activeGeneration)
            }
        } else {
            return try await recognizeFallback(samples, language: language, final: final,
                                               generation: activeGeneration)
        }
        if final {
            remember(update.text, language: update.language)
            resetWindow()
        }
        return update
    }

    private func recognizeFallback(_ samples: [Float], language: String?, final: Bool,
                                   generation token: UUID) async throws -> SpeechRecognitionUpdate {
        let selected = language ?? detectedLanguage
        let prior = selected != nil && selected == contextLanguage ? context : ""
        let result = try await fallback(samples, language, prior)
        guard generation == token else { throw CancellationError() }
        if final {
            remember(result.text, language: result.language)
            resetWindow()
        }
        return SpeechRecognitionUpdate(text: result.text, language: result.language)
    }

    func commit(_ prefix: ConfirmedSpeechPrefix, language: String) {
        remember(prefix.text, language: language)
        resetWindow()
    }

    private func remember(_ text: String, language: String) {
        guard let cleaned = RecognizedSpeechText.cleaned(text) else { return }
        if contextLanguage != language { context = "" }
        contextLanguage = language
        context = String((context + " " + cleaned).suffix(800))
    }

    func resetWindow() {
        generation = UUID()
        native?.cancel()
        native = nil
        nativeLanguage = nil
        triedLanguage = nil
        detectedLanguage = nil
        configuredLanguage = nil
        languageConfigured = false
        lastDetectionSamples = 0
    }

    func reset() {
        resetWindow()
        context = ""
        contextLanguage = nil
    }
}

@MainActor
final class AppleSpeechSession: IncrementalSpeechSession {
    private let language: String
    private let analyzer: SpeechAnalyzer
    private let audioInput: StreamingPCMInput
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var resultTask: Task<Void, Never>?
    private var timeline = RecognitionTimeline()
    private var resultError: Error?
    private var cancelled = false

    static func installedTranscriber(language: String) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        return await AssetInventory.status(forModules: [transcriber]) == .installed ? transcriber : nil
    }

    static func make(language: String) async throws -> AppleSpeechSession? {
        // 不因切换引擎弹出下载；已有系统语音资源直接复用，否则回退。
        guard let transcriber = await installedTranscriber(language: language),
              let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000, channels: 1, interleaved: false),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                        considering: sourceFormat) else { return nil }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                     options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let session = try AppleSpeechSession(language: language, analyzer: analyzer, format: format,
                                             input: continuation)
        session.resultTask = Task { @MainActor [weak session] in
            do {
                for try await result in transcriber.results {
                    guard let session, !session.cancelled else { return }
                    session.timeline.receive(.init(start: result.range.start.seconds,
                        end: result.range.end.seconds, text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch { session?.resultError = error }
        }
        do { try await analyzer.start(inputSequence: stream) }
        catch { session.cancel(); throw error }
        return session
    }

    private init(language: String, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.language = language
        self.analyzer = analyzer
        audioInput = try StreamingPCMInput(format: format)
        self.input = input
    }

    func update(_ samples: [Float], final: Bool) async throws -> SpeechRecognitionUpdate {
        guard !cancelled else { throw CancellationError() }
        for packet in try audioInput.append(samples, final: final) {
            input.yield(AnalyzerInput(buffer: packet.buffer, bufferStartTime: packet.startTime))
        }
        if final {
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
        } else { await Task.yield() }
        guard !cancelled else { throw CancellationError() }
        if let resultError { throw resultError }
        return SpeechRecognitionUpdate(text: timeline.text, language: language,
                                       confirmedPrefix: final ? nil : timeline.confirmedPrefix)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        input.finish()
        resultTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
