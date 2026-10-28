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
