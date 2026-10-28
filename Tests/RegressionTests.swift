import XCTest
@testable import AirPodsTranslator

@MainActor
final class RegressionTests: XCTestCase {
    private func line(_ text: String) -> TranscriptLine {
        TranscriptLine(sourceLanguage: "en", targetLanguage: "zh",
                       original: text, translated: text, isMine: false)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDialogueAndLiveSessionsStaySeparateAcrossTabChanges() {
        let controller = ConversationController()
        let liveID = controller.currentConversationID
        controller.lines = [line("live speech")]
        XCTAssertTrue(controller.selectMode(.dialogue))
        XCTAssertTrue(controller.lines.isEmpty)
        let dialogueID = controller.currentConversationID
        XCTAssertNotEqual(liveID, dialogueID)
        controller.lines = [line("keyboard text")]
        controller.dialogueKeyboardDraft = "unfinished"
        XCTAssertTrue(controller.selectMode(.listen))
        XCTAssertEqual(controller.lines.map(\.original), ["live speech"])
        XCTAssertEqual(controller.currentConversationID, liveID)
        XCTAssertTrue(controller.selectMode(.dialogue))
        XCTAssertEqual(controller.lines.map(\.original), ["keyboard text"])
        XCTAssertEqual(controller.currentConversationID, dialogueID)
        XCTAssertEqual(controller.dialogueKeyboardDraft, "unfinished")
    }

    func testClearingDialogueDoesNotClearLiveSession() {
        let controller = ConversationController()
        controller.lines = [line("live")]
        controller.selectMode(.dialogue)
        controller.lines = [line("dialogue")]
        controller.clearCurrent()
        XCTAssertTrue(controller.lines.isEmpty)
        controller.selectMode(.listen)
        XCTAssertEqual(controller.lines.map(\.original), ["live"])
        controller.selectMode(.dialogue)
        XCTAssertTrue(controller.lines.isEmpty)
    }

    func testClearingPendingKeyboardTranslationDoesNotLeaveEndWaiting() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        controller.preferences.preferredLanguage = "zh"
        controller.lastOtherLanguage = "en"
        await controller.sendDialogueText("你好")
        XCTAssertNotNil(controller.languagePackRequest)
        let oldID = controller.currentConversationID
        controller.clearCurrent()
        XCTAssertNil(controller.languagePackRequest)
        XCTAssertNotEqual(controller.currentConversationID, oldID)
        controller.end()
        XCTAssertFalse(controller.isEnding)
        XCTAssertTrue(controller.hasEnded)
    }

