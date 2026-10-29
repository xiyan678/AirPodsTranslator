import XCTest
import Translation
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

    func testTextCompletionPreservesNewDraftAndClearsOnlySubmittedDraft() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        let autoRead = controller.preferences.autoReadAloud
        let language = controller.preferences.preferredLanguage
        defer {
            controller.preferences.autoReadAloud = autoRead
            controller.preferences.preferredLanguage = language
        }
        controller.preferences.autoReadAloud = false
        controller.preferences.preferredLanguage = "zh"
        controller.dialogueKeyboardDraft = "new unsent text"
        let firstID = UUID()
        // Same-language pass-through exercises delivery without a downloaded model.
        await controller.translateText("hello", from: "en", to: "en", inDialogue: true, requestID: firstID)
        XCTAssertEqual(controller.deliveredDialogueTextID, firstID)
        XCTAssertEqual(controller.dialogueKeyboardDraft, "new unsent text")
        controller.dialogueKeyboardDraft = " hello "
        let secondID = UUID()
        await controller.translateText("hello", from: "en", to: "en", inDialogue: true, requestID: secondID)
        XCTAssertEqual(controller.deliveredDialogueTextID, secondID)
        XCTAssertEqual(controller.dialogueKeyboardDraft, "")
        XCTAssertEqual(controller.lines.count, 2)
        controller.clearCurrent()
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

    func testCancellingLanguageDownloadKeepsDraftAndAllowsRetryWithoutAlert() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        controller.preferences.preferredLanguage = "zh"
        controller.lastOtherLanguage = "en"
        controller.dialogueKeyboardDraft = "你好"
        for cancellation: Error in [CocoaError(.userCancelled), CancellationError(),
                                    URLError(.cancelled), TranslationError.alreadyCancelled] {
            await controller.sendDialogueText("你好")
            guard let request = controller.languagePackRequest else {
                return XCTFail("Expected language preparation request")
            }
            controller.languagePackFailed(cancellation, for: request.id)
            XCTAssertNil(controller.errorMessage)
            XCTAssertNil(controller.languagePackRequest)
            XCTAssertEqual(controller.dialogueKeyboardDraft, "你好")
            XCTAssertTrue(controller.lines.isEmpty)
            controller.expireTextRequest(request.id)
            XCTAssertNil(controller.errorMessage, "旧超时不能把取消变成报错")
        }
        await controller.sendDialogueText("你好")
        XCTAssertNotNil(controller.languagePackRequest, "取消后必须允许重新发送")
        controller.clearCurrent()
    }

    func testRealLanguagePreparationFailureStillReportsError() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        controller.preferences.preferredLanguage = "zh"
        controller.lastOtherLanguage = "en"
        await controller.sendDialogueText("你好")
        guard let request = controller.languagePackRequest else {
            return XCTFail("Expected language preparation request")
        }
        controller.languagePackFailed(URLError(.notConnectedToInternet), for: request.id)
        XCTAssertNotNil(controller.errorMessage)
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

    func testBareSoundCaptionsNeverReachTranslation() {
        for caption in ["掌声", "掌声。", "鼓掌", "音乐", "空白音频。", "无语音", "静音",
                        "Applause.", "Clapping", "♪ Music ♪", "Silence", "No speech",
                        "(掌声) [BLANK_AUDIO]"] {
            XCTAssertNil(RecognizedSpeechText.cleaned(caption), caption)
        }
        for speech in ["请给他一点掌声", "播放音乐", "The applause was loud", "No speech is needed today"] {
            XCTAssertEqual(RecognizedSpeechText.cleaned(speech), speech)
        }
    }

    func testBriefNoiseDoesNotBecomeSpeechOrPartialPreview() {
        let capture = AudioCapture()
        var partials = 0
        var utterances = 0
        capture.onPartial = { _ in partials += 1 }
        capture.onUtterance = { _ in utterances += 1 }
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0, count: 16_000))
        capture.feedExternal(Array(repeating: 0.2, count: 1_600))
        capture.feedExternal(Array(repeating: 0, count: 32_000))
        XCTAssertNil(capture.takePendingSpeech(), "短促噪声不能作为待翻译语音")
        XCTAssertEqual(partials, 0)
        XCTAssertEqual(utterances, 0)
        capture.stop()
    }

    func testRepeatedCaptionsAndSpecialTokensAreDropped() {
        for caption in ["掌声 掌声", "Applause. Applause.", "<|startoftranscript|><|zh|>(掌声)<|endoftext|>",
                        "字幕由Amara.org社区提供", "♪♪"] {
            XCTAssertNil(RecognizedSpeechText.cleaned(caption), caption)
        }
        XCTAssertEqual(RecognizedSpeechText.cleaned("<|0.00|> Hello<|1.00|>"), "Hello")
    }

    func testLowConfidenceAndRepetitiveSegmentsAreDropped() {
        let segments = [
            RecognizedSegment(text: " 你好", avgLogprob: -0.3, compressionRatio: 1.2, noSpeechProb: 0),
            RecognizedSegment(text: " 谢谢观看", avgLogprob: -1.4, compressionRatio: 1.1, noSpeechProb: 0),
            RecognizedSegment(text: " 好好好好好好好好", avgLogprob: -0.2, compressionRatio: 3.1, noSpeechProb: 0),
            RecognizedSegment(text: " 静音", avgLogprob: -0.4, compressionRatio: 1.0, noSpeechProb: 0.9),
            RecognizedSegment(text: " [BLANK_AUDIO]", avgLogprob: -0.1, compressionRatio: 1.0, noSpeechProb: 0),
            RecognizedSegment(text: " 请给他一点掌声", avgLogprob: -0.5, compressionRatio: 1.3, noSpeechProb: 0)
        ]
        XCTAssertEqual(SpeechSegmentFilter.joinedText(segments), "你好 请给他一点掌声")
        XCTAssertEqual(SpeechSegmentFilter.joinedText([segments[1], segments[4]]), "")
    }

    func testSteadyBackgroundNoiseStopsCountingAsSpeech() {
        let capture = AudioCapture()
        capture.nearField = false
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0, count: 16_000))
        // 约 -30 dB 的持续底噪（风扇、空调）连续 60 秒。
        for _ in 0..<60 { capture.feedExternal(Array(repeating: 0.03, count: 16_000)) }
        let countAfterAdapting = utterances.count
        for _ in 0..<30 { capture.feedExternal(Array(repeating: 0.03, count: 16_000)) }
        XCTAssertEqual(utterances.count, countAfterAdapting, "适应底噪后不能继续把持续噪声切成句子")
        XCTAssertNil(capture.takePendingSpeech())
        capture.stop()
    }

    func testLongChangingSpeechDoesNotGetAbsorbedIntoNoiseFloor() {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        var deliveredSamples = 0
        capture.onUtterance = { deliveredSamples += $0.count }
        capture.startExternal()
        // 连续 30 秒有强弱变化的语音能量，不加入句间长静音。
        // 底噪估计应跟随安静部分，而不能持续追上较响的音节。
        for _ in 0..<120 {
            capture.feedExternal(Array(repeating: 0.2, count: 2_560))
            capture.feedExternal(Array(repeating: 0.02, count: 1_440))
        }
        deliveredSamples += capture.takePendingSpeech()?.count ?? 0
        XCTAssertGreaterThanOrEqual(deliveredSamples, 16_000 * 29,
                                    "连续说话不能在底噪适应后丢失后半段音频")
        capture.stop()
    }

    func testUtteranceDropsLongTrailingSilence() {
        let capture = AudioCapture()
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0.2, count: 16_000))
        capture.feedExternal(Array(repeating: 0, count: 32_000))
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.count, 16_000 + 4_800)
        capture.stop()
    }

    func testLiveInterpretationCutsAtShortPauseButDialogueWaitsForFullSentence() {
        for live in [true, false] {
            let capture = AudioCapture()
            capture.liveSegmentation = live
            var utterances: [[Float]] = []
            capture.onUtterance = { utterances.append($0) }
            capture.startExternal()
            capture.feedExternal(Array(repeating: 0.2, count: 64_000))   // 连续讲 4 秒
            capture.feedExternal(Array(repeating: 0, count: 8_000))      // 停顿 0.5 秒
            XCTAssertEqual(utterances.count, live ? 1 : 0, "live=\(live)")
            capture.stop()
        }
    }

    func testLiveInterpretationSplitsLongSpeechAtQuietPointWithoutLosingAudio() {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0.2, count: 112_000))  // 7 秒
        capture.feedExternal(Array(repeating: 0.01, count: 1_600))   // 0.1 秒轻声（词间）
        capture.feedExternal(Array(repeating: 0.2, count: 48_000))   // 再讲 3 秒，超过 8 秒上限
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.count, 112_320, "应在轻声处切开，而不是硬切在 8 秒")
        let rest = capture.takePendingSpeech()
        XCTAssertEqual((utterances.first?.count ?? 0) + (rest?.count ?? 0), 112_000 + 1_600 + 48_000,
                       "切开后前后两段加起来不能丢音频")
        capture.stop()
    }

    func testStalledTextRequestCanExpireAndBeResent() async {
        let controller = ConversationController()
        controller.selectMode(.dialogue)
        controller.preferences.preferredLanguage = "zh"
        controller.lastOtherLanguage = "en"
        controller.dialogueKeyboardDraft = "你好"
        await controller.sendDialogueText("你好")
        guard let first = controller.languagePackRequest else { return XCTFail("Expected request") }
        controller.expireTextRequest(first.id)
        XCTAssertNil(controller.languagePackRequest)
        XCTAssertEqual(controller.dialogueKeyboardDraft, "你好")
        await controller.sendDialogueText("你好")
        let second = controller.languagePackRequest?.id
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first.id)
        controller.expireTextRequest(first.id)
        XCTAssertEqual(controller.languagePackRequest?.id, second)
        controller.clearCurrent()
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
