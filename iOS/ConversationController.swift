import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import Translation

struct LanguagePackRequest: Identifiable {
    let id = UUID()
    let configuration: TranslationSession.Configuration
}

@MainActor
final class ConversationController: ObservableObject {
    @Published var mode: ConversationMode = .listen
    @Published var lines: [TranscriptLine] = []
    @Published var status = "准备就绪"
    @Published var errorMessage: String?
    @Published var detectedLanguage = ""
    @Published var lastOtherLanguage = "en"
    @Published var imageOriginal = ""
    @Published var imageTranslation = ""
    @Published var imageIsProcessing = false
    @Published var textOriginal = ""
    @Published var textTranslation = ""
    @Published var textDetectedLanguage = ""
    @Published var textTargetLanguage = ""
    @Published var showPaywall = false
    @Published private(set) var isBroadcastMode = false
    @Published var destination: AudioDestination = .earphones
    @Published private(set) var phase: ConversationPhase = .idle
    @Published private(set) var outputRouteName = "未检测到播放设备"
    @Published var correctionLanguage: String?
    @Published var liveText = ""
    @Published private(set) var languagePackRequest: LanguagePackRequest?
    var isRunning: Bool { phase.isActive && sessionID != nil }
    var isPreparing: Bool { phase == .preparing }
    var activeDialogueLanguage: String? { isRunning && mode == .dialogue ? forcedLanguage : nil }
    private var recognitionLanguage: String? {
        forcedLanguage ?? correctionLanguage ??
        (mode == .listen && preferences.sourceLanguage != "auto" ? preferences.sourceLanguage : nil)
    }

    let preferences = Preferences()
    let store = ConversationStore()
    let whisper = WhisperService()
    let capture = AudioCapture()
    let watch = WatchBridge()
    let subscriptions = SubscriptionManager()
    let usage = UsageMeter()
    let broadcastInbox = BroadcastAudioInbox()
    private let translator = LocalTranslator()
    private let player = SpeechPlayer()
    private var observers = Set<AnyCancellable>()
    private var pending: [[Float]] = []
    private var latestPartial: [Float]?
    private var draining = false
    private var sessionID: UUID?
    private var imageRequestID: UUID?
    private var revisionID: UUID?
    private var waitingUtterance: PendingUtterance?
    private var waitingImage: (text: String, source: String, target: String, requestID: UUID)?
    private var waitingText: (text: String, source: String, target: String, requestID: UUID)?
    private var waitingRevision: PendingRevision?
    private var textRequestID: UUID?
    private var forcedLanguage: String?

    private struct PendingRevision {
        let lineID: UUID
        let text: String
        let source: String
        let target: String
        let revisionID: UUID
    }

    private struct PendingUtterance {
        let text: String
        let source: String
        let target: String
        let mine: Bool
        let sessionID: UUID
    }

    private func transition(to next: ConversationPhase) {
        assert(phase.canTransition(to: next), "Unexpected conversation transition: \(phase) → \(next)")
        phase = next
    }