    func testOldLanguagePreparationFailureCannotAffectNewPage() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        controller.preferences.preferredLanguage = "zh"
        controller.lastOtherLanguage = "en"
        await controller.sendDialogueText("你好")
        guard let request = controller.languagePackRequest else {
            XCTFail("Expected language preparation")
            return
        }
        controller.selectMode(.listen)
        controller.languagePackFailed(NSError(domain: "test", code: 1), for: request.id)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.lines.isEmpty)
        XCTAssertNil(controller.languagePackRequest)
    }

    func testExplicitConversationIDsNeverMergeEvenWithIdenticalLines() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "summary" })
        let sharedLines = [line("hello")]
        let first = UUID(), second = UUID()
        try await store.save(sharedLines, id: first)
        try await store.save(sharedLines, id: second)
        XCTAssertEqual(Set(store.conversations.map(\.id)), Set([first, second]))
    }

    func testWhisperSoundCaptionsAreNotTreatedAsSpokenSentences() {
        for caption in ["(snoring)", "[XBOX SOUND]", "[XBOX SOUND] [Music]", "（打鼾）", "【音乐】", "[BLANK_AUDIO]"] {
            XCTAssertNil(RecognizedSpeechText.cleaned(caption), caption)
        }
        for spoken in ["Hello", "请说 Xbox", "[Music] hello", "I said (hello)"] {
            XCTAssertEqual(RecognizedSpeechText.cleaned(spoken), spoken)
        }
    }

    func testBodyIsPersistedBeforeSummaryFinishes() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = SummaryGate()
        defer { gate.release() }
        let store = ConversationStore(directory: url, summarize: { _ in await gate.value() })
        let entry = line("hello")
        try await store.save([entry])
        // The summary is blocked: a fresh store must already load the transcript.
        let reopened = ConversationStore(directory: url)
        XCTAssertEqual(reopened.conversations.first?.lines.first?.id, entry.id)
    }

    func testRepeatedSaveUpdatesTheSameConversation() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "summary" })
        let id = UUID()
        let first = line("first")
        try await store.save([first], id: id)
        try await store.save([first, line("second")], id: id)
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.conversations.first?.lines.count, 2)
        XCTAssertEqual(store.conversations.first?.id, id)
    }

    func testBatchDeleteCanBeUndoneAndReloaded() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "summary" })
        let ids = [UUID(), UUID()]
        try await store.save([line("first")], id: ids[0])
        try await store.save([line("second")], id: ids[1])
        try store.delete(Set(ids))
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.canUndoDelete)
        try store.undoDelete()
        XCTAssertEqual(Set(store.conversations.map(\.id)), Set(ids))
        XCTAssertFalse(store.canUndoDelete)
        XCTAssertEqual(ConversationStore(directory: url).conversations.count, 2)
    }

    func testStructuredSummarySurvivesReloadAndLateResultsCannotReviveDeletion() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "local" })
        let id = UUID()
        let lines = [line("Release Friday")]
        let outline = SummaryOutline(keyPoints: ["周五发布"], questions: [], nextSteps: ["周四测试"])
        try await store.save(lines, id: id)
        try store.updateOutline(outline, id: id, lines: lines)
        XCTAssertEqual(ConversationStore(directory: url).conversations.first?.outline, outline)
        try store.delete([id])
        try store.updateOutline(outline, id: id, lines: lines)
        XCTAssertTrue(ConversationStore(directory: url).conversations.isEmpty)
    }

    func testOldHistoryWithoutStructuredSummaryRemainsReadable() throws {
        let old = SavedConversation(lines: [line("old")], summary: "legacy")
        let encoded = try JSONEncoder().encode(old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "outline")
        let restored = try JSONDecoder().decode(SavedConversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.summary, "legacy")
        XCTAssertNil(restored.outline)
    }

    func testSummaryForOldTextCannotOverwriteEditedConversation() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "local" })
        let id = UUID()
        let old = [line("Monday")]
        try await store.save(old, id: id)
        var edited = old
        edited[0].original = "Friday"
        try await store.save(edited, id: id)
        try store.updateOutline(SummaryOutline(keyPoints: ["Monday"], questions: [], nextSteps: []), id: id, lines: old)
        XCTAssertNil(ConversationStore(directory: url).conversations.first?.outline)
    }

    func testEndingKeepsAShortUnfinishedAnswerOnlyOnce() {
        let capture = AudioCapture()
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0.2, count: 3_200))
        XCTAssertEqual(capture.takePendingSpeech()?.count, 3_200)
        XCTAssertNil(capture.takePendingSpeech())
        capture.stop()
    }

    func testSilenceDoesNotBecomeAnUtterance() {
        let capture = AudioCapture()
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0, count: 16_000))
        XCTAssertNil(capture.takePendingSpeech())
        capture.stop()
    }

    func testSummaryKeepsSectionsAndDoesNotInventMissingTasks() throws {
        let content = """
        {"keyPoints":["周五发布新版本"],"questions":[],"nextSteps":[]}
        """
        let summary = try SummaryOutline.decode(content)
        XCTAssertEqual(summary.keyPoints, ["周五发布新版本"])
        XCTAssertTrue(summary.questions.isEmpty)
        XCTAssertTrue(summary.nextSteps.isEmpty)
        XCTAssertTrue(summary.plainText.contains("暂无明确问题"))
        XCTAssertTrue(summary.plainText.contains("暂无明确行动项"))
    }

    func testSummaryAcceptsFencedJSONAndRemovesRepeatedPoints() throws {
        let content = """
        ```json
        {"keyPoints":[" 发布版本 ","发布版本",""],"questions":[],"nextSteps":["周四测试"]}
        ```
        """
        let summary = try SummaryOutline.decode(content)
        XCTAssertEqual(summary.keyPoints, ["发布版本"])
        XCTAssertEqual(summary.nextSteps, ["周四测试"])
    }

    func testSummaryRejectsMalformedAndEmptyModelOutput() {
        XCTAssertThrowsError(try SummaryOutline.decode("没有 JSON"))
        XCTAssertThrowsError(try SummaryOutline.decode("{\"keyPoints\":[],\"questions\":[],\"nextSteps\":[]}"))
    }
}

@MainActor
private final class SummaryGate {
    private var released = false
    private var waiter: CheckedContinuation<String, Never>?

    func value() async -> String {
        if released { return "summary" }
        return await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume(returning: "summary")
        waiter = nil
    }
}
