import Foundation
import NaturalLanguage
import SherpaOnnx

/// Download once into Application Support; incomplete downloads never become model files.
@MainActor
final class SherpaSpeech {
    private var engine: SherpaStreamingEngine?
    private var preparation: Task<SherpaStreamingEngine, Error>?
    static func supports(_ language: String?) -> Bool { language == nil || language == "en" || language == "zh" }

    func prepare() async throws {
        if engine != nil { return }
        if let preparation { engine = try await preparation.value; return }
        let task = Task<SherpaStreamingEngine, Error> {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SherpaZipformer-zh-en")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files: [(String, Int)] = [
                ("encoder-epoch-99-avg-1.int8.onnx", 181895032),
                ("decoder-epoch-99-avg-1.onnx", 13876452),
                ("joiner-epoch-99-avg-1.int8.onnx", 3228404), ("tokens.txt", 56317)
            ]
            for (name, size) in files {
                try Task.checkCancellation()
                let path = directory.appendingPathComponent(name)
                if (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size { continue }
                let url = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main/\(name)")!
                let (temporary, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else {
                    throw URLError(.badServerResponse)
                }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                try FileManager.default.moveItem(at: temporary, to: path)
            }
            return try await SherpaStreamingEngine.make(directory: directory)
        }
        preparation = task
        defer { preparation = nil }
        engine = try await task.value
    }

    func recognize(_ samples: [Float], language: String?, final: Bool) async throws -> SpeechRecognitionUpdate {
        try await prepare()
        guard let engine else { throw TranslatorError.modelUnavailable }
        return try await engine.update(samples, language: language, final: final)
    }
    func reset() { if let engine { Task { await engine.reset() } } }
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
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: directory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path,
            decoder: directory.appendingPathComponent("decoder-epoch-99-avg-1.onnx").path,
            joiner: directory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path)
        let model = sherpaOnnxOnlineModelConfig(tokens: directory.appendingPathComponent("tokens.txt").path,
            transducer: transducer, numThreads: 2, modelType: "zipformer")
        var config = sherpaOnnxOnlineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: model, decodingMethod: "modified_beam_search", maxActivePaths: 4)
        recognizer = SherpaOnnxRecognizer(config: &config)
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
        let text = recognizer.getResult().text
        let detected = language ?? (NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue.hasPrefix("zh") == true ? "zh" : "en")
        if final { reset() }
        return SpeechRecognitionUpdate(text: text, language: detected)
    }
    func reset() { recognizer?.reset(); submitted = 0 }
}