    init() {
        preferences.$nearField
            .sink { [weak self] enabled in
                Task { @MainActor in self?.capture.nearField = enabled }
            }
            .store(in: &observers)
        preferences.$processingMode
            .sink { [weak self] selectedMode in
                let highQuality = selectedMode == .quality
                Task { @MainActor in self?.capture.quality = highQuality }
            }
            .store(in: &observers)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.consumeUsage()
                    self?.broadcastInbox.poll()
                }
            }
            .store(in: &observers)
        broadcastInbox.onActiveChange = { [weak self] active in
            guard let self else { return }
            if active {
                if self.isRunning { self.pause() }
                Task { await self.startBroadcast() }
            } else if self.isBroadcastMode {
                self.end()
            }
        }
        broadcastInbox.canConsume = { [weak self] in
            self?.isBroadcastMode == true && self?.capture.isRecording == true
        }
        broadcastInbox.onSamples = { [weak self] samples in
            self?.capture.feedExternal(samples)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let value = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard value == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.handleAudioInterruption() }
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateOutputRoute() }
            }
            .store(in: &observers)
        updateOutputRoute()
        watch.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case "toggle": Task {
                if self.isRunning { self.end(save: true) }
                else { await self.start() }
            }
            case "replay": self.replay()
            default: break
            }
        }
    }

    func start() async {
        guard !isRunning, !isPreparing, phase != .replaying else { return }
        if !subscriptions.isPro &&
            (mode == .listen ? usage.remainingLiveSeconds == 0 : usage.remainingDialogueLines == 0) {
            await subscriptions.refresh()
            guard !isRunning, !isPreparing, phase != .replaying else { return }
        }
        guard subscriptions.isPro || (mode == .listen ? usage.remainingLiveSeconds > 0 : usage.remainingDialogueLines > 0) else {
            showPaywall = true
            status = "今日免费额度已用完"
            return
        }
        let activeSession = UUID()
        sessionID = activeSession
        transition(to: .preparing)
        status = "加载离线语音模型…"
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard sessionID == activeSession else { return }
        guard allowed else {
            sessionID = nil
            transition(to: .idle)
            errorMessage = "请在系统设置中允许麦克风访问"
            status = "未获得麦克风权限"
            return
        }
        do {
            try await whisper.prepare()
            guard sessionID == activeSession else { return }
            capture.nearField = preferences.nearField
            capture.quality = preferences.processingMode == .quality
            configureCaptureCallbacks()
            try capture.start()
            transition(to: .listening)
            status = "正在自动识别语音…"
            updateOutputRoute()
            watch.publish(running: true, latest: lines.last?.translated ?? "")
        } catch {
            guard sessionID == activeSession else { return }
            sessionID = nil
            transition(to: .idle)
            status = "启动失败"
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        usage.track(active: !subscriptions.isPro && mode == .listen && capture.isRecording)
        sessionID = nil
        isBroadcastMode = false
        capture.stop()
        player.stop()
        pending = []
        latestPartial = nil
        waitingUtterance = nil
        waitingImage = nil
        waitingText = nil
        waitingRevision = nil
        languagePackRequest = nil
        forcedLanguage = nil
        liveText = ""
        transition(to: .paused)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "已暂停"
        updateOutputRoute()
        watch.publish(running: false, latest: lines.last?.translated ?? "")
    }

    private func handleAudioInterruption() {
        guard isRunning || isPreparing || phase == .replaying else { return }
        pause()
        status = "录音被系统打断，请点开始继续"
    }

    func end(save: Bool = false) {
        pause()
        guard save || preferences.saveAutomatically else { return }
        let snapshot = lines
        guard !snapshot.isEmpty else {
            if save { status = "已结束" }
            return
        }
        if save { status = "正在保存到历史…" }
        Task {
            do {
                try await store.save(snapshot)
                if save, sessionID == nil { status = "已保存到历史" }
            } catch {
                errorMessage = "保存对话失败：\(error.localizedDescription)"
            }
        }
    }

    func saveCurrent() async {
        let snapshot = lines
        guard !snapshot.isEmpty else { status = "没有可保存的对话"; return }
        status = "正在生成摘要…"
        do {
            try await store.save(snapshot)
            status = "对话已保存"
        } catch {
            status = "保存失败"
            errorMessage = error.localizedDescription
        }
    }
    func clearCurrent() { revisionID = nil; waitingRevision = nil; lines = []; liveText = ""; status = "已清空" }

    func replay() {
        guard let line = lines.last else { return }
        guard !draining, pending.isEmpty, waitingUtterance == nil,
              phase == .listening || phase == .paused || phase == .idle else {
            status = "当前语音处理完后再重播"
            return
        }
        let previousPhase = phase
        transition(to: .replaying)
        let activeSession = sessionID
        if isRunning {
            capture.stop()
            latestPartial = nil
            liveText = ""
        }
        let output: AudioDestination = line.isMine ? .speaker : destination
        let played = player.speak(line.translated, language: line.targetLanguage,
                                  rate: preferences.speechRate, destination: output) { [weak self] in
            guard let self else { return }
            guard self.sessionID == activeSession else { return }
            self.transition(to: previousPhase)
            self.resumeCapture()
        }
        if !played { errorMessage = "当前设备没有\(AppLanguage.name(line.targetLanguage))语音" }
        updateOutputRoute()
    }

    func overrideLanguage(_ code: String?) {
        correctionLanguage = code
    }

    func beginDialogue(in language: String) async {
        if isRunning { pause() }
        mode = .dialogue
        forcedLanguage = language
        await start()
    }

    private func configureCaptureCallbacks() {
        capture.onPartial = { [weak self] samples in
            self?.latestPartial = samples
            Task { await self?.drain() }
        }
        capture.onUtterance = { [weak self] samples in
            self?.pending.append(samples)
            self?.latestPartial = nil
            Task { await self?.drain() }
        }
    }

    private func startBroadcast() async {
        guard mode == .listen, !isRunning, !isPreparing else { return }
        guard BroadcastStorage.directory != nil else {
            errorMessage = "屏幕广播需要启用 App Group，请检查安装配置"
            return
        }
        guard subscriptions.isPro || usage.remainingLiveSeconds > 0 else {
            showPaywall = true
            return
        }
        let token = UUID()
        sessionID = token
        transition(to: .preparing)
        status = "准备屏幕音频识别…"
        do {
            try await whisper.prepare()
            guard sessionID == token else { return }
            guard broadcastInbox.active else {
                sessionID = nil
                transition(to: .idle)
                status = "屏幕广播已结束"
                return
            }
            configureCaptureCallbacks()
            capture.startExternal()
            isBroadcastMode = true
            transition(to: .listening)
            status = "正在识别屏幕音频…"
            watch.publish(running: true, latest: lines.last?.translated ?? "")
        } catch {
            guard sessionID == token else { return }
            sessionID = nil
            transition(to: .idle)
            errorMessage = error.localizedDescription
            status = "屏幕音频识别启动失败"
        }
    }

    private func consumeUsage() {
        usage.track(active: !subscriptions.isPro && mode == .listen && capture.isRecording)
        guard !subscriptions.isPro, isRunning, mode == .listen,
              usage.remainingLiveSeconds == 0 else { return }
        end()
        status = "今日免费同传时长已用完"
        showPaywall = true
    }

    private func checkDialogueQuota() -> Bool {
        guard mode == .dialogue, !subscriptions.isPro else { return true }
        usage.recordDialogueLine()
        guard usage.remainingDialogueLines == 0 else { return true }
        end()
        status = "今日免费对话句数已用完"
        showPaywall = true
        return false
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty || latestPartial != nil {
            if !pending.isEmpty {
                let samples = pending.removeFirst()
                await process(samples)
            } else if let samples = latestPartial {
                latestPartial = nil
                await processPartial(samples)
            }
        }
    }

    private func processPartial(_ samples: [Float]) async {
        guard let activeSession = sessionID else { return }
        transition(to: .recognizing)
        defer {
            if sessionID == activeSession && phase == .recognizing && pending.isEmpty {
                transition(to: .listening)
            }
        }
        do {
            let recognized = try await whisper.recognize(samples, language: recognitionLanguage)
            if sessionID == activeSession && pending.isEmpty && waitingUtterance == nil {
                liveText = RecognizedSpeechText.cleaned(recognized.text) ?? ""
            }
        } catch { }
    }

    private func process(_ samples: [Float]) async {
        guard let activeSession = sessionID else { return }
        transition(to: .recognizing)
        let selectedLanguage = recognitionLanguage
        do {
            let recognized = try await whisper.recognize(samples, language: selectedLanguage)
            guard sessionID == activeSession else { return }
            liveText = ""
            guard let recognizedText = RecognizedSpeechText.cleaned(recognized.text) else {
                transition(to: .listening)
                return
            }
            let source = selectedLanguage ?? AppLanguage.normalizedCode(recognized.language)
            correctionLanguage = nil
            guard AppLanguage.all.contains(where: { $0.code == source }) else {
                status = "暂不支持识别到的语言：\(source)"
                transition(to: .listening)
                return
            }
            detectedLanguage = source
            let mine = source == preferences.preferredLanguage && mode == .dialogue
            if mine == false && source != preferences.preferredLanguage { lastOtherLanguage = source }
            if lastOtherLanguage == preferences.preferredLanguage {
                lastOtherLanguage = preferences.preferredLanguage == "en" ? "zh" : "en"
            }
            let target = mine ? lastOtherLanguage : preferences.preferredLanguage
            guard source != target else { transition(to: .listening); return }
            await translateAndPlay(PendingUtterance(text: recognizedText, source: source,
                                                    target: target, mine: mine, sessionID: activeSession))
        } catch {
            guard sessionID == activeSession else { return }
            status = "没听清，继续倾听…"
            transition(to: .listening)
        }
    }

    private func translateAndPlay(_ item: PendingUtterance, allowDownload: Bool = true) async {
        guard sessionID == item.sessionID else { return }
        do {
            transition(to: .translating)
            status = "正在翻译 \(AppLanguage.name(item.source))…"
            let translated = try await translator.translate(item.text, from: item.source,
                                                             to: item.target, mode: preferences.processingMode,
                                                             terms: preferences.terms)
            guard sessionID == item.sessionID else { return }
            let line = TranscriptLine(sourceLanguage: item.source, targetLanguage: item.target,
                                      original: item.text, translated: translated, isMine: item.mine)
            lines.append(line)
            watch.publish(running: isRunning, latest: translated)
            status = "检测到\(AppLanguage.name(item.source))"
            if !preferences.autoReadAloud || isBroadcastMode {
                guard checkDialogueQuota() else { return }
                resumeCapture()
                return
            }
            capture.stop()
            transition(to: .speaking)
            latestPartial = nil
            liveText = ""
            await withCheckedContinuation { continuation in
                let played = player.speak(translated, language: item.target,
                                          rate: preferences.speechRate,
                                          destination: item.mine ? .speaker : destination) {
                    continuation.resume()
                }
                if !played { errorMessage = "当前设备没有\(AppLanguage.name(item.target))语音，译文已显示" }
                updateOutputRoute()
            }
            if sessionID == item.sessionID, checkDialogueQuota() { resumeCapture() }
        } catch {
            guard sessionID == item.sessionID else { return }
            if let reason = error as? TranslatorError,
               case let .languagePackRequired(source, target) = reason,
               allowDownload {
                guard languagePackRequest == nil else {
                    errorMessage = "另一组语言包正在下载，请稍后重试"
                    resumeCapture()
                    return
                }
                capture.stop()
                pending = []
                latestPartial = nil
                waitingUtterance = item
                transition(to: .waitingForLanguagePack)
                requestLanguagePack(from: source, to: target)
                return
            }
            status = "这句话没有翻译成功，请再说一次"
            resumeCapture()
        }
    }

    private func resumeCapture() {
        guard isRunning, sessionID != nil, phase != .replaying else { return }
        do {
            if !capture.isRecording {
                if isBroadcastMode { capture.startExternal() }
                else { try capture.start() }
            }
            transition(to: .listening)
            status = isBroadcastMode ? "正在识别屏幕音频…" : "正在自动识别语音…"
            updateOutputRoute()
        }
        catch {
            sessionID = nil
            transition(to: .paused)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            status = "录音已停止"
            errorMessage = error.localizedDescription
            watch.publish(running: false, latest: lines.last?.translated ?? "")
        }
    }

    private func requestLanguagePack(from source: String, to target: String) {
        status = "需要下载\(AppLanguage.name(source)) → \(AppLanguage.name(target))语言包"
        let configuration = TranslationConfigurationFactory.make(
            source: source, target: target, mode: preferences.processingMode
        )
        languagePackRequest = LanguagePackRequest(configuration: configuration)
    }

    func languagePackReady(for requestID: UUID) {
        guard languagePackRequest?.id == requestID else { return }
        let utterance = waitingUtterance
        let image = waitingImage
        let text = waitingText
        let revision = waitingRevision
        languagePackRequest = nil
        waitingUtterance = nil
        waitingImage = nil
        waitingText = nil
        waitingRevision = nil
        Task {
            if let utterance { await translateAndPlay(utterance, allowDownload: false) }
            if let image {
                await translateImageText(image.text, from: image.source, to: image.target,
                                         requestID: image.requestID, allowDownload: false)
            }
            if let text {
                await translateTextContent(text.text, from: text.source, to: text.target,
                                           requestID: text.requestID, allowDownload: false)
            }
            if let revision { await applyRevision(revision, allowDownload: false) }
        }
    }

    func languagePackFailed(_ error: Error, for requestID: UUID) {
        guard languagePackRequest?.id == requestID else { return }
        let resumeUtterance = waitingUtterance != nil
        languagePackRequest = nil
        waitingUtterance = nil
        waitingImage = nil
        waitingText = nil
        waitingRevision = nil
        errorMessage = error.localizedDescription
        status = "语言包下载未完成"
        if resumeUtterance { resumeCapture() }
    }

    func reviseLastLine(_ lineID: UUID, text: String, source: String, target: String) async {
        guard lines.last?.id == lineID else {
            errorMessage = "只能修改当前对话的上一句"
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, source != target else {
            errorMessage = "请输入原文并选择不同的源语言和目标语言"
            return
        }
        let token = UUID()
        revisionID = token
        await applyRevision(PendingRevision(lineID: lineID, text: trimmed, source: source,
                                            target: target, revisionID: token))
    }

    private func applyRevision(_ revision: PendingRevision, allowDownload: Bool = true) async {
        guard revisionID == revision.revisionID, lines.last?.id == revision.lineID else { return }
        do {
            status = "正在重新翻译上一句…"
            let result = try await translator.translate(revision.text, from: revision.source,
                                                        to: revision.target, mode: preferences.processingMode,
                                                        terms: preferences.terms)
            guard revisionID == revision.revisionID, lines.last?.id == revision.lineID else { return }
            guard let index = lines.indices.last else { return }
            lines[index].original = revision.text
            lines[index].sourceLanguage = revision.source
            lines[index].targetLanguage = revision.target
            lines[index].translated = result
            lines[index].isMine = mode == .dialogue && revision.source == preferences.preferredLanguage
            watch.publish(running: isRunning, latest: result)
            status = "上一句已更新"
        } catch {
            guard revisionID == revision.revisionID else { return }
            if let reason = error as? TranslatorError,
               case let .languagePackRequired(source, target) = reason, allowDownload {
                guard languagePackRequest == nil else {
                    errorMessage = "另一组语言包正在下载，请稍后重试"
                    return
                }
                waitingRevision = revision
                requestLanguagePack(from: source, to: target)
                return
            }
            errorMessage = error.localizedDescription
            status = "重新翻译失败"
        }
    }

    private func updateOutputRoute() {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        outputRouteName = names.isEmpty ? "未检测到播放设备" : names.joined(separator: "、")
    }

    func translateText(_ text: String, from selectedSource: String, to target: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入要翻译的文字"; return }
        guard languagePackRequest == nil else { errorMessage = "请先完成当前语言包下载"; return }
        let requestID = UUID()
        textRequestID = requestID
        textOriginal = trimmed
        textTranslation = ""
        textTargetLanguage = target
        let source: String
        if selectedSource == "auto" {
            let detector = NLLanguageRecognizer()
            detector.processString(trimmed)
            let detected = AppLanguage.normalizedCode(detector.dominantLanguage?.rawValue ?? "")
            source = AppLanguage.all.contains(where: { $0.code == detected })
                ? detected : fallbackTextLanguage(for: trimmed, target: target)
        } else {
            source = selectedSource
        }
        guard AppLanguage.all.contains(where: { $0.code == source }) else {
            errorMessage = "无法确定原文语言，请手动选择"
            return
        }
        textDetectedLanguage = source
        await translateTextContent(trimmed, from: source, to: target, requestID: requestID)
    }

    private func translateTextContent(_ text: String, from source: String, to target: String,
                                      requestID: UUID, allowDownload: Bool = true) async {
        guard textRequestID == requestID else { return }
        do {
            let result = try await translator.translate(text, from: source, to: target,
                                                        mode: preferences.processingMode, terms: preferences.terms)
            guard textRequestID == requestID else { return }
            textTranslation = result
            guard preferences.autoReadAloud else { return }
            let shouldResumeCapture = isRunning && capture.isRecording
            let activeSession = sessionID
            if shouldResumeCapture {
                capture.stop()
                latestPartial = nil
                liveText = ""
            }
            let played = player.speak(result, language: target, rate: preferences.speechRate,
                                      destination: destination) { [weak self] in
                guard let self, shouldResumeCapture, self.sessionID == activeSession else { return }
                self.resumeCapture()
            }
            if !played {
                status = "当前设备没有\(AppLanguage.name(target))语音，译文已显示"
            }
        } catch {
            guard textRequestID == requestID else { return }
            if let reason = error as? TranslatorError,
               case let .languagePackRequired(from, to) = reason, allowDownload {
                guard languagePackRequest == nil else {
                    errorMessage = "另一组语言包正在下载，请稍后重试"
                    return
                }
                waitingText = (text, source, target, requestID)
                requestLanguagePack(from: from, to: to)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func fallbackTextLanguage(for text: String, target: String) -> String {
        let scalars = text.unicodeScalars
        let containsHan = scalars.contains {
            (0x3400...0x4DBF).contains($0.value) ||
            (0x4E00...0x9FFF).contains($0.value) ||
            (0xF900...0xFAFF).contains($0.value)
        }
        if containsHan { return "zh" }
        let containsLatin = scalars.contains {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }
        if containsLatin && target != "en" { return "en" }
        return ""
    }

    func translateImage(_ data: Data) async {
        guard languagePackRequest == nil else {
            errorMessage = "语言包正在下载，请完成后再选择图片"
            return
        }
        let requestID = UUID()
        imageRequestID = requestID
        imageIsProcessing = true
        defer { if imageRequestID == requestID { imageIsProcessing = false } }
        do {
            imageTranslation = ""
            imageOriginal = ""
            let original = try await PhotoOCR.recognize(data)
            guard imageRequestID == requestID else { return }
            guard !original.isEmpty else { throw TranslatorError.emptyImageText }
            imageOriginal = original
            let detector = NLLanguageRecognizer()
            detector.processString(original)
            let source = AppLanguage.normalizedCode(detector.dominantLanguage?.rawValue ?? "en")
            await translateImageText(original, from: source, to: preferences.preferredLanguage,
                                     requestID: requestID)
        } catch {
            if imageRequestID == requestID { errorMessage = error.localizedDescription }
        }
    }

    private func translateImageText(_ text: String, from source: String, to target: String,
                                    requestID: UUID,
                                    allowDownload: Bool = true) async {
        guard imageRequestID == requestID else { return }
        do {
            let translation = try await translator.translate(text, from: source, to: target,
                                                              mode: preferences.processingMode,
                                                              terms: preferences.terms)
            guard imageRequestID == requestID else { return }
            imageTranslation = translation
        } catch {
            guard imageRequestID == requestID else { return }
            if let reason = error as? TranslatorError,
               case let .languagePackRequired(from, to) = reason,
               allowDownload {
                guard languagePackRequest == nil else {
                    errorMessage = "另一组语言包正在下载，请稍后重试"
                    return
                }
                waitingImage = (text, source, target, requestID)
                requestLanguagePack(from: from, to: to)
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}
