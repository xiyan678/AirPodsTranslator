import XCTest
@testable import AirPodsTranslator

@MainActor
final class LiveSessionTests: XCTestCase {
    private var directory: URL!
    private var preferences: Preferences!
    private var savedAutoRead = false
    private var savedTarget = "zh"

    override func setUp() async throws {
        preferences = Preferences()
        savedAutoRead = preferences.autoReadAloud
        savedTarget = preferences.preferredLanguage
        preferences.autoReadAloud = false
        preferences.preferredLanguage = "zh"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        preferences.autoReadAloud = savedAutoRead
        preferences.preferredLanguage = savedTarget
        try FileManager.default.removeItem(at: directory)
    }

    private func controller(translationGate: TranslationGate? = nil,
                            gatedText: String? = nil) -> ConversationController {
        let capture = AudioCapture()
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in (text: "Hello there", language: "en") },
            translation: { text, _, _, _, _ in
                if let translationGate, gatedText == nil || text == gatedText {
                    return await translationGate.wait()
                }
                return "你好"
            }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "测试对话" })
        return ConversationController(capture: capture, store: store, services: services)
    }

    private func eventually(_ condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "异步流程没有按预期完成", file: file, line: line)
    }

    private func feedSentence(_ controller: ConversationController) {
        controller.capture.feedExternal(Array(repeating: 0.2, count: 3_200))
        controller.capture.feedExternal(Array(repeating: 0, count: 32_000))
    }

    func testInstalledEnglishTranslationDoesNotRequestAnotherLanguagePack() async {
        let controller = controller()
        await controller.translateText("Hello", from: "en", to: "zh")
        XCTAssertEqual(controller.textTranslation, "你好")
        XCTAssertNil(controller.languagePackRequest, "已安装语言对应直接翻译，不进入准备下载流程")
        XCTAssertNil(controller.errorMessage)
        controller.clearCurrent()
    }

    func testTransientLiveTranslationFailureIsRetriedWithoutLosingSentence() async {
        let capture = AudioCapture()
        var attempts = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in (text: "Do not release on Friday", language: "en") },
            translation: { _, _, _, _, _ in
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return "不要在周五发布"
            }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "会议" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        await controller.start()
        feedSentence(controller)
        controller.end(save: true)
        await eventually { controller.hasEnded && !store.conversations.isEmpty }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(controller.lines.map(\.original), ["Do not release on Friday"])
        XCTAssertEqual(store.conversations.first?.lines.map(\.translated), ["不要在周五发布"])
    }

    func testPermanentLiveTranslationFailureStillSavesOriginalAndContinues() async {
        let capture = AudioCapture()
        var count = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in
                count += 1
                return (text: "Sentence \(count)", language: "en")
            },
            translation: { text, _, _, _, _ in
                if text == "Sentence 1" { throw URLError(.networkConnectionLost) }
                return "第二句译文"
            }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "会议" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        await controller.start()
        feedSentence(controller)
        feedSentence(controller)
        controller.end(save: true)
        await eventually { controller.hasEnded && !store.conversations.isEmpty }
        XCTAssertEqual(controller.lines.map(\.original), ["Sentence 1", "Sentence 2"])
        XCTAssertEqual(controller.lines.last?.translated, "第二句译文")
        XCTAssertEqual(store.conversations.first?.lines.map(\.original), ["Sentence 1", "Sentence 2"])
        XCTAssertNotNil(controller.lines.first?.translationIssue)
    }

    func testConfirmedNativeSentenceTranslatesBeforeSilenceAndKeepsTheAudioTail() async {
        let capture = AudioCapture()
        var finalAudio: [[Float]] = []
        var commits = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { samples, _ in finalAudio.append(samples); return ("The second sentence.", "en") },
            translation: { text, _, _, _, _ in "译文 \(text)" },
            partialRecognition: { _, _ in
                SpeechRecognitionUpdate(text: "The first sentence. The second", language: "en",
                    confirmedPrefix: .init(text: "The first sentence.", sampleCount: 16_000))
            },
            commitRecognition: { _, _ in commits += 1 }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "演讲" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        await controller.start()
        capture.feedExternal(Array(repeating: 0.2, count: 32_000))
        await eventually { controller.lines.count == 1 }
        XCTAssertTrue(capture.isRecording)
        XCTAssertEqual(controller.lines.map(\.original), ["The first sentence."])
        controller.end(save: true)
        await eventually { controller.hasEnded && !store.conversations.isEmpty }
        XCTAssertEqual(controller.lines.map(\.original), ["The first sentence.", "The second sentence."])
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(finalAudio.first?.count, 16_000, "提交前半句后，结束时仍要处理后半句的所有音频")
    }

    func testLatePartialCannotCommitAfterTheAudioWindowAlreadyEnded() async {
        let capture = AudioCapture()
        let gate = TranslationGate()
        defer { gate.release() }
        var commits = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in ("The whole final sentence.", "en") },
            translation: { text, _, _, _, _ in "译文 \(text)" },
            partialRecognition: { _, _ in
                _ = await gate.wait()
                return SpeechRecognitionUpdate(text: "Stale sentence.", language: "en",
                    confirmedPrefix: .init(text: "Stale sentence.", sampleCount: 16_000))
            },
            commitRecognition: { _, _ in commits += 1 }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "演讲" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        await controller.start()
        capture.feedExternal(Array(repeating: 0.2, count: 32_000))
        await eventually { gate.waiting }
        capture.feedExternal(Array(repeating: 0, count: 32_000))
        controller.end(save: true)
        gate.release()
        await eventually { controller.hasEnded && !store.conversations.isEmpty }
        XCTAssertEqual(controller.lines.map(\.original), ["The whole final sentence."])
        XCTAssertEqual(commits, 0)
    }

    func testTranslationFailureDuringQueuedPlaybackReturnsToListeningAndProcessesNextSentence() async {
        let capture = AudioCapture()
        var recognized = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in recognized += 1; return ("Sentence \(recognized)", "en") },
            translation: { text, _, _, _, _ in
                if text == "Sentence 1" { throw URLError(.networkConnectionLost) }
                return "下一句译文"
            }, playbackIsActive: { true }
        )
        let controller = ConversationController(capture: capture, services: services)
        await controller.start()
        feedSentence(controller)
        await eventually { controller.lines.count == 1 && controller.phase == .listening }
        XCTAssertNotNil(controller.lines.first?.translationIssue)
        XCTAssertTrue(capture.isRecording)
        feedSentence(controller)
        await eventually { controller.lines.count == 2 && controller.phase == .listening }
        XCTAssertEqual(controller.lines.last?.translated, "下一句译文")
        controller.clearCurrent()
    }

    func testDialoguePreparesItsSelectedLanguageInsteadOfDownloadingAnUnneededFallback() async {
        let capture = AudioCapture()
        var prepared: [String?] = []
        let services = ConversationServices(
            prepareSpeech: { XCTFail("指定说英语时，应优先准备英语原生识别") },
            requestMicrophonePermission: { true }, startCapture: { capture.startExternal() },
            recognition: { _, _ in ("Hello", "en") },
            translation: { _, _, _, _, _ in "你好" },
            prepareRecognition: { prepared.append($0) }
        )
        let controller = ConversationController(capture: capture, services: services)
        await controller.beginDialogue(in: "en")
        XCTAssertEqual(prepared, ["en"])
        XCTAssertTrue(controller.isRunning)
        controller.clearCurrent()
    }

    func testTimedOutTextCanBeResentBeforeOldTranslationReturns() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate, gatedText: "first")
        controller.selectMode(.dialogue)
        let firstID = UUID()
        let first = Task {
            await controller.translateText("first", from: "en", to: "zh",
                                           inDialogue: true, requestID: firstID)
        }
        await eventually { gate.waiting }
        XCTAssertTrue(controller.isTranslatingText)
        controller.expireTextRequest(firstID)
        XCTAssertFalse(controller.isTranslatingText, "超时后发送按钮必须解除等待状态")
        await controller.translateText("second", from: "en", to: "zh", inDialogue: true)
        XCTAssertFalse(controller.isTranslatingText)
        XCTAssertEqual(controller.lines.map(\.original), ["second"])
        gate.release()
        await first.value
        XCTAssertEqual(controller.lines.map(\.original), ["second"], "旧结果晚到不能覆盖重试结果")
        XCTAssertNil(controller.errorMessage)
        controller.clearCurrent()
    }

    func testPauseThenEndTranslatesAndSavesUnfinishedSpeechExactlyOnce() async {
        let controller = controller()
        await controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.capture.feedExternal(Array(repeating: 0.2, count: 3_200))
        controller.pause()
        XCTAssertFalse(controller.capture.isRecording)
        XCTAssertTrue(controller.lines.isEmpty)
        controller.end(save: true)
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.lines.map(\.translated), ["你好"])
        XCTAssertEqual(controller.store.conversations.first?.lines.count, 1)
        XCTAssertFalse(controller.capture.isRecording)
        XCTAssertFalse(controller.isEnding)
    }

    func testEndingDuringTranslationWaitsForFinalSentenceBeforeSaving() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate)
        await controller.start()
        feedSentence(controller)
        await eventually { gate.waiting }
        controller.end(save: true)
        XCTAssertTrue(controller.isEnding)
        XCTAssertTrue(controller.store.conversations.isEmpty)
        gate.release()
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.store.conversations.first?.lines.map(\.translated), ["你好"])
        XCTAssertFalse(controller.capture.isRecording)
    }

    func testNextSentenceIsCapturedWhileThePreviousTranslationIsWaiting() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate)
        await controller.start()
        feedSentence(controller)
        await eventually { gate.waiting }
        XCTAssertTrue(controller.capture.isRecording)
        feedSentence(controller)
        controller.end(save: true)
        gate.release()
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.lines.count, 2, "翻译上一句时收到的下一句不能丢失")
        XCTAssertEqual(controller.store.conversations.first?.lines.count, 2)
    }

    func testSlowPreviewCompletesAndCoalescesNewSpeechWithoutRepeatedCancellation() async {
        let capture = AudioCapture()
        let gate = TranslationGate()
        defer { gate.release() }
        var recognitionCount = 0
        var requests: [String] = []
        var modes: [ProcessingMode] = []
        let hypotheses = ["We should", "We should meet", "We should meet tomorrow"]
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in
                let text = hypotheses[min(recognitionCount, hypotheses.count - 1)]
                recognitionCount += 1
                return (text: text, language: "en")
            },
            translation: { text, _, _, mode, _ in
                requests.append(text)
                modes.append(mode)
                if text == "We should" { _ = await gate.wait() }
                return "译文 \(text)"
            }
        )
        let controller = ConversationController(capture: capture, services: services)
        await controller.start()
        capture.feedExternal(Array(repeating: 0.2, count: 32_000))
        await eventually { recognitionCount == 1 }
        capture.feedExternal(Array(repeating: 0.2, count: 32_000))
        await eventually { gate.waiting }
        capture.feedExternal(Array(repeating: 0.2, count: 32_000))
        await eventually { recognitionCount == 3 }
        XCTAssertEqual(requests, ["We should"], "新字幕不得取消尚未完成的预览翻译")
        gate.release()
        await eventually { controller.liveTranslation == "译文 We should meet" }
        XCTAssertEqual(requests, ["We should", "We should meet"])
        XCTAssertTrue(modes.allSatisfy { $0 == .fast })
        XCTAssertTrue(controller.lines.isEmpty, "预览不能进入最终对话记录")
        controller.clearCurrent()
    }

    func testContinuousInterpretationDoesNotWaitForPlaybackBeforeTranslatingNextSentence() async {
        let capture = AudioCapture()
        var spoken: [String] = []
        var finishedRecognitions = 0
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true },
            startCapture: { capture.startExternal() },
            recognition: { _, _ in
                finishedRecognitions += 1
                return (text: "Sentence \(finishedRecognitions)", language: "en")
            },
            translation: { text, _, _, _, _ in "译文 \(text)" },
            headphonesConnected: { true },
            enqueueSpeech: { text, _, _ in spoken.append(text); return true }
        )
        let store = ConversationStore(directory: directory, summarize: { _ in "演讲" })
        let controller = ConversationController(capture: capture, store: store, services: services)
        let savedAutoRead = controller.preferences.autoReadAloud
        defer { controller.preferences.autoReadAloud = savedAutoRead }
        controller.preferences.autoReadAloud = true
        await controller.start()
        capture.feedExternal(Array(repeating: 0.2, count: 64_000))
        capture.feedExternal(Array(repeating: 0, count: 8_000))
        await eventually { !controller.liveText.isEmpty }
        XCTAssertTrue(spoken.isEmpty, "说话中的预览不得触发朗读")
        XCTAssertTrue(controller.lines.isEmpty, "换气时不得保存半句话")
        capture.feedExternal(Array(repeating: 0.2, count: 16_000))
        capture.feedExternal(Array(repeating: 0, count: 28_800))
        await eventually { spoken.count == 1 }
        XCTAssertTrue(capture.isRecording)
        feedSentence(controller)
        // 没有任何播放完成回调；识别、翻译仍应继续，播放顺序与译文顺序一致。
        await eventually { spoken.count == 2 }
        XCTAssertEqual(spoken, controller.lines.map(\.translated))
        XCTAssertTrue(capture.isRecording)
        controller.end(save: true)
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.store.conversations.first?.lines.count, 2)
    }

    func testEndingDuringInstalledTextTranslationStillSavesTheFinalLine() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate)
        controller.selectMode(.dialogue)
        let translation = Task {
            await controller.translateText("Hello", from: "en", to: "zh", inDialogue: true)
        }
        await eventually { gate.waiting }
        controller.end(save: true)
        XCTAssertTrue(controller.isEnding)
        gate.release()
        await translation.value
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.store.conversations.first?.lines.map(\.translated), ["你好"])
    }

    func testTranslationFinishingAfterModeChangeCannotLeakIntoDialogue() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate)
        await controller.start()
        feedSentence(controller)
        await eventually { gate.waiting }
        XCTAssertTrue(controller.selectMode(.dialogue))
        gate.release()
        // End flushes work if any has incorrectly leaked into the new mode.
        controller.end()
        await eventually { controller.hasEnded }
        XCTAssertTrue(controller.lines.isEmpty)
        XCTAssertTrue(controller.store.conversations.isEmpty)
        XCTAssertFalse(controller.capture.isRecording)
    }

    func testPauseAndResumeRetranslatesInFlightSpeechOnlyOnce() async {
        let gate = TranslationGate()
        defer { gate.release() }
        let controller = controller(translationGate: gate)
        await controller.start()
        feedSentence(controller)
        await eventually { gate.waiting }
        controller.pause()
        await controller.start()
        gate.release()
        await eventually { controller.lines.count == 1 && controller.phase == .listening }
        controller.end(save: true)
        await eventually { controller.hasEnded && controller.store.conversations.count == 1 }
        XCTAssertEqual(controller.lines.count, 1)
        XCTAssertEqual(controller.store.conversations.first?.lines.count, 1)
        XCTAssertFalse(controller.capture.isRecording)
    }
}

@MainActor
private final class TranslationGate {
    private var released = false
    private(set) var waiting = false
    private var continuation: CheckedContinuation<String, Never>?

    func wait() async -> String {
        if released { return "你好" }
        waiting = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: "你好")
        continuation = nil
    }
}
