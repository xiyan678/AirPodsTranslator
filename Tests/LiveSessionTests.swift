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
