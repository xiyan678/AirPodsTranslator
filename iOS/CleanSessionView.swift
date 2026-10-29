import SwiftUI

struct CleanSessionView: View {
    @EnvironmentObject private var controller: ConversationController
    @ObservedObject var preferences: Preferences
    let mode: ConversationMode
    @State private var showText = false
    @State private var showPhoto = false
    @State private var showSummary = false
    @State private var editingLine: TranscriptLine?
    private var keyboardMode: Bool { mode == .dialogue && controller.dialogueKeyboardEnabled }
    private var draft: String { controller.dialogueKeyboardDraft }
    private var sending: Bool { controller.isTranslatingText }
    @FocusState private var inputFocused: Bool

    private var active: Bool { controller.mode == mode && controller.isRunning }
    private var paused: Bool {
        controller.mode == mode && controller.phase == .paused && !controller.hasEnded
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.95, green: 0.95, blue: 0.97).ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if controller.lines.isEmpty && controller.liveText.isEmpty {
                        Spacer(minLength: keyboardMode ? 0 : 25)
                        emptyState
                        Spacer(minLength: keyboardMode ? 0 : 25)
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView {
                                LazyVStack(spacing: 13) {
                                    ForEach(Array(controller.lines.enumerated()), id: \.element.id) { index, line in
                                        if mode == .listen {
                                            LiveTranscriptCard(original: line.original, translated: line.translated.isEmpty
                                                ? line.translationIssue ?? "" : line.translated,
                                                               index: index + 1, completed: true,
                                                               size: preferences.fontSize)
                                                .contextMenu {
                                                    if controller.lines.last?.id == line.id {
                                                        Button("修改并重译") { editingLine = line }
                                                    }
                                                    ShareLink(item: line.original + "\n" + line.translated) { Text("分享") }
                                                }
                                                .id(line.id)
                                        } else if keyboardMode {
                                            DialogueTextBubble(line: line) { controller.replay(line, output: .earphones) }
                                                .id(line.id)
                                        } else {
                                            TranscriptCard(line: line, size: preferences.fontSize,
                                                       onEdit: controller.lines.last?.id == line.id ? {
                                                           editingLine = line
                                                       } : nil)
                                                .id(line.id)
                                        }
                                    }
                                    if !controller.liveText.isEmpty {
                                        LiveTranscriptCard(original: controller.liveText,
                                                           translated: controller.liveTranslation,
                                                           index: controller.lines.count + 1, completed: false,
                                                           size: preferences.fontSize)
                                            .id("live")
                                    }
                                }
                                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 25)
                            }
                            .onChange(of: controller.lines.count) { _, _ in
                                if let last = controller.lines.last { scroll.scrollTo(last.id, anchor: .bottom) }
                            }
                            .onChange(of: controller.liveText) { _, value in
                                if !value.isEmpty { scroll.scrollTo("live", anchor: .bottom) }
                            }
                        }
                    }
                    if mode == .listen {
                        if !active && !paused { liveControls }
                    } else {
                        if keyboardMode { keyboardControls }
                        else { dialogueControls }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showText) { TextTranslationView(preferences: preferences) }
            .sheet(isPresented: $showPhoto) { CameraTranslateView() }
            .sheet(isPresented: $showSummary) { LiveSummaryView(summary: controller.summary) }
            .sheet(item: $editingLine) { line in ReviseLineView(line: line) }
            .onChange(of: inputFocused) { _, focused in controller.isKeyboardInputFocused = focused }
            .onDisappear { controller.isKeyboardInputFocused = false }
            .task(id: keyboardMode) {
                if keyboardMode {
                    await Task.yield()
                    guard !Task.isCancelled, keyboardMode else { return }
                    inputFocused = true
                }
            }
            .onAppear {
                if mode == .dialogue {
                    controller.dialogueKeyboardEnabled = false
                    inputFocused = false
                    controller.isKeyboardInputFocused = false
                }
                if controller.mode != mode {
                    controller.selectMode(mode)
                }
                if controller.lastOtherLanguage == preferences.preferredLanguage {
                    controller.lastOtherLanguage = preferences.preferredLanguage == "en" ? "zh" : "en"
                }
            }
            .onChange(of: preferences.preferredLanguage) { _, newValue in
                if mode == .dialogue && controller.isRunning && controller.mode == .dialogue {
                    controller.pause()
                }
                if controller.lastOtherLanguage == newValue {
                    controller.lastOtherLanguage = newValue == "en" ? "zh" : "en"
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            if mode == .listen {
                if active || paused {
                    Button { controller.pictureInPicture.start() } label: {
                        Image(systemName: "pip.enter").font(.title3)
                    }.accessibilityLabel("开启字幕画中画")
                }
                Spacer()
                if active || paused {
                    liveSessionControls
                } else {
                    Menu {
                        Button("开启画中画", systemImage: "pip.enter") {
                            Task {
                                if !controller.isRunning { await controller.start() }
                                if controller.isRunning { controller.pictureInPicture.start() }
                            }
                        }
                        if !controller.lines.isEmpty {
                            Button("AI 总结", systemImage: "sparkles") { showSummary = true }
                        }
                        Button("文本翻译", systemImage: "text.bubble") { showText = true }
                        Button("图片翻译", systemImage: "photo") { showPhoto = true }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                            Text("实时同传")
                            Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioStyle.blue)
                        .padding(.horizontal, 17).frame(height: 44)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().strokeBorder(StudioStyle.blue.opacity(0.12)))
                    }
                }
            } else {
                DialogueLanguagePicker(preferences: preferences,
                                       otherLanguage: $controller.lastOtherLanguage)
                Button {
                    if !keyboardMode && (controller.isRunning || controller.isPreparing) { controller.pause() }
                    controller.dialogueKeyboardEnabled.toggle()
                    if !keyboardMode { inputFocused = false }
                } label: {
                    Label(keyboardMode ? "语音" : "键盘", systemImage: keyboardMode ? "mic.fill" : "keyboard")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 15).frame(height: 42)
                        .background(.white, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(.white).frame(width: 100, height: 100)
                if mode == .listen {
                    Image(systemName: "waveform")
                        .font(.system(size: 42, weight: .medium))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .offset(x: 26, y: 18)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 43, weight: .medium))
                }
            }
            .foregroundStyle(Color(red: 0.56, green: 0.57, blue: 0.60))
            Text(mode == .listen ? emptyTitle : "开始一段对话")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(StudioStyle.ink)
            Text(mode == .listen ? emptySubtitle : keyboardMode
                 ? "输入任一语言，自动识别并翻译成另一种语言。"
                 : "选择说话的人，完成后自动显示译文。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 45)
            if controller.isPreparing && mode == .listen {
                CleanModelProgress(service: controller.whisper)
                    .padding(.horizontal, 52).padding(.top, 8)
            }
            if controller.languagePackRequest != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备苹果离线语言包")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        switch controller.phase {
        case .preparing: "准备翻译模型"
        case .waitingForLanguagePack: "准备翻译语言包"
        case .listening, .recognizing: "正在倾听"
        case .translating: "正在翻译"
        case .speaking, .replaying: "正在播放译文"
        case .idle, .paused: "准备开始同传"
        }
    }

    private var emptySubtitle: String {
        switch controller.phase {
        case .preparing: "正在准备端侧翻译资源"
        case .waitingForLanguagePack: "下载进度由苹果系统显示"
        case .listening, .recognizing: "正在识别听到的语言"
        case .translating: "正在把听到的话翻译成你的语言"
        case .speaking, .replaying: "译文正在播放"
        case .idle, .paused: "选择麦克风，开始面对面翻译"
        }
    }

    private var liveControls: some View {
        VStack(spacing: 13) {
            LiveLanguagePicker(preferences: preferences, fallback: controller.lastOtherLanguage)
            Group {
                HStack(spacing: 34) {
                    VStack(spacing: 7) {
                        Button { Task { await controller.start() } } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 72, height: 72)
                                .background(StudioStyle.blue, in: Circle())
                        }
                        .disabled(controller.isPreparing || controller.isBroadcastMode ||
                                  controller.phase == .replaying)
                        Text(controller.isBroadcastMode ? "屏幕音频中" : "麦克风")
                    }
                #if !EAR_YI_DEVICE_TEST
                    VStack(spacing: 7) {
                        ScreenBroadcastControl()
                            .frame(width: 72, height: 72)
                            .background(StudioStyle.violet, in: Circle())
                        Text("屏幕广播")
                    }
                #endif
                }
            }
            #if EAR_YI_DEVICE_TEST
            if !active && !paused {
                Text("选择麦克风开始同传")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(StudioStyle.ink)
            }
            #else
            if !active && !paused {
                Text(controller.isBroadcastMode ? "屏幕音频正在翻译，停止请点屏幕广播" :
                     "选择麦克风，或广播其他 App 的屏幕音频")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(StudioStyle.ink)
            }
            #endif
        }
        .disabled(controller.isEnding)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
        .background(Color.clear)
    }

    private var liveSessionControls: some View {
        HStack(spacing: 16) {
            liveActionButton(symbol: "sparkles", tint: .purple,
                             accessibilityLabel: "实时总结") { showSummary = true }
            liveActionButton(symbol: preferences.autoReadAloud
                             ? "speaker.wave.2.fill" : "speaker.slash.fill",
                             tint: preferences.autoReadAloud ? StudioStyle.blue : .gray,
                             accessibilityLabel: preferences.autoReadAloud
                             ? "关闭译文朗读" : "开启译文朗读") {
                controller.toggleReadAloud()
            }
            liveActionButton(symbol: paused ? "play.fill" : "pause.fill", tint: StudioStyle.blue,
                             accessibilityLabel: paused ? "继续同传" : "暂停同传") {
                if paused { Task { await controller.start() } }
                else { controller.pause() }
            }
            liveActionButton(symbol: "stop.fill", tint: .red,
                             accessibilityLabel: "结束并保存") {
                controller.end(save: true)
            }
        }
        .disabled(controller.isEnding)
    }

    private func liveActionButton(symbol: String, tint: Color, accessibilityLabel: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.12)))
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var dialogueControls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                dialogueButton(preferences.preferredLanguage, tint: StudioStyle.cyan)
                dialogueButton(controller.lastOtherLanguage, tint: StudioStyle.violet)
            }
            if !controller.lines.isEmpty { sessionActions }
        }
        .disabled(controller.isEnding)
        .padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 9)
        .background(Color.clear)
    }

    private var keyboardControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动识别输入语言")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TextField("输入文字，自动识别语言", text: $controller.dialogueKeyboardDraft)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendText() }
                    .accessibilityLabel("输入文字，自动识别语言")
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                Button(action: sendText) {
                    Group {
                        if sending || controller.languagePackRequest != nil { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up").font(.title2.weight(.semibold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(StudioStyle.cyan, in: Circle())
                }
                .accessibilityLabel("发送并翻译")
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          controller.languagePackRequest != nil || controller.isEnding)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func sendText() {
        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, !sending, !controller.isEnding,
              controller.languagePackRequest == nil else { return }
        let requestID = UUID()
        Task {
            await controller.sendDialogueText(submitted, requestID: requestID)
        }
    }

    private func dialogueButton(_ language: String, tint: Color) -> some View {
        let selected = controller.activeDialogueLanguage == language
        return Button {
            inputFocused = false
            controller.isKeyboardInputFocused = false
            controller.dialogueKeyboardEnabled = false
            if selected { controller.pause() }
            else { Task { await controller.beginDialogue(in: language) } }
        } label: {
            Label(selected ? "结束说话" : "说\(AppLanguage.name(language))",
                  systemImage: selected ? "stop.fill" : "mic.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 56)
        }
        .foregroundStyle(selected ? Color.white : tint)
        .background(selected ? tint : .white, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(tint.opacity(0.3)))
        .disabled(controller.isPreparing)
    }

    private var sessionActions: some View {
        HStack {
            Button("重播") { controller.replay() }
            Spacer()
            Button("保存") { Task { await controller.saveCurrent() } }
            Spacer()
            if !controller.isBroadcastMode {
                Button("结束") { controller.end(save: true) }
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(StudioStyle.blue)
        .padding(.horizontal, 14)
    }
}

private struct LiveTranscriptCard: View {
    let original: String
    let translated: String
    let index: Int
    let completed: Bool
    let size: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(completed ? "已完成" : "识别中", systemImage: completed ? "checkmark.circle.fill" : "waveform")
                    .foregroundStyle(completed ? Color.green : .gray)
                Spacer()
                Text("#\(index)").foregroundStyle(.gray)
            }
            .font(.caption.weight(.semibold))
            Text(original).font(.system(size: size * 0.76)).foregroundStyle(.secondary)
            if !translated.isEmpty {
                Text(translated).font(.system(size: size, weight: .semibold))
                    .foregroundStyle(StudioStyle.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct DialogueTextBubble: View {
    let line: TranscriptLine
    let replay: () -> Void

    var body: some View {
        HStack {
            if !line.isMine { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLanguage.name(line.sourceLanguage))
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioStyle.violet)
                Text(line.original).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Button(action: replay) {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(StudioStyle.blue)
                    }
                    .accessibilityLabel("朗读译文")
                    Text(line.translated).font(.body.weight(.semibold)).textSelection(.enabled)
                }
            }
            .padding(18)
            .background(line.isMine ? Color.white : StudioStyle.violet.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 22))
            if line.isMine { Spacer(minLength: 44) }
        }
    }
}

private struct CleanModelProgress: View {
    @ObservedObject var service: WhisperService
    var body: some View {
        VStack(spacing: 5) {
            Text(service.downloadStage).font(.footnote).foregroundStyle(.secondary)
            if let value = service.downloadProgress {
                ProgressView(value: value)
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else { ProgressView() }
        }
    }
}
