import XCTest
import Translation
import AVFoundation
@testable import AirPodsTranslator

@MainActor
final class RegressionTests: XCTestCase {
    func testLongDefaultAndCustomSummaryMergeEveryChunkInOrder() async throws {
        let original = String(repeating: "会议内容🙂", count: 8_000)
        let lines = [TranscriptLine(sourceLanguage: "zh", targetLanguage: "en",
            original: original, translated: "English translation", isMine: false)]
        let existing = SummaryOutline(keyPoints: ["earlier"], questions: [], nextSteps: [])
        var chunks: [String] = []
        let result = try await SummaryBatch.summarize(lines, existing: existing) { chunk, previous in
            XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 8_000)
            XCTAssertLessThanOrEqual(chunk.utf8.count, 32_000)
            XCTAssertEqual(previous?.keyPoints, [chunks.isEmpty ? "earlier" : "batch \(chunks.count)"])
            chunks.append(chunk)
            return SummaryOutline(keyPoints: ["batch \(chunks.count)"], questions: [], nextSteps: [])
        }
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertEqual(chunks.joined(), "原文：\(original)\n译文：English translation")
        XCTAssertEqual(result.keyPoints, ["batch \(chunks.count)"])
    }

    func testFailedSummaryChunkStopsFurtherRequests() async {
        let lines = [TranscriptLine(sourceLanguage: "en", targetLanguage: "zh",
            original: String(repeating: "A", count: 24_000), translated: "译文", isMine: false)]
        var calls = 0
        do {
            _ = try await SummaryBatch.summarize(lines, existing: nil) { _, _ in
                calls += 1
                if calls == 2 { throw URLError(.notConnectedToInternet) }
                return SummaryOutline(keyPoints: ["first"], questions: [], nextSteps: [])
            }
            XCTFail("分块失败不能返回不完整总结作为成功结果")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(calls, 2)
    }

    func testCloudSpeechUsesSiblingEndpointAndRejectsUnsecuredAddresses() {
        XCTAssertEqual(CloudSpeechAPI.endpoint(summaryAddress: "https://ai.duwang.win/v1/summary")?.absoluteString,
                       "https://ai.duwang.win/v1/speech")
        XCTAssertNil(CloudSpeechAPI.endpoint(summaryAddress: "http://ai.duwang.win/v1/summary"))
        XCTAssertNil(CloudSpeechAPI.endpoint(summaryAddress: "https://ai.duwang.win/v1/summary?secret=x"))
        XCTAssertEqual(CloudSpeechAPI.rate(.nan), 1)
        XCTAssertEqual(CloudSpeechAPI.rate(0.48), 1, accuracy: 0.001)
        XCTAssertEqual(CloudSpeechAPI.rate(10), 2)
        XCTAssertEqual(CloudSpeechAPI.rate(-1), 0.5)
    }

    private func line(_ text: String) -> TranscriptLine {
        TranscriptLine(sourceLanguage: "en", targetLanguage: "zh",
                       original: text, translated: text, isMine: false)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func controllerWithoutLanguagePacks() -> ConversationController {
        let services = ConversationServices(
            prepareSpeech: {}, requestMicrophonePermission: { true }, startCapture: {},
            recognition: { _, _ in (text: "", language: "en") },
            translation: { text, source, target, _, _ in
                if source == target { return text }
                throw TranslatorError.languagePackRequired(source, target)
            }
        )
        return ConversationController(services: services)
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
        let controller = controllerWithoutLanguagePacks()
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
        let controller = controllerWithoutLanguagePacks()
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
        let controller = controllerWithoutLanguagePacks()
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
        let controller = controllerWithoutLanguagePacks()
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

    func testConfidenceAppliesToWholeUtteranceAndExplicitNoiseIsDropped() {
        let segments = [
            RecognizedSegment(text: " 你好", avgLogprob: -0.3, compressionRatio: 1.2, noSpeechProb: 0),
            RecognizedSegment(text: " 谢谢观看", avgLogprob: -1.4, compressionRatio: 1.1, noSpeechProb: 0),
            RecognizedSegment(text: " 好好好好好好好好", avgLogprob: -0.2, compressionRatio: 3.1, noSpeechProb: 0),
            RecognizedSegment(text: " 静音", avgLogprob: -0.4, compressionRatio: 1.0, noSpeechProb: 0.9),
            RecognizedSegment(text: " [BLANK_AUDIO]", avgLogprob: -0.1, compressionRatio: 1.0, noSpeechProb: 0),
            RecognizedSegment(text: " 请给他一点掌声", avgLogprob: -0.5, compressionRatio: 1.3, noSpeechProb: 0)
        ]
        XCTAssertEqual(SpeechSegmentFilter.joinedText(segments), "你好谢谢观看请给他一点掌声")
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

    func testSustainedSpeechWithoutQuietSyllablesCannotBecomeTheNoiseFloor() {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        capture.quality = true
        capture.nearField = false
        var delivered: [[Float]] = []
        capture.onUtterance = { delivered.append($0) }
        capture.startExternal()
        // A compressed lecture can remain loud for many seconds. There is no real pause here.
        for index in 0..<1_000 {
            let amplitude: Float = index % 3 == 0 ? 0.12 : index % 3 == 1 ? 0.18 : 0.22
            capture.feedExternal((0..<320).map { sin(Float($0) * 0.1) * amplitude })
        }
        XCTAssertTrue(delivered.isEmpty, "音量持续变化的讲话不能被底噪追上后提前切句")
        XCTAssertEqual(capture.takePendingSpeech()?.count, 320_000, "最后半句仍要完整保留")
        capture.stop()
    }

    func testUncertainSpokenNegationIsNotDeletedFromTheRecognizedSentence() {
        let segments = [
            RecognizedSegment(text: "We should", avgLogprob: -0.3, compressionRatio: 1, noSpeechProb: 0),
            RecognizedSegment(text: "not", avgLogprob: -1.1, compressionRatio: 1, noSpeechProb: 0),
            RecognizedSegment(text: "release on Friday.", avgLogprob: -0.3, compressionRatio: 1, noSpeechProb: 0)
        ]
        XCTAssertEqual(SpeechSegmentFilter.joinedText(segments), "We should not release on Friday.",
                       "不能删除低置信度词后把否定句拼成肯定句")
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

    func testBreathingPauseDoesNotSplitTheSentenceBeforeItsFinalWords() {
        for quality in [false, true] {
            let capture = AudioCapture()
            capture.liveSegmentation = true
            capture.quality = quality
            var utterances: [[Float]] = []
            capture.onUtterance = { utterances.append($0) }
            capture.startExternal()
            capture.feedExternal(Array(repeating: 0.2, count: 64_000))
            capture.feedExternal(Array(repeating: 0, count: 8_000)) // 换气 0.5 秒
            XCTAssertTrue(utterances.isEmpty, "换气不能提前提交半句话，quality=\(quality)")
            capture.feedExternal(Array(repeating: 0.2, count: 16_000)) // 句尾限定或否定词
            capture.feedExternal(Array(repeating: 0, count: 28_800))
            XCTAssertEqual(utterances.count, 1, "整句只能提交一次，quality=\(quality)")
            XCTAssertEqual(utterances.first?.count, 64_000 + 8_000 + 16_000 + 4_800)
            XCTAssertNil(capture.takePendingSpeech())
            capture.stop()
        }
    }

    func testQualityModeWaitsForFullSentencePauseAndStillProvidesPreviews() {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        capture.quality = true
        var finals = 0, previews = 0
        capture.onUtterance = { _ in finals += 1 }
        capture.onPartial = { _ in previews += 1 }
        capture.startExternal()
        capture.feedExternal(Array(repeating: 0.2, count: 64_000))
        capture.feedExternal(Array(repeating: 0, count: 19_200)) // 1.2 秒尚未达到质量档句末
        XCTAssertEqual(finals, 0)
        XCTAssertGreaterThan(previews, 0, "等待整句时仍需提供实时预览")
        capture.feedExternal(Array(repeating: 0, count: 6_400))
        XCTAssertEqual(finals, 1)
        capture.stop()
    }

    func testBothModesProvideMultiplePreviewOpportunitiesBeforeSentenceEnd() {
        for quality in [false, true] {
            let capture = AudioCapture()
            capture.liveSegmentation = true
            capture.quality = quality
            var previews = 0, finals = 0
            capture.onPartial = { _ in previews += 1 }
            capture.onUtterance = { _ in finals += 1 }
            capture.startExternal()
            capture.feedExternal(Array(repeating: 0.2, count: 40_000))
            XCTAssertGreaterThanOrEqual(previews, 2, "开口后应及时提供可互相确认的预览，quality=\(quality)")
            XCTAssertEqual(finals, 0, "预览刷新不得提前触发整句提交")
            capture.stop()
        }
    }

    func testBothModesKeepALongSentenceTogetherPastTwelveSeconds() {
        for quality in [false, true] {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        capture.quality = quality
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        // 14 秒连续讲话含强弱音节，不应在旧的 12 秒上限处切掉后半句。
        for _ in 0..<56 {
            capture.feedExternal(Array(repeating: 0.2, count: 2_560))
            capture.feedExternal(Array(repeating: 0.02, count: 1_440))
        }
        capture.feedExternal(Array(repeating: 0.2, count: 3_200))
        XCTAssertTrue(utterances.isEmpty)
        capture.feedExternal(Array(repeating: 0, count: 28_800))
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.count, 16_000 * 14 + 3_200 + 4_800)
        capture.stop()
        }
    }

    func testPreviewWaitsForAgreementAndNeverTranslatesPartialEnglishWords() {
        var stabilizer = LiveTranscriptStabilizer()
        XCTAssertEqual(stabilizer.update("We need to increase", language: "en"), "")
        XCTAssertEqual(stabilizer.update("We need to include everyone.", language: "en"), "We need to")
        XCTAssertEqual(stabilizer.update("We need to include everyone today.", language: "en"),
                       "We need to include everyone")
        XCTAssertEqual(stabilizer.update("We need to include everyone today.", language: "en"),
                       "We need to include everyone today.")
        stabilizer.reset()
        XCTAssertEqual(stabilizer.update("I can", language: "en"), "")
        XCTAssertEqual(stabilizer.update("I can't attend.", language: "en"), "I")
        XCTAssertEqual(stabilizer.update("完全不同的内容", language: "zh"), "")
        XCTAssertEqual(stabilizer.update("完全不同的内容", language: "zh"), "完全不同的内容")
        stabilizer.reset()
        XCTAssertEqual(stabilizer.update("We need to include everyone today.", language: "en"), "")
    }

    func testNewPreferencesPrioritizeQualityAndPreserveExplicitChoice() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "processingMode")
        defer {
            if let previous { defaults.set(previous, forKey: "processingMode") }
            else { defaults.removeObject(forKey: "processingMode") }
        }
        defaults.removeObject(forKey: "processingMode")
        XCTAssertEqual(Preferences().processingMode, .quality)
        defaults.set(ProcessingMode.fast.rawValue, forKey: "processingMode")
        XCTAssertEqual(Preferences().processingMode, .fast)
        defaults.set(ProcessingMode.quality.rawValue, forKey: "processingMode")
        XCTAssertEqual(Preferences().processingMode, .quality)
    }

    func testLiveInterpretationSplitsLongSpeechAtQuietPointWithoutLosingAudio() {
        let capture = AudioCapture()
        capture.liveSegmentation = true
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        for _ in 0..<108 {
            capture.feedExternal(Array(repeating: 0.2, count: 2_560))
            capture.feedExternal(Array(repeating: 0.02, count: 1_440))
        } // 27 秒连续讲话
        capture.feedExternal(Array(repeating: 0.01, count: 1_600))   // 0.1 秒轻声（词间）
        for _ in 0..<12 {
            capture.feedExternal(Array(repeating: 0.2, count: 2_560))
            capture.feedExternal(Array(repeating: 0.02, count: 1_440))
        } // 再讲 3 秒，超过 28 秒安全上限
        XCTAssertEqual(utterances.count, 1)
        XCTAssertTrue((16_000 * 26...16_000 * 28).contains(utterances.first?.count ?? 0),
                      "应在低音量区间切开，而不是切在下一词的强语音上")
        let rest = capture.takePendingSpeech()
        XCTAssertEqual((utterances.first?.count ?? 0) + (rest?.count ?? 0), 16_000 * 30 + 1_600,
                       "切开后前后两段加起来不能丢音频")
        capture.stop()
    }

    func testCommittedPrefixKeepsEveryRemainingSampleAndRejectsStaleWindow() {
        let capture = AudioCapture()
        capture.startExternal()
        let audio = (0..<32_000).map { Float(0.15) + Float($0 % 100) / 1000 }
        capture.feedExternal(audio)
        let originalWindow = capture.windowID
        XCTAssertTrue(capture.commitPrefix(16_000, window: originalWindow))
        XCTAssertFalse(capture.commitPrefix(16_000, window: originalWindow), "同一个旧前缀不能裁切两次")
        XCTAssertEqual(capture.takePendingSpeech(), Array(audio[16_000...]))
        capture.stop()
    }

    func testCorruptAudioCannotPoisonLaterSpeechDetection() {
        let capture = AudioCapture()
        var utterances: [[Float]] = []
        capture.onUtterance = { utterances.append($0) }
        capture.startExternal()
        capture.feedExternal([.nan, .infinity])
        capture.feedExternal(Array(repeating: 0.2, count: 3_200))
        capture.feedExternal(Array(repeating: 0, count: 32_000))
        XCTAssertEqual(utterances.count, 1)
        XCTAssertTrue(utterances[0].allSatisfy(\.isFinite))
        XCTAssertTrue(capture.level.isFinite)
        capture.stop()
    }

    func testStalledTextRequestCanExpireAndBeResent() async {
        let controller = controllerWithoutLanguagePacks()
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

    func testPendingSnapshotKeepsTextWithoutPersistingAnActiveTask() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConversationStore(directory: url, summarize: { _ in "summary" })
        let id = UUID()
        var entry = line("first")
        entry.translationPending = true
        try await store.save([entry], id: id)
        let saved = try XCTUnwrap(ConversationStore(directory: url).conversations.first?.lines.first)
        XCTAssertEqual(saved.original, entry.original)
        XCTAssertEqual(saved.translated, entry.translated)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertNotEqual(saved.translationPending, true)
        XCTAssertNotNil(saved.translationIssue, "未确认的译文不能静默变成正式译文")
        entry.translationPending = nil
        try await store.save([entry], id: id)
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertNil(store.conversations.first?.lines.first?.translationIssue)
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

    func testQueuedAudioFromStoppedCaptureCannotEnterRestartedCapture() throws {
        let capture = AudioCapture()
        capture.startExternal()
        let oldRecording = try XCTUnwrap(capture.recordingID)
        capture.stop()
        capture.startExternal()
        let currentRecording = try XCTUnwrap(capture.recordingID)
        XCTAssertNotEqual(oldRecording, currentRecording)
        capture.receive(Array(repeating: 0.2, count: 16_000), recordingID: oldRecording)
        XCTAssertNil(capture.takePendingSpeech(), "暂停前排队的音频不能成为继续后的新语音")
        capture.receive(Array(repeating: 0.2, count: 3_200), recordingID: currentRecording)
        XCTAssertEqual(capture.takePendingSpeech()?.count, 3_200)
        capture.stop()
        capture.receive(Array(repeating: 0.2, count: 16_000), recordingID: currentRecording)
        XCTAssertNil(capture.takePendingSpeech())
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
