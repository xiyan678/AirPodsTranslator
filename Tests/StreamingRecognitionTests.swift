import XCTest
@testable import AirPodsTranslator

@MainActor
final class StreamingRecognitionTests: XCTestCase {
    func testFinalTimelineReplacesPreviewAndNeverCommitsUnfinishedSpeech() {
        var timeline = RecognitionTimeline()
        timeline.receive(.init(start: 0, end: 2, text: "I can release.", isFinal: false))
        XCTAssertNil(timeline.confirmedPrefix)
        timeline.receive(.init(start: 0, end: 2, text: "I can't release.", isFinal: true))
        timeline.receive(.init(start: 2, end: 3, text: "We should wait", isFinal: false))
        XCTAssertEqual(timeline.text, "I can't release. We should wait")
        XCTAssertEqual(timeline.confirmedPrefix, .init(text: "I can't release.", sampleCount: 32_000))
        timeline.receive(.init(start: 0, end: 2, text: "I can release.", isFinal: false))
        XCTAssertEqual(timeline.text, "I can't release. We should wait", "过时预览不能替换最终结果")
    }

    func testFinalTimelineWaitsForSentenceBoundaryAndJoinsChineseWithoutSpaces() {
        var timeline = RecognitionTimeline()
        timeline.receive(.init(start: 0, end: 1, text: "如果今天", isFinal: true))
        XCTAssertNil(timeline.confirmedPrefix)
        timeline.receive(.init(start: 1, end: 2, text: "不能发布。", isFinal: true))
        XCTAssertEqual(timeline.text, "如果今天不能发布。")
        XCTAssertEqual(timeline.confirmedPrefix?.text, "如果今天不能发布。")
        timeline.receive(.init(start: .nan, end: 4, text: "bad", isFinal: true))
        XCTAssertEqual(timeline.pieces.count, 2)
    }

