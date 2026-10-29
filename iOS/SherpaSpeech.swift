import Foundation
import NaturalLanguage
import SherpaOnnx
import Combine

/// Download once into Application Support; incomplete downloads never become model files.
@MainActor
final class SherpaSpeech: ObservableObject {
    static let shared = SherpaSpeech()
    @Published private(set) var loading = false
    @Published private(set) var stage = ""
    @Published private(set) var lastError: String?
    static let files: [(String, Int)] = [
        ("encoder-epoch-99-avg-1.int8.onnx", 181895032),
        ("decoder-epoch-99-avg-1.onnx", 13876452),
        ("joiner-epoch-99-avg-1.int8.onnx", 3228404), ("tokens.txt", 56317)
    ]
    private static let checksums = [
        "encoder-epoch-99-avg-1.int8.onnx": "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b",
        "decoder-epoch-99-avg-1.onnx": "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d",
        "joiner-epoch-99-avg-1.int8.onnx": "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0",
        "tokens.txt": "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3"
    ]
    static func modelDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SherpaZipformer-zh-en")
    }
    static var installed: Bool {
        guard let directory = try? modelDirectory() else { return false }
        return files.allSatisfy { name, size in
            (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
        }
    }
    private var engine: SherpaStreamingEngine?
    private var preparation: Task<SherpaStreamingEngine, Error>?
    private var needsReset = false
    static func supports(_ language: String?) -> Bool { language == "en" || language == "zh" }

    func prepare() async throws {
        if engine != nil { return }
        if let preparation { engine = try await preparation.value; return }
        loading = true
        lastError = nil
        defer { loading = false }
        let task = Task<SherpaStreamingEngine, Error> {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let downloader = ModelFileDownloader(download: { url, resumeData in
                if let resumeData { return try await session.download(resumeFrom: resumeData) }
                return try await session.download(from: url)
            })
            let directory = try Self.modelDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, file) in Self.files.enumerated() {
                let (name, size) = file
                try Task.checkCancellation()
                let path = directory.appendingPathComponent(name)
                guard let checksum = Self.checksums[name] else { throw TranslatorError.modelUnavailable }
                if (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size {
                    self.stage = "正在校验中英语音模型（\(index + 1)/4）"
                    if try await ModelFileChecksum.matches(path, expected: checksum) { continue }
                }
                self.stage = "正在下载中英语音模型（\(index + 1)/\(Self.files.count)）"
                let url = URL(string: "https://download.duwang.win/models/sherpa-zh-en/\(name)")!
                let temporary: URL
                do {
                    temporary = try await downloader.fetch(url, expectedSize: size, expectedChecksum: checksum) { attempt in
                        self.stage = "网络中断，正在重试（\(attempt)/3；文件 \(index + 1)/4）"
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { throw ModelDownloadFailure.failed }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                try FileManager.default.moveItem(at: temporary, to: path)
            }
            self.stage = "正在载入中英语音模型…"
            return try await SherpaStreamingEngine.make(directory: directory)
        }
        preparation = task
        defer { preparation = nil }
        do {
            engine = try await task.value
            stage = "中英语音模型已就绪"
        } catch {
            lastError = error is CancellationError ? "已取消下载" : error.localizedDescription
            stage = "准备未完成"
            throw error
        }
    }

    func recognize(_ samples: [Float], language: String?, final: Bool) async throws -> SpeechRecognitionUpdate {
        try await prepare()
        try Task.checkCancellation()
        guard let engine else { throw TranslatorError.modelUnavailable }
        if needsReset { try await engine.reset(); needsReset = false }
        return try await engine.update(samples, language: language, final: final)
    }
    func reset() { needsReset = true }
}

@MainActor
final class SherpaSpeechSession: IncrementalSpeechSession {
    private let service: SherpaSpeech
    private let language: String
    private var cancelled = false
    init(service: SherpaSpeech, language: String) { self.service = service; self.language = language }
    func update(_ samples: [Float], final: Bool) async throws -> SpeechRecognitionUpdate {
        guard !cancelled else { throw CancellationError() }
        let result = try await service.recognize(samples, language: language, final: final)
        guard !cancelled else { throw CancellationError() }
        return result
    }
    func cancel() { cancelled = true; service.reset() }
}

/// Serial actor keeps ONNX inference off the UI thread and owns the incremental stream.
actor SherpaStreamingEngine {
    private var recognizer: SherpaOnnxRecognizer?
    private var submitted = 0
    static func make(directory: URL) async throws -> SherpaStreamingEngine {
        let engine = SherpaStreamingEngine()
        try await engine.load(directory)
        return engine
    }
    private func load(_ directory: URL) throws {
        let names = ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.onnx",
                     "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"]
        // C config holds borrowed pointers. Own every string until native creation returns.
        let values = names.map { directory.appendingPathComponent($0).path } +
            ["cpu", "zipformer", "modified_beam_search", "cjkchar", ""]
        var pointers: [UnsafeMutablePointer<CChar>] = []
        defer { pointers.forEach { free($0) } }
        for value in values {
            guard let pointer = strdup(value) else { throw TranslatorError.modelUnavailable }
            pointers.append(pointer)
        }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(pointers[0])
        config.model_config.transducer.decoder = UnsafePointer(pointers[1])
        config.model_config.transducer.joiner = UnsafePointer(pointers[2])
        config.model_config.tokens = UnsafePointer(pointers[3])
        config.model_config.num_threads = 2
        config.model_config.provider = UnsafePointer(pointers[4])
        config.model_config.model_type = UnsafePointer(pointers[5])
        config.decoding_method = UnsafePointer(pointers[6])
        config.model_config.modeling_unit = UnsafePointer(pointers[7])
        config.model_config.bpe_vocab = UnsafePointer(pointers[8])
        config.max_active_paths = 4
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 1.2
        config.rule3_min_utterance_length = 30
        recognizer = try SherpaOnnxRecognizer(config: &config)
    }

    func update(_ samples: [Float], language: String?, final: Bool) throws -> SpeechRecognitionUpdate {
        try Task.checkCancellation()
        guard let recognizer, samples.count >= submitted, samples.allSatisfy(\.isFinite) else {
            throw TranslatorError.recordingFailed
        }
        if samples.count > submitted { recognizer.acceptWaveform(samples: Array(samples.dropFirst(submitted))) }
        submitted = samples.count
        if final {
            recognizer.acceptWaveform(samples: Array(repeating: 0, count: 8_000))
            recognizer.inputFinished()
        }
        while recognizer.isReady() { try Task.checkCancellation(); recognizer.decode() }
        let text = try recognizer.getResult().text
        let detected = language ?? (NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue.hasPrefix("zh") == true ? "zh" : "en")
        if final { try reset() }
        return SpeechRecognitionUpdate(text: text, language: detected)
    }
    func reset() throws { try recognizer?.reset(); submitted = 0 }
}
