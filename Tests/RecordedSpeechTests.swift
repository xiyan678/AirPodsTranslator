import AVFoundation
import XCTest
import WhisperKit
@testable import AirPodsTranslator

@MainActor
final class RecordedSpeechTests: XCTestCase {
    func testSmallModelAgainstTheSameLectureAudio() async throws {
        guard let audio = Bundle(for: Self.self).url(forResource: "lecture", withExtension: "wav") else {
            throw XCTSkip("音频由专项语音回放工作流提供")
        }
        let file = try AVAudioFile(forReading: audio)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let folder = try await WhisperKit.download(variant: "small")
        let model = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true, download: false))
        let started = Date.timeIntervalSinceReferenceDate
        let results = try await model.transcribe(audioArray: samples, decodeOptions:
            DecodingOptions(language: "en", detectLanguage: false, skipSpecialTokens: true, suppressBlank: true))
        let actual = SpeechSegmentFilter.joinedText(results.flatMap(\.segments).map {
            RecognizedSegment(text: $0.text, avgLogprob: $0.avgLogprob,
                              compressionRatio: $0.compressionRatio, noSpeechProb: $0.noSpeechProb)
        })
        print("LECTURE_SMALL_RECOGNIZED: \(actual)")
        print("LECTURE_SMALL_DECODE_SECONDS: \(Date.timeIntervalSinceReferenceDate - started)")
        XCTAssertEqual(words(actual).filter { $0 == "accurate" }.count, 2)
        XCTAssertEqual(words(actual).filter { $0 == "not" }.count, 6)
    }

    func testEnglishLectureThroughActualLocalRecognitionAndCapture() async throws {
        let bundle = Bundle(for: Self.self)
        guard let audio = bundle.url(forResource: "lecture", withExtension: "wav"),
              let reference = bundle.url(forResource: "lecture", withExtension: "txt") else {
            throw XCTSkip("音频由专项语音回放工作流提供")
        }
        let expected = try String(contentsOf: reference, encoding: .utf8)
        let file = try AVAudioFile(forReading: audio)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let capture = AudioCapture(), whisper = WhisperService()
        print("LECTURE_NATIVE_INSTALLED: \(await AppleSpeechSession.installedTranscriber(language: "en") != nil)")
        var services = ConversationServices.live(whisper: whisper, capture: capture)
        services.requestMicrophonePermission = { true }
        services.startCapture = { capture.startExternal() }
        // This benchmark measures recognition and segmentation, not the translation model.
        services.translation = { text, _, _, _, _ in text }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory, summarize: { _ in "" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        let preferences = controller.preferences
        let previous = (preferences.sourceLanguage, preferences.preferredLanguage,
                        preferences.processingMode, preferences.autoReadAloud, preferences.nearField)
        defer {
            controller.clearCurrent()
            preferences.sourceLanguage = previous.0
            preferences.preferredLanguage = previous.1
            preferences.processingMode = previous.2
            preferences.autoReadAloud = previous.3
            preferences.nearField = previous.4
        }
        preferences.sourceLanguage = "auto"
        preferences.preferredLanguage = "zh"
        preferences.processingMode = .quality
        preferences.autoReadAloud = false
        preferences.nearField = false
        await controller.start()
        XCTAssertTrue(controller.isRunning, controller.errorMessage ?? controller.status)
        let replayStarted = Date.timeIntervalSinceReferenceDate
        for offset in stride(from: 0, to: samples.count, by: 1_600) {
            capture.feedExternal(Array(samples[offset..<min(offset + 1_600, samples.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        controller.end(save: false)
        for _ in 0..<3_600 {
            if controller.hasEnded { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(controller.hasEnded, "回放结束后识别不能卡住")
        let actual = SpeechTextJoiner.join(controller.lines.map(\.original))
        let expectedWords = words(expected), actualWords = words(actual)
        let errorRate = Double(distance(expectedWords, actualWords)) / Double(max(1, expectedWords.count))
        print("LECTURE_REFERENCE: \(expected)")
        print("LECTURE_RECOGNIZED: \(actual)")
        print("LECTURE_WORD_ERROR_RATE: \(errorRate)")
        print("LECTURE_AUDIO_SECONDS: \(Double(samples.count) / 16_000)")
        print("LECTURE_REPLAY_SECONDS: \(Date.timeIntervalSinceReferenceDate - replayStarted)")
        if actualWords.filter({ $0 == "accurate" }).count < expectedWords.filter({ $0 == "accurate" }).count {
            let independent = try await whisper.recognize(Array(samples.prefix(8 * 16_000)), language: "en")
            print("LECTURE_INDEPENDENT_FALLBACK: \(independent.text)")
        }
        XCTAssertLessThanOrEqual(errorRate, 0.15, "清晰英语回放的识别词错误率超过 15%")
        XCTAssertGreaterThanOrEqual(actualWords.filter { $0 == "not" }.count,
                                    expectedWords.filter { $0 == "not" }.count,
                                    "否定条件和金额对比不能丢掉 not")
        XCTAssertEqual(actualWords.filter { $0 == "accurate" }.count,
                       expectedWords.filter { $0 == "accurate" }.count,
                       "完整音频中的 accurate 不能变成 Accura")
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func distance(_ expected: [String], _ actual: [String]) -> Int {
        var row = Array(0...actual.count)
        for (index, word) in expected.enumerated() {
            var next = [index + 1]
            for (other, candidate) in actual.enumerated() {
                next.append(min(next[other] + 1, row[other + 1] + 1,
                                row[other] + (word == candidate ? 0 : 1)))
            }
            row = next
        }
        return row[actual.count]
    }
}