    func testNativeSessionIsPreferredAndReusedWithinOneUtterance() async throws {
        let native = StubIncrementalSpeech()
        var starts = 0
        var fallbacks = 0
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { _, _, _ in fallbacks += 1; return ("fallback", "en") },
            detect: { _ in XCTFail("指定语言时不应再次探测"); return nil },
            nativeFactory: { language in XCTAssertEqual(language, "en"); starts += 1; return native }
        )
        _ = try await recognizer.recognize(Array(repeating: 0.2, count: 16_000), language: "en", final: false)
        let final = try await recognizer.recognize(Array(repeating: 0.2, count: 32_000), language: "en", final: true)
        XCTAssertEqual(final.text, "Native sentence.")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(native.receivedCounts, [16_000, 32_000])
        XCTAssertEqual(fallbacks, 0)
        XCTAssertTrue(native.cancelled)
    }

    func testAutomaticLanguageIsDetectedOncePerWindowAndCanChangeNextWindow() async throws {
        var detections = 0
        var languages: [String] = []
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { _, _, _ in XCTFail("原生引擎可用时不回退"); return ("", "") },
            detect: { _ in detections += 1; return detections == 1 ? "en" : "ja" },
            nativeFactory: { language in languages.append(language); return StubIncrementalSpeech(language: language) }
        )
        let samples = Array(repeating: Float(0.2), count: 16_000)
        _ = try await recognizer.recognize(samples, language: nil, final: false)
        _ = try await recognizer.recognize(samples, language: nil, final: true)
        _ = try await recognizer.recognize(samples, language: nil, final: true)
        XCTAssertEqual(detections, 2)
        XCTAssertEqual(languages, ["en", "ja"])
    }

    func testNativeFailureRetriesTheWholeOriginalAudioWithFallback() async throws {
        let native = StubIncrementalSpeech()
        native.failure = URLError(.cannotDecodeContentData)
        var fallbackCounts: [Int] = []
        var starts = 0
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { samples, language, _ in fallbackCounts.append(samples.count); return ("Recovered.", language ?? "en") },
            detect: { _ in "en" },
            nativeFactory: { _ in starts += 1; return native }
        )
        _ = try await recognizer.recognize(Array(repeating: 0.2, count: 16_000), language: "en", final: false)
        let final = try await recognizer.recognize(Array(repeating: 0.2, count: 32_000), language: "en", final: true)
        XCTAssertEqual(final.text, "Recovered.")
        XCTAssertEqual(fallbackCounts, [16_000, 32_000])
        XCTAssertEqual(starts, 1, "同一窗口出错后，不应每次预览都重新启动坏掉的引擎")
        XCTAssertTrue(native.cancelled)
    }

    func testFallbackContextIsBoundedAndNeverCrossesLanguagesOrSessions() async throws {
        var prompts: [String] = []
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { _, language, context in
                prompts.append(context)
                return (String(repeating: "context ", count: 200), language ?? "en")
            }, detect: { _ in nil }, nativeFactory: { _ in nil }
        )
        let samples = Array(repeating: Float(0.2), count: 16_000)
        _ = try await recognizer.recognize(samples, language: "en", final: true)
        _ = try await recognizer.recognize(samples, language: "en", final: true)
        _ = try await recognizer.recognize(samples, language: "zh", final: true)
        recognizer.reset()
        _ = try await recognizer.recognize(samples, language: "zh", final: true)
        XCTAssertEqual(prompts[0], "")
        XCTAssertFalse(prompts[1].isEmpty)
        XCTAssertLessThanOrEqual(prompts[1].count, 800)
        XCTAssertEqual(prompts[2], "")
        XCTAssertEqual(prompts[3], "")
    }

    func testResetRejectsAnOldLanguageDetectionBeforeItStartsANativeSession() async throws {
        let gate = RecognitionTestGate()
        var requestedLanguages: [String] = []
        let recognizer = AdaptiveSpeechRecognizer(
            fallback: { _, _, _ in ("Fallback.", "en") },
            detect: { _ in await gate.wait(); return "en" },
            nativeFactory: { language in requestedLanguages.append(language); return StubIncrementalSpeech(language: language) }
        )
        let old = Task { try await recognizer.recognize(Array(repeating: 0.2, count: 16_000), language: nil, final: false) }
        for _ in 0..<100 where !gate.waiting { await Task.yield() }
        XCTAssertTrue(gate.waiting)
        recognizer.reset()
        _ = try await recognizer.recognize(Array(repeating: 0.2, count: 16_000), language: "ja", final: true)
        gate.release()
        do { _ = try await old.value; XCTFail("旧会话不能继续提交结果") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requestedLanguages, ["ja"])
    }

    func testDeadlineUnblocksEvenWhenTheUnderlyingOperationIgnoresCancellation() async throws {
        let gate = RecognitionTestGate()
        do {
            _ = try await AsyncDeadline<String>.run(timeout: .milliseconds(20)) {
                await gate.wait()
                return "late"
            }
            XCTFail("应超时")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let next = try await AsyncDeadline<String>.run(timeout: .seconds(1)) { "new" }
        XCTAssertEqual(next, "new")
        gate.release()
        await Task.yield()
    }

    func testDeadlineCancellationDoesNotWaitForTheUnderlyingOperation() async {
        let gate = RecognitionTestGate()
        let task = Task {
            try await AsyncDeadline<String>.run(timeout: .seconds(60)) { await gate.wait(); return "late" }
        }
        for _ in 0..<100 where !gate.waiting { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("应取消") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.release()
    }

    func testLanguageConfidenceUsesLogProbabilitiesInsteadOfRawProbabilities() {
        XCTAssertTrue(WhisperLanguageConfidence.accepts(log(0.9)))
        XCTAssertFalse(WhisperLanguageConfidence.accepts(log(0.4)))
        XCTAssertFalse(WhisperLanguageConfidence.accepts(nil))
        XCTAssertFalse(WhisperLanguageConfidence.accepts(.nan))
        XCTAssertFalse(WhisperLanguageConfidence.accepts(.infinity))
    }

    func testPlaybackCatchupPreservesNormalRateAndLimitsAcceleration() {
        XCTAssertEqual(SpeechBacklog.adjustedRate(0.48, backlog: 0), 0.48)
        XCTAssertEqual(SpeechBacklog.adjustedRate(0.48, backlog: 5), 0.48)
        let catchup = SpeechBacklog.adjustedRate(0.48, backlog: 60)
        XCTAssertGreaterThan(catchup, 0.48)
        XCTAssertLessThanOrEqual(catchup, 0.48 * 1.2)
        XCTAssertGreaterThan(SpeechBacklog.estimatedSeconds("这是完整的翻译句子。", rate: 0.48), 0)
    }

    func testSpeechJoiningKeepsChineseCompactAndEnglishWordsSeparated() {
        XCTAssertEqual(SpeechTextJoiner.join(["你好 ", " 世界。"]), "你好世界。")
        XCTAssertEqual(SpeechTextJoiner.join(["Hello ", " there.", "Next sentence."]), "Hello there. Next sentence.")
        XCTAssertEqual(SpeechTextJoiner.join(["I can", "'t do it."]), "I can't do it.")
        XCTAssertEqual(SpeechTextJoiner.join(["안녕", "세계"]), "안녕 세계")
    }
}

@MainActor
private final class StubIncrementalSpeech: IncrementalSpeechSession {
    let language: String
    var failure: Error?
    private(set) var receivedCounts: [Int] = []
    private(set) var cancelled = false
    init(language: String = "en") { self.language = language }
    func update(_ samples: [Float], final: Bool) async throws -> SpeechRecognitionUpdate {
        receivedCounts.append(samples.count)
        if let failure { throw failure }
        return SpeechRecognitionUpdate(text: "Native sentence.", language: language)
    }
    func cancel() { cancelled = true }
}

@MainActor
private final class RecognitionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
