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
    @Published private(set) var mode: ConversationMode = .listen
    @Published var dialogueKeyboardDraft = ""
    @Published var dialogueKeyboardEnabled = false
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
    @Published private(set) var deliveredDialogueTextID: UUID?
    private(set) var deliveredDialogueText = ""
    @Published var isKeyboardInputFocused = false
    @Published var showPaywall = false
    @Published private(set) var isBroadcastMode = false
    @Published var destination: AudioDestination = .earphones
    @Published private(set) var phase: ConversationPhase = .idle
    @Published private(set) var outputRouteName = "未检测到播放设备"
    @Published private(set) var isSpeechPlaying = false
    @Published var correctionLanguage: String?
    @Published var liveText = ""
    @Published private(set) var liveTranslation = ""
    private var previewRequestID: UUID?
    private var previewTask: Task<Void, Never>?
    private var previewStabilizer = LiveTranscriptStabilizer()
    private struct PreviewInput: Equatable {
        let text: String
        let source: String
        let target: String
        let session: UUID

        func extends(_ earlier: Self) -> Bool {
            session == earlier.session && source == earlier.source && target == earlier.target &&
                text.hasPrefix(earlier.text)
        }
    }
    private var latestPreview: PreviewInput?
    private var completedPreview: PreviewInput?
    @Published private(set) var languagePackRequest: LanguagePackRequest?
    @Published private(set) var isEnding = false
    @Published private(set) var hasEnded = false
    private var saveWhenEnded = false
    private var conversationID = UUID()
    var currentConversationID: UUID { conversationID }
    var isRunning: Bool { phase.isActive && sessionID != nil }
    var isPreparing: Bool { phase == .preparing }
    var activeDialogueLanguage: String? { isRunning && mode == .dialogue ? forcedLanguage : nil }
    private var recognitionLanguage: String? {
        forcedLanguage ?? correctionLanguage ??
        Preferences.manualSource(preferences.sourceLanguage, target: preferences.preferredLanguage)
    }

    let preferences = Preferences()
    let store: ConversationStore
    private let liveSummary = LiveSummary()
    private let dialogueSummary = LiveSummary()
    var summary: LiveSummary { mode == .listen ? liveSummary : dialogueSummary }
    let pictureInPicture = SubtitlePictureInPicture()
    let whisper: WhisperService
    let capture: AudioCapture
    let watch = WatchBridge()
    let subscriptions = SubscriptionManager()
    let usage = UsageMeter()
    let broadcastInbox = BroadcastAudioInbox()
    private let services: ConversationServices
    private let player = SpeechPlayer()
    private var observers = Set<AnyCancellable>()
    private struct CapturedAudio {
        let samples: [Float]
        let language: String?
    }
    private func capturedAudio(_ samples: [Float]) -> CapturedAudio {
        CapturedAudio(samples: samples, language: recognitionLanguage)
    }
    private var pending: [CapturedAudio] = []
    private var pausedSamples: [CapturedAudio] = []
    private var activeSamples: (audio: CapturedAudio, session: UUID)?
    private var latestPartial: (samples: [Float], window: UUID)?
    private var recognitionWindow: UUID?
    private var draining = false
    private var liveTranslations: [PendingUtterance] = []
    private var activeLiveTranslation: PendingUtterance?
    private var liveTranslationTask: Task<Void, Never>?
    private var liveTranslationWorkerID: UUID?
    private var sessionID: UUID?
    private var imageRequestID: UUID?
    private var revisionID: UUID?
    private var playbackID: UUID?
    private var waitingUtterance: PendingUtterance?
    private var pausedUtterances: [PendingUtterance] = []
    private var restoringUtterance: PendingUtterance?
    private var languagePackResumeID: UUID?
    private var textRequestTimeout: Task<Void, Never>?
    private var waitingImage: (text: String, source: String, target: String, requestID: UUID)?
    private var waitingText: (text: String, source: String, target: String, requestID: UUID)?
    private var waitingRevision: PendingRevision?
    @Published private(set) var textRequestID: UUID?
    var isTranslatingText: Bool { textRequestID != nil }
    private var textRequestIsDialogue = false
    private var textDialogueConversationID: UUID?
    private var forcedLanguage: String?
    private var dialogueInputStopped = false

    private struct PendingRevision {
        let lineID: UUID
        let text: String
        let source: String
        let target: String
        let revisionID: UUID
    }

    private struct PendingUtterance {
        let id: UUID
        let text: String
        let source: String
        let target: String
        let mine: Bool
        let sessionID: UUID
        init(text: String, source: String, target: String, mine: Bool, sessionID: UUID, id: UUID = UUID()) {
            self.id = id
            self.text = text
            self.source = source
            self.target = target
            self.mine = mine
            self.sessionID = sessionID
        }
    }

    private struct ModeSession {
        var id = UUID()
        var lines: [TranscriptLine] = []
        var phase: ConversationPhase = .idle
        var hasEnded = false
        var samples: [CapturedAudio] = []
        var utterances: [PendingUtterance] = []
    }
    private var modeSessions: [ConversationMode: ModeSession] = [:]

    @discardableResult
    func selectMode(_ selected: ConversationMode) -> Bool {
        guard selected != mode else { return true }
        guard !isEnding else { return false }
        let oldPhase: ConversationPhase = phase == .idle ? .idle : .paused
        summary.close()
        pictureInPicture.stop()
        pause()
        modeSessions[mode] = ModeSession(id: conversationID, lines: lines, phase: oldPhase,
            hasEnded: hasEnded, samples: pausedSamples, utterances: pausedUtterances)
        // In-flight translations from the previous page must not append or play later.
        textRequestTimeout?.cancel()
        textRequestTimeout = nil
        textRequestID = nil
        textDialogueConversationID = nil
        imageRequestID = nil
        imageIsProcessing = false
        revisionID = nil
        errorMessage = nil
        isKeyboardInputFocused = false
        textOriginal = ""
        textTranslation = ""
        let restored = modeSessions[selected] ?? ModeSession()
        mode = selected
        conversationID = restored.id
        hasEnded = restored.hasEnded
        pausedSamples = restored.samples
        pausedUtterances = restored.utterances
        phase = restored.phase
        lines = restored.lines
        status = hasEnded ? "已结束" : phase == .paused ? "已暂停" : "准备就绪"
        return true
    }

    private func transition(to next: ConversationPhase) {
        assert(phase.canTransition(to: next), "Unexpected conversation transition: \(phase) → \(next)")
        guard phase != next else { return }
        phase = next
        pictureInPicture.setPaused(next == .paused || next == .idle)
    }

    init(capture: AudioCapture? = nil, store: ConversationStore? = nil,
         services: ConversationServices? = nil) {
        let audioCapture = capture ?? AudioCapture()
        let speechRecognizer = WhisperService()
        self.whisper = speechRecognizer
        self.capture = audioCapture
        self.store = store ?? ConversationStore()
        self.services = services ?? .live(whisper: speechRecognizer, capture: audioCapture)
        player.$isPlaying.assign(to: &$isSpeechPlaying)
        player.onFailure = { [weak self] message in self?.errorMessage = message }
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
                Task { @MainActor in self?.consumeUsage() }
            }
            .store(in: &observers)
        #if !EAR_YI_DEVICE_TEST
        // The personal test build has no broadcast extension or App Group entitlement.
        // 屏幕音频每 0.5 秒一块，按 0.25 秒取，文件操作由后台 actor 完成。
        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.broadcastInbox.poll() }
            }
            .store(in: &observers)
        #endif
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
        broadcastInbox.onError = { [weak self] message in
            self?.errorMessage = message
        }
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let value = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard value == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.handleAudioInterruption() }
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let deviceRemoved = reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                Task { @MainActor in
                    self?.updateOutputRoute()
                    if deviceRemoved { self?.handleHeadphonesRemoved() }
                }
            }
            .store(in: &observers)
        updateOutputRoute()
        pictureInPicture.onError = { [weak self] in self?.errorMessage = $0 }
        pictureInPicture.onPlaybackChange = { [weak self] playing in
            guard let self, !self.isEnding, !self.hasEnded else { return }
            if playing { Task { await self.start() } }
            else { self.pause() }
        }
        $liveText.combineLatest($liveTranslation).sink { [weak self] text, translation in
            guard let self else { return }
            let last = self.lines.last
            self.pictureInPicture.update(original: text.isEmpty ? last?.original ?? "" : text,
                translation: text.isEmpty ? last?.translated ?? "" : translation)
        }.store(in: &observers)
        for summary in [liveSummary, dialogueSummary] {
            summary.onUpdate = { [weak self] outline, id, snapshot in
                guard let self else { return }
                do { try self.store.updateOutline(outline, id: id, lines: snapshot) }
                catch { self.errorMessage = "总结保存失败：\(error.localizedDescription)" }
            }
        }
        $lines.sink { [weak self] lines in
            guard let self else { return }
            self.summary.receive(lines, conversationID: self.conversationID)
            self.pictureInPicture.update(original: lines.last?.original ?? "", translation: lines.last?.translated ?? "")
        }.store(in: &observers)
        watch.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case "toggle": Task {
                if self.isRunning { self.pause() }
                else { await self.start() }
            }
            case "replay": self.replay()
            default: break
            }
        }
    }

    func start() async {
        usage.refreshDay()
        guard !isEnding, !isRunning, !isPreparing, phase != .replaying else { return }
        let requestedConversation = conversationID
        let requestedMode = mode
        if !subscriptions.hasUnlimitedAccess &&
            (mode == .listen ? usage.remainingLiveSeconds == 0 : usage.remainingDialogueLines == 0) {
            await subscriptions.refresh()
            guard conversationID == requestedConversation, mode == requestedMode,
                  !isEnding, !isRunning, !isPreparing, phase != .replaying else { return }
        }
        guard subscriptions.hasUnlimitedAccess || (mode == .listen ? usage.remainingLiveSeconds > 0 : usage.remainingDialogueLines > 0) else {
            showPaywall = true
            status = "今日免费额度已用完"
            return
        }
        player.stop()
        let activeSession = UUID()
        if hasEnded {
            clearCurrent()
            conversationID = UUID()
            hasEnded = false
        }
        sessionID = activeSession
        transition(to: .preparing)
        status = "加载离线语音模型…"
        let allowed = await services.requestMicrophonePermission()
        guard sessionID == activeSession else { return }
        guard allowed else {
            sessionID = nil
            transition(to: .idle)
            errorMessage = "请在系统设置中允许麦克风访问"
            status = "未获得麦克风权限"
            return
        }
        do {
            try await services.prepare(language: recognitionLanguage)
            guard sessionID == activeSession else { return }
            capture.nearField = preferences.nearField
            capture.quality = preferences.processingMode == .quality
            capture.liveSegmentation = mode == .listen
            configureCaptureCallbacks()
            dialogueInputStopped = false
            try services.startCapture()
            transition(to: .listening)
            status = "正在识别\(AppLanguage.name(recognitionLanguage ?? preferences.sourceLanguage))…"
            pending.append(contentsOf: pausedSamples)
            pausedSamples = []
            if !pending.isEmpty || !pausedUtterances.isEmpty { Task { await drain() } }
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
        guard !isEnding else { return }
        dialogueInputStopped = false
        if let item = activeLiveTranslation { pausedUtterances.append(item) }
        pausedUtterances.append(contentsOf: liveTranslations)
        liveTranslations = []
        activeLiveTranslation = nil
        liveTranslationWorkerID = nil
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        services.resetRecognition()
        recognitionWindow = nil
        if let item = waitingUtterance ?? restoringUtterance {
            pausedUtterances.append(item)
        } else if let activeSamples { pausedSamples.append(activeSamples.audio) }
        languagePackResumeID = nil
        textRequestTimeout?.cancel()
        textRequestTimeout = nil
        textRequestID = nil
        imageRequestID = nil
        revisionID = nil
        imageIsProcessing = false
        restoringUtterance = nil
        activeSamples = nil
        pausedSamples.append(contentsOf: pending)
        if let tail = capture.takePendingSpeech() { pausedSamples.append(capturedAudio(tail)) }
        usage.track(active: !subscriptions.hasUnlimitedAccess && mode == .listen && capture.isRecording)
        sessionID = nil
        playbackID = nil
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
        clearLivePreview()
        transition(to: .paused)
        if !pictureInPicture.enabled {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        status = "已暂停"
        updateOutputRoute()
        watch.publish(running: false, latest: lines.last?.translated ?? "")
    }

    /// AirPods 摘下或断开后，同传译文会改从手机播出并被麦克风录回去，
    /// 按系统音频 App 的惯例暂停，由用户确认后再继续。
    private func handleHeadphonesRemoved() {
        guard mode == .listen, destination == .earphones, !isBroadcastMode, !isEnding,
              isRunning, !SpeechPlayer.headphonesConnected else { return }
        pause()
        status = "耳机已断开，同传已暂停"
    }

    private func handleAudioInterruption() {
        guard isRunning || isPreparing || phase == .replaying else { return }
        pause()
        status = "录音被系统打断，请点开始继续"
    }

    func end(save: Bool = false) {
        guard !isEnding else { return }
        pictureInPicture.stop()
        if sessionID == nil, !pausedSamples.isEmpty || !pausedUtterances.isEmpty {
            sessionID = UUID()
            transition(to: .preparing)
            transition(to: .listening)
        }
        pending.append(contentsOf: pausedSamples)
        pausedSamples = []
        isEnding = true
        saveWhenEnded = save || preferences.saveAutomatically
        usage.track(active: !subscriptions.hasUnlimitedAccess && mode == .listen && capture.isRecording)
        if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
        capture.stop()
        latestPartial = nil
        player.stop()
        status = "正在完成最后一句…"
        if draining { return }
        if !pending.isEmpty || !pausedUtterances.isEmpty {
            Task { await drain() }
        } else {
            finishEndingIfReady()
        }
    }

    private func finishEndingIfReady() {
        guard isEnding, !draining, pending.isEmpty, pausedUtterances.isEmpty,
              liveTranslations.isEmpty, activeLiveTranslation == nil, liveTranslationWorkerID == nil,
              waitingUtterance == nil, waitingText == nil, languagePackResumeID == nil,
              revisionID == nil, waitingRevision == nil else { return }
        let shouldSave = saveWhenEnded
        isEnding = false
        pause()
        pausedSamples = []
        hasEnded = true
        status = "已结束"
        guard shouldSave else { return }
        let snapshot = lines
        let recordID = conversationID
        let savedOutline = summary.outline(for: recordID, lines: snapshot)
        guard !snapshot.isEmpty else {
            return
        }
        status = "正在保存到历史…"
        Task {
            do {
                try await store.save(snapshot, id: recordID, outline: savedOutline)
                if conversationID == recordID, hasEnded, sessionID == nil { status = "已保存到历史" }
            } catch {
                errorMessage = "保存对话失败：\(error.localizedDescription)"
            }
        }
    }

    func saveCurrent() async {
        let snapshot = lines
        let recordID = conversationID
        guard !snapshot.isEmpty else { status = "没有可保存的对话"; return }
        status = "正在保存到历史…"
        do {
            try await store.save(snapshot, id: recordID, outline: summary.outline(for: recordID, lines: snapshot))
            if conversationID == recordID { status = "对话已保存" }
        } catch {
            guard conversationID == recordID else { return }
            status = "保存失败"
            errorMessage = error.localizedDescription
        }
    }
    func clearCurrent() {
        guard !isEnding else { return }
        pause()
        pausedSamples = []
        pausedUtterances = []
        conversationID = UUID()
        hasEnded = false
        revisionID = nil
        waitingRevision = nil
        textRequestTimeout?.cancel()
        textRequestTimeout = nil
        textRequestID = nil
        textDialogueConversationID = nil
        textOriginal = ""
        textTranslation = ""
        lines = []
        clearLivePreview()
        status = "已清空"
    }

    func replay(_ selectedLine: TranscriptLine? = nil, output: AudioDestination? = nil) {
        guard !isEnding else { return }
        guard let line = selectedLine ?? lines.last else { return }
        guard !line.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = line.translationIssue ?? "这句话还没有译文"
            return
        }
        guard !draining, pending.isEmpty, waitingUtterance == nil,
              liveTranslationWorkerID == nil, liveTranslations.isEmpty,
              phase == .listening || phase == .paused || phase == .idle else {
            status = "当前语音处理完后再重播"
            return
        }
        let previousPhase = phase
        let token = UUID()
        playbackID = token
        transition(to: .replaying)
        let activeSession = sessionID
        if isRunning {
            if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
            capture.stop()
            latestPartial = nil
            clearLivePreview()
        }
        let output: AudioDestination = output ?? (line.isMine ? .speaker : destination)
        let played = player.speak(line.translated, language: line.targetLanguage,
                                  rate: preferences.speechRate, destination: output) { [weak self] in
            guard let self else { return }
            guard self.sessionID == activeSession, self.playbackID == token else { return }
            self.playbackID = nil
            self.transition(to: previousPhase)
            if self.pending.isEmpty { self.resumeCapture() }
            else { Task { await self.drain() } }
        }
        if !played { errorMessage = "当前设备没有\(AppLanguage.name(line.targetLanguage))语音" }
        updateOutputRoute()
    }

    func toggleReadAloud() {
        preferences.autoReadAloud.toggle()
        if !preferences.autoReadAloud { player.stop() }
    }

    func overrideLanguage(_ code: String?) {
        correctionLanguage = code
    }

    func beginDialogue(in language: String) async {
        guard !isEnding else { return }
        if isRunning { pause() }
        guard selectMode(.dialogue) else { return }
        forcedLanguage = language
        await start()
    }

    /// Finish the current spoken turn without waiting for a silence timeout or
    /// ending the conversation. Recognition/translation/playback finish in order.
    func finishDialogueTurn() {
        guard mode == .dialogue, isRunning, !isEnding else { return }
        dialogueInputStopped = true
        if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
        capture.stop()
        latestPartial = nil
        clearLivePreview()
        guard !draining else { return }
        if pending.isEmpty && pausedUtterances.isEmpty && waitingUtterance == nil {
            pause()
        } else {
            Task { await self.drain() }
        }
    }

    private func configureCaptureCallbacks() {
        capture.onPartial = { [weak self] samples in
            guard let self else { return }
            self.latestPartial = (samples, self.capture.windowID)
            Task { await self.drain() }
        }
        capture.onUtterance = { [weak self] samples in
            guard let self else { return }
            self.pending.append(self.capturedAudio(samples))
            self.latestPartial = nil
            Task { await self.drain() }
        }
    }

    private func startBroadcast() async {
        guard mode == .listen, !isEnding, !isRunning, !isPreparing, phase != .replaying else { return }
        guard BroadcastStorage.directory != nil else {
            errorMessage = "屏幕广播需要启用 App Group，请检查安装配置"
            return
        }
        usage.refreshDay()
        guard subscriptions.hasUnlimitedAccess || usage.remainingLiveSeconds > 0 else {
            showPaywall = true
            return
        }
        if hasEnded { clearCurrent() }
        let token = UUID()
        sessionID = token
        transition(to: .preparing)
        status = "准备屏幕音频识别…"
        do {
            try await services.prepare(language: recognitionLanguage)
            guard sessionID == token else { return }
            guard broadcastInbox.active else {
                sessionID = nil
                transition(to: .idle)
                status = "屏幕广播已结束"
                return
            }
            configureCaptureCallbacks()
            capture.liveSegmentation = true
            capture.startExternal()
            isBroadcastMode = true
            transition(to: .listening)
            pending.append(contentsOf: pausedSamples)
            pausedSamples = []
            if !pending.isEmpty || !pausedUtterances.isEmpty { Task { await drain() } }
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
        usage.track(active: !subscriptions.hasUnlimitedAccess && mode == .listen && capture.isRecording)
        guard !subscriptions.hasUnlimitedAccess, isRunning, mode == .listen,
              usage.remainingLiveSeconds == 0 else { return }
        end()
        status = "今日免费同传时长已用完"
        showPaywall = true
    }

    private func checkDialogueQuota() -> Bool {
        guard mode == .dialogue, !subscriptions.hasUnlimitedAccess else { return true }
        usage.recordDialogueLine()
        guard usage.remainingDialogueLines == 0 else { return true }
        end()
        status = "今日免费对话句数已用完"
        showPaywall = true
        return false
    }

    private func drain() async {
        guard !draining, languagePackResumeID == nil else { return }
        draining = true
        let drainSession = sessionID
        defer {
            draining = false
            if mode == .listen, sessionID == drainSession, !isEnding,
               phase == .recognizing, activeSamples == nil, pending.isEmpty,
               pausedUtterances.isEmpty, latestPartial == nil {
                transition(to: .listening)
            }
            finishEndingIfReady()
            if dialogueInputStopped, mode == .dialogue, !isEnding, sessionID == drainSession,
               pending.isEmpty, pausedUtterances.isEmpty, waitingUtterance == nil,
               languagePackResumeID == nil {
                pause()
            }
            if !isEnding, phase == .listening, !capture.isRecording { resumeCapture() }
        }
        while !pending.isEmpty || !pausedUtterances.isEmpty || latestPartial != nil {
            guard waitingUtterance == nil, languagePackResumeID == nil else { return }
            guard let session = sessionID, session == drainSession else {
                if sessionID != nil { Task { await self.drain() } }
                return
            }
            if isEnding, phase != .listening { transition(to: .listening) }
            if !pausedUtterances.isEmpty {
                let item = pausedUtterances.removeFirst()
                let restored = PendingUtterance(text: item.text, source: item.source,
                    target: item.target, mine: item.mine, sessionID: session, id: item.id)
                restoringUtterance = restored
                transition(to: .recognizing)
                if mode == .listen { enqueueLiveTranslation(restored) }
                else { await translateAndPlay(restored) }
                if restoringUtterance?.sessionID == session { restoringUtterance = nil }
            } else if !pending.isEmpty {
                let samples = pending.removeFirst()
                await process(samples)
            } else if let partial = latestPartial {
                latestPartial = nil
                await processPartial(partial.samples, window: partial.window)
            }
        }
    }

    private func processPartial(_ samples: [Float], window: UUID) async {
        guard let activeSession = sessionID, capture.windowID == window else { return }
        if recognitionWindow != window {
            services.resetRecognitionWindow()
            recognitionWindow = window
        }
        let selectedLanguage = recognitionLanguage
        transition(to: .recognizing)
        defer {
            if sessionID == activeSession && phase == .recognizing && pending.isEmpty {
                transition(to: .listening)
            }
        }
        do {
            let recognized = try await services.recognizePartial(samples, language: selectedLanguage)
            if sessionID == activeSession && pending.isEmpty && waitingUtterance == nil &&
                capture.windowID == window && selectedLanguage == recognitionLanguage {
                let source = selectedLanguage ?? AppLanguage.normalizedCode(recognized.language)
                if mode == .listen, let prefix = recognized.confirmedPrefix,
                   let prefixText = RecognizedSpeechText.cleaned(prefix.text), prefix.sampleCount <= samples.count,
                   AppLanguage.all.contains(where: { $0.code == source }),
                   let cut = capture.sentenceBoundary(near: prefix.sampleCount, window: window),
                   capture.commitPrefix(cut, window: window) {
                    services.commitRecognition?(.init(text: prefix.text, sampleCount: cut), source)
                    recognitionWindow = nil
                    latestPartial = nil
                    clearLivePreview()
                    if let item = makeUtterance(prefixText, source: source, session: activeSession) {
                        pausedUtterances.append(item)
                    }
                    return
                }
                let text = RecognizedSpeechText.cleaned(recognized.text) ?? ""
                if liveText != text { liveText = text }
                updateLiveTranslation(source: source, session: activeSession)
            }
        } catch { }
    }

    private func clearLivePreview() {
        previewRequestID = nil
        previewTask?.cancel()
        previewTask = nil
        latestPreview = nil
        completedPreview = nil
        previewStabilizer.reset()
        liveText = ""
        liveTranslation = ""
    }

    private func updateLiveTranslation(source: String, session: UUID) {
        // Stable sentences have priority over speculative preview work. Recognition
        // and source subtitles remain live while the final translation queue drains.
        guard liveTranslationWorkerID == nil else {
            previewRequestID = nil
            previewTask?.cancel()
            previewTask = nil
            latestPreview = nil
            completedPreview = nil
            liveTranslation = ""
            return
        }
        let text = previewStabilizer.update(liveText, language: source)
        let target = mode == .dialogue && source == preferences.preferredLanguage
            ? lastOtherLanguage : preferences.preferredLanguage
        guard !text.isEmpty, source != target,
              AppLanguage.all.contains(where: { $0.code == source }) else {
            previewRequestID = nil
            previewTask?.cancel()
            previewTask = nil
            latestPreview = nil
            completedPreview = nil
            liveTranslation = ""
            return
        }
        let input = PreviewInput(text: text, source: source, target: target, session: session)
        latestPreview = input
        if let completedPreview, !input.extends(completedPreview) { liveTranslation = "" }
        startNextPreview()
    }

    private func startNextPreview() {
        guard previewTask == nil, let input = latestPreview, input != completedPreview else { return }
        let token = UUID()
        previewRequestID = token
        previewTask = Task { [weak self] in
            guard let self else { return }
            let translated: String?
            do {
                // 增量预览优先及时显示；完整句子仍使用用户选择的质量策略。
                translated = try await AsyncDeadline<String>.run(timeout: .seconds(3)) { [services = self.services] in
                    try await services.translate(input.text, from: input.source, to: input.target, mode: .fast)
                }
            } catch {
                // 预览不触发下载、不播报、不保存；完整句子再按正常流程处理。
                translated = nil
            }
            guard !Task.isCancelled, self.previewRequestID == token,
                  self.sessionID == input.session else { return }
            self.previewTask = nil
            self.previewRequestID = nil
            if self.latestPreview?.extends(input) == true, let translated {
                self.completedPreview = input
                self.liveTranslation = translated
            }
            // 慢翻译完成后直接处理最新稳定前缀，跳过中间已过时的预览。
            if self.latestPreview != input { self.startNextPreview() }
        }
    }

    private func process(_ audio: CapturedAudio) async {
        guard let activeSession = sessionID else { return }
        activeSamples = (audio, activeSession)
        defer {
            if activeSamples?.session == activeSession { activeSamples = nil }
            if sessionID == activeSession {
                services.resetRecognitionWindow()
                recognitionWindow = nil
            }
        }
        transition(to: .recognizing)
        let selectedLanguage = audio.language
        do {
            let recognized = try await services.recognize(audio.samples, language: selectedLanguage)
            guard sessionID == activeSession else { return }
            guard let recognizedText = RecognizedSpeechText.cleaned(recognized.text) else {
                clearLivePreview()
                transition(to: .listening)
                return
            }
            let source = selectedLanguage ?? AppLanguage.normalizedCode(recognized.language)
            if let item = makeUtterance(recognizedText, source: source, session: activeSession) {
                if mode == .listen {
                    let preview: String
                    if let completedPreview, completedPreview.session == activeSession,
                       completedPreview.source == source, completedPreview.target == item.target,
                       recognizedText.hasPrefix(completedPreview.text) {
                        preview = liveTranslation
                    } else { preview = "" }
                    enqueueLiveTranslation(item, preview: preview)
                    clearLivePreview()
                    transition(to: .listening)
                } else { clearLivePreview(); await translateAndPlay(item) }
            } else { clearLivePreview(); transition(to: .listening) }
        } catch {
            guard sessionID == activeSession else { return }
            status = "没听清，继续倾听…"
            transition(to: .listening)
        }
    }

    private func makeUtterance(_ recognizedText: String, source: String, session: UUID) -> PendingUtterance? {
        correctionLanguage = nil
        guard AppLanguage.all.contains(where: { $0.code == source }) else {
            status = "暂不支持识别到的语言：\(source)"
            return nil
        }
        detectedLanguage = source
        let mine = source == preferences.preferredLanguage && mode == .dialogue
        if mine == false && source != preferences.preferredLanguage { lastOtherLanguage = source }
        if lastOtherLanguage == preferences.preferredLanguage {
            lastOtherLanguage = preferences.preferredLanguage == "en" ? "zh" : "en"
        }
        let target = mine ? lastOtherLanguage : preferences.preferredLanguage
        guard source != target else { return nil }
        return PendingUtterance(text: recognizedText, source: source,
                                target: target, mine: mine, sessionID: session)
    }

    private func translateLive(_ item: PendingUtterance, preparedSession: TranslationSession?) async throws -> String {
        for attempt in 0..<3 {
            guard sessionID == item.sessionID else { throw CancellationError() }
            do {
                let mode = preferences.processingMode
                let text = try await AsyncDeadline<String>.run(timeout: .seconds(20)) { [services] in
                    try await services.translate(item.text, from: item.source, to: item.target,
                                                 mode: mode, preparedSession: preparedSession)
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw URLError(.cannotDecodeContentData)
                }
                return text
            } catch {
                if error is CancellationError || (error as? TranslatorError) != nil || attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 250))
            }
        }
        throw URLError(.unknown)
    }

    private func enqueueLiveTranslation(_ item: PendingUtterance, preview: String = "") {
        if !lines.contains(where: { $0.id == item.id }) {
            var line = TranscriptLine(id: item.id, sourceLanguage: item.source, targetLanguage: item.target,
                                      original: item.text, translated: preview, isMine: item.mine)
            line.translationPending = true
            lines.append(line)
        }
        liveTranslations.append(item)
        guard liveTranslationWorkerID == nil else { return }
        let workerID = UUID()
        liveTranslationWorkerID = workerID
        liveTranslationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.liveTranslationWorkerID == workerID {
                    self.activeLiveTranslation = nil
                    self.liveTranslationWorkerID = nil
                    self.liveTranslationTask = nil
                    self.finishEndingIfReady()
                }
            }
            while self.liveTranslationWorkerID == workerID, !Task.isCancelled,
                  self.sessionID == item.sessionID, !self.liveTranslations.isEmpty {
                let next = self.liveTranslations.removeFirst()
                self.activeLiveTranslation = next
                // A missing pack preserves the original as a retryable line rather
                // than stopping capture and blocking every subsequent utterance.
                await self.translateAndPlay(next, allowDownload: false, backgroundLive: true)
                guard self.liveTranslationWorkerID == workerID else { return }
                self.activeLiveTranslation = nil
            }
        }
    }

    private func translateAndPlay(_ item: PendingUtterance, allowDownload: Bool = true, backgroundLive: Bool = false,
                                  preparedSession: TranslationSession? = nil) async {
        guard sessionID == item.sessionID else { return }
        do {
            if !backgroundLive { transition(to: .translating) }
            status = "正在翻译 \(AppLanguage.name(item.source))…"
            // 正式译文优先于预览，避免旧预览和整句翻译争抢同一语言模型。
            if !backgroundLive { clearLivePreview() }
            let translated = try await translateLive(item, preparedSession: preparedSession)
            guard sessionID == item.sessionID else { return }
            let line = TranscriptLine(id: item.id, sourceLanguage: item.source, targetLanguage: item.target,
                                      original: item.text, translated: translated, isMine: item.mine)
            if let index = lines.firstIndex(where: { $0.id == item.id }) {
                var completed = line
                completed.time = lines[index].time
                lines[index] = completed
            }
            else { lines.append(line) }
            if !backgroundLive {
                activeSamples = nil
                if restoringUtterance?.sessionID == item.sessionID { restoringUtterance = nil }
            }
            watch.publish(running: isRunning, latest: translated)
            status = "检测到\(AppLanguage.name(item.source))"
            if !preferences.autoReadAloud || isEnding {
                if !isEnding { guard checkDialogueQuota() else { return } }
                if !backgroundLive { resumeCapture() }
                return
            }
            let output: AudioDestination = item.mine ? .speaker : destination
            // Live interpretation owns a continuous input stream. Playback is a consumer,
            // never a reason to stop that stream; microphone echo processing is configured
            // when capture starts. Dialogue retains its explicit turn-taking behavior.
            let keepListening = mode == .listen && capture.isRecording
            if keepListening {
                // 同传按顺序播报，识别继续处理下一句，不等待整段朗读结束。
                let queued = services.enqueueSpeech?(translated, item.target, preferences.speechRate) ??
                    player.enqueue(translated, language: item.target, rate: preferences.speechRate, destination: output)
                if !queued { errorMessage = "当前设备没有\(AppLanguage.name(item.target))语音，译文已显示" }
                if !backgroundLive { transition(to: .listening) }
                updateOutputRoute()
                return
            }
            if !keepListening {
                if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
                capture.stop()
                latestPartial = nil
            }
            transition(to: .speaking)
            clearLivePreview()
            await withCheckedContinuation { continuation in
                let played = player.speak(translated, language: item.target,
                                          rate: preferences.speechRate,
                                          destination: output,
                                          keepInputActive: keepListening) {
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
                if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
                capture.stop()
                latestPartial = nil
                waitingUtterance = item
                transition(to: .waitingForLanguagePack)
                requestLanguagePack(from: source, to: target)
                return
            }
            var untranslated = TranscriptLine(id: item.id, sourceLanguage: item.source, targetLanguage: item.target,
                original: item.text, translated: "", isMine: item.mine)
            untranslated.translationIssue = "翻译未完成，原文已保留"
            if let index = lines.firstIndex(where: { $0.id == item.id }) {
                untranslated.time = lines[index].time
                if !lines[index].translated.isEmpty {
                    untranslated.translated = lines[index].translated
                    untranslated.translationIssue = "正式翻译未完成，暂存译文待确认"
                }
                lines[index] = untranslated
            }
            else { lines.append(untranslated) }
            if !backgroundLive {
                activeSamples = nil
                if restoringUtterance?.sessionID == item.sessionID { restoringUtterance = nil }
            }
            status = "翻译未完成，原文已保留"
            if !backgroundLive { resumeCapture() }
        }
    }

    private func resumeCapture() {
        guard !isEnding, isRunning, sessionID != nil,
              phase != .replaying else { return }
        if mode == .dialogue, dialogueInputStopped {
            transition(to: .listening)
            return
        }
        // 同传的播报队列不拥有录音生命周期；对话模式保留轮流说话的等待。
        if mode != .listen, !capture.isRecording, services.playbackIsActive?() ?? player.isPlaying { return }
        do {
            if !capture.isRecording {
                if isBroadcastMode { capture.startExternal() }
                else { try services.startCapture() }
            }
            transition(to: .listening)
            status = isBroadcastMode ? "正在识别屏幕音频…" : "正在识别\(AppLanguage.name(recognitionLanguage ?? preferences.sourceLanguage))…"
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
        status = "正在准备\(AppLanguage.name(source)) → \(AppLanguage.name(target))翻译"
        let configuration = TranslationConfigurationFactory.make(
            source: source, target: target, mode: preferences.processingMode
        )
        languagePackRequest = LanguagePackRequest(configuration: configuration)
    }

    func languagePackReady(for requestID: UUID, session: TranslationSession) async {
        guard languagePackRequest?.id == requestID else { return }
        let utterance = waitingUtterance
        let image = waitingImage
        let text = waitingText
        let revision = waitingRevision
        let resumeID = UUID()
        languagePackResumeID = resumeID
        restoringUtterance = utterance
        waitingUtterance = nil
        waitingImage = nil
        waitingText = nil
        waitingRevision = nil
        if let utterance { await translateAndPlay(utterance, allowDownload: false, preparedSession: session) }
        guard languagePackResumeID == resumeID else { return }
        restoringUtterance = nil
        if let image {
            await translateImageText(image.text, from: image.source, to: image.target,
                                     requestID: image.requestID, allowDownload: false, preparedSession: session)
        }
        if let text {
            await translateTextContent(text.text, from: text.source, to: text.target,
                                       requestID: text.requestID, allowDownload: false, preparedSession: session)
        }
        if let revision { await applyRevision(revision, allowDownload: false, preparedSession: session) }
        guard languagePackResumeID == resumeID else { return }
        languagePackRequest = nil
        languagePackResumeID = nil
        await drain()
        finishEndingIfReady()
    }

    func languagePackFailed(_ error: Error, for requestID: UUID) {
        guard languagePackRequest?.id == requestID else { return }
        let failedUtterance = waitingUtterance
        let resumeUtterance = waitingUtterance != nil
        let cancelled = error is CancellationError || (TranslationError.alreadyCancelled ~= error) ||
            (error as NSError).domain == NSCocoaErrorDomain &&
            (error as NSError).code == CocoaError.Code.userCancelled.rawValue ||
            (error as NSError).domain == NSURLErrorDomain &&
            (error as NSError).code == NSURLErrorCancelled
        textRequestTimeout?.cancel()
        textRequestTimeout = nil
        textRequestID = nil
        imageRequestID = nil
        imageIsProcessing = false
        revisionID = nil
        languagePackRequest = nil
        waitingUtterance = nil
        waitingImage = nil
        waitingText = nil
        waitingRevision = nil
        languagePackResumeID = nil
        restoringUtterance = nil
        if let item = failedUtterance, sessionID == item.sessionID,
           !lines.contains(where: { $0.id == item.id }) {
            var line = TranscriptLine(id: item.id, sourceLanguage: item.source, targetLanguage: item.target,
                                      original: item.text, translated: "", isMine: item.mine)
            line.translationIssue = cancelled ? "已取消翻译准备，原文已保留" : "翻译准备未完成，原文已保留"
            lines.append(line)
        }
        if cancelled {
            // 取消下载是正常操作；暂停收音，避免下一句再次弹出同一个下载提示。
            if resumeUtterance && !isEnding { pause() }
            errorMessage = nil
            status = "已取消语言包准备"
            finishEndingIfReady()
            return
        }
        errorMessage = "翻译准备失败，请检查语言包后重试。输入文字已保留。"
        status = "语言包下载未完成"
        if resumeUtterance { resumeCapture() }
        if !pending.isEmpty { Task { await drain() } }
        finishEndingIfReady()
    }

    func reviseLastLine(_ lineID: UUID, text: String, source: String, target: String) async {
        guard !isEnding, lines.last?.translationPending != true else { return }
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

    private func applyRevision(_ revision: PendingRevision, allowDownload: Bool = true,
                               preparedSession: TranslationSession? = nil) async {
        guard revisionID == revision.revisionID, lines.last?.id == revision.lineID else { return }
        defer {
            if revisionID == revision.revisionID, waitingRevision?.revisionID != revision.revisionID {
                revisionID = nil
            }
            finishEndingIfReady()
        }
        do {
            status = "正在重新翻译上一句…"
            let processingMode = preferences.processingMode
            let result = try await AsyncDeadline<String>.run(timeout: .seconds(20)) { [services] in
                try await services.translate(revision.text, from: revision.source,
                                             to: revision.target, mode: processingMode, preparedSession: preparedSession)
            }
            guard revisionID == revision.revisionID, lines.last?.id == revision.lineID else { return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
            guard let index = lines.indices.last else { return }
            lines[index].original = revision.text
            lines[index].sourceLanguage = revision.source
            lines[index].targetLanguage = revision.target
            lines[index].translated = result
            lines[index].translationIssue = nil
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

    func sendDialogueText(_ text: String, requestID: UUID = UUID()) async {
        guard selectMode(.dialogue) else { return }
        await translateText(text, from: preferences.sourceLanguage, to: preferences.preferredLanguage,
                            inDialogue: true, requestID: requestID)
    }

    func translateText(_ text: String, from selectedSource: String, to target: String,
                       inDialogue: Bool = false, requestID: UUID = UUID()) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入要翻译的文字"; return }
        guard languagePackRequest == nil else { errorMessage = "请先完成当前语言包下载"; return }
        guard !isEnding else { return }
        errorMessage = nil
        if inDialogue {
            usage.refreshDay()
            guard subscriptions.hasUnlimitedAccess || usage.remainingDialogueLines > 0 else {
                showPaywall = true
                return
            }
            if hasEnded {
                clearCurrent()
                conversationID = UUID()
                hasEnded = false
            }
        }
        textRequestID = requestID
        textRequestIsDialogue = inDialogue
        textDialogueConversationID = inDialogue ? conversationID : nil
        textOriginal = trimmed
        textTranslation = ""
        textTargetLanguage = target
        let source: String
        if selectedSource == "auto" {
            let detector = NLLanguageRecognizer()
            if inDialogue {
                detector.languageConstraints = [preferences.preferredLanguage, lastOtherLanguage]
                    .map { NLLanguage(rawValue: $0 == "zh" ? "zh-Hans" : $0) }
            }
            detector.processString(trimmed)
            let detected = AppLanguage.normalizedCode(detector.dominantLanguage?.rawValue ?? "")
            source = AppLanguage.all.contains(where: { $0.code == detected })
                ? detected : fallbackTextLanguage(for: trimmed, target: target)
        } else {
            source = selectedSource
        }
        guard AppLanguage.all.contains(where: { $0.code == source }) else {
            textRequestID = nil
            errorMessage = "无法确定原文语言，请手动选择"
            return
        }
        textDetectedLanguage = source
        let resolvedTarget = inDialogue && source == preferences.preferredLanguage
            ? lastOtherLanguage : target
        textTargetLanguage = resolvedTarget
        waitingText = (trimmed, source, resolvedTarget, requestID)
        textRequestTimeout?.cancel()
        textRequestTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) }
            catch { return }
            self?.expireTextRequest(requestID)
        }
        // LocalTranslator 先检查系统中当前语言对是否已安装；只有明确缺少时才准备下载。
        await translateTextContent(trimmed, from: source, to: resolvedTarget, requestID: requestID)
    }

    func expireTextRequest(_ preparationID: UUID) {
        guard let currentID = textRequestID,
              currentID == preparationID || languagePackRequest?.id == preparationID else { return }
        textRequestID = nil
        textRequestTimeout?.cancel()
        textRequestTimeout = nil
        languagePackRequest = nil
        waitingText = nil
        languagePackResumeID = nil
        errorMessage = "翻译等待超时，文字已保留，请重新发送。"
        finishEndingIfReady()
    }

    private func translateTextContent(_ text: String, from source: String, to target: String,
                                      requestID: UUID, allowDownload: Bool = true,
                                      preparedSession: TranslationSession? = nil) async {
        guard textRequestID == requestID else { return }
        defer { finishEndingIfReady() }
        do {
            let result = try await services.translate(text, from: source, to: target,
                                                        mode: preferences.processingMode, preparedSession: preparedSession)
            guard textRequestID == requestID else { return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
            textRequestTimeout?.cancel()
            textRequestTimeout = nil
            if waitingText?.requestID == requestID { waitingText = nil }
            textRequestID = nil
            textTranslation = result
            if textRequestIsDialogue {
                guard textDialogueConversationID == conversationID, !hasEnded else { return }
                let line = TranscriptLine(sourceLanguage: source, targetLanguage: target,
                                          original: text, translated: result,
                                          isMine: source == preferences.preferredLanguage)
                lines.append(line)
                deliveredDialogueText = text
                if dialogueKeyboardDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    dialogueKeyboardDraft = ""
                }
                deliveredDialogueTextID = requestID
                watch.publish(running: isRunning, latest: result)
                if !subscriptions.hasUnlimitedAccess { usage.recordDialogueLine() }
            }
            guard preferences.autoReadAloud else { return }
            guard !isEnding else { return }
            let shouldResumeCapture = isRunning
            let activeSession = sessionID
            if shouldResumeCapture {
                if let tail = capture.takePendingSpeech() { pending.append(capturedAudio(tail)) }
                capture.stop()
                latestPartial = nil
                clearLivePreview()
            }
            // .earphones 使用 playback 会话，跟随系统输出；未连接耳机时由手机播放。
            let played = player.speak(result, language: target, rate: preferences.speechRate,
                                      destination: .earphones) { [weak self] in
                guard let self, shouldResumeCapture, self.sessionID == activeSession,
                      !self.draining else { return }
                if self.pending.isEmpty { self.resumeCapture() }
                else { Task { await self.drain() } }
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
            textRequestTimeout?.cancel()
            textRequestTimeout = nil
            if waitingText?.requestID == requestID { waitingText = nil }
            textRequestID = nil
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
                                    allowDownload: Bool = true, preparedSession: TranslationSession? = nil) async {
        guard imageRequestID == requestID else { return }
        do {
            let translation = try await services.translate(text, from: source, to: target,
                                                              mode: preferences.processingMode,
                                                              preparedSession: preparedSession)
            guard imageRequestID == requestID else { return }
            guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
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
