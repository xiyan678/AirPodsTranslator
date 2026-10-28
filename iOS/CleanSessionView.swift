import SwiftUI

struct CleanSessionView: View {
    @EnvironmentObject private var controller: ConversationController
    @ObservedObject var preferences: Preferences
    let mode: ConversationMode
    @State private var showText = false
    @State private var showPhoto = false
    @State private var editingLine: TranscriptLine?

    private var active: Bool { controller.mode == mode && controller.isRunning }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.95, green: 0.95, blue: 0.97).ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if controller.lines.isEmpty {
                        Spacer(minLength: 25)
                        emptyState
                        Spacer(minLength: 25)
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView {
                                LazyVStack(spacing: 13) {
                                    if mode == .listen { compactStatus }
                                    ForEach(controller.lines) { line in
                                        TranscriptCard(line: line, size: preferences.fontSize,
                                                       onEdit: controller.lines.last?.id == line.id ? {
                                                           editingLine = line
                                                       } : nil)
                                        .id(line.id)
                                    }
                                    if !controller.liveText.isEmpty {
                                        Text(controller.liveText)
                                            .font(.system(size: preferences.fontSize * 0.8))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(18)
                                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
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
                    if mode == .listen { liveControls } else { dialogueControls }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showText) { TextTranslationView(preferences: preferences) }
            .sheet(isPresented: $showPhoto) { CameraTranslateView() }
            .sheet(item: $editingLine) { line in ReviseLineView(line: line) }
            .onAppear {
                if controller.mode != mode {
                    if controller.isRunning || controller.isPreparing { controller.pause() }
                    controller.mode = mode
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
                Spacer()
                Menu {
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
            } else {
                DialogueLanguagePicker(preferences: preferences,
                                       otherLanguage: $controller.lastOtherLanguage)
                Button { showText = true } label: {
                    Label("键盘", systemImage: "keyboard")
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
            Text(mode == .listen ? emptySubtitle : "选择说话的人，完成后自动显示译文。")
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

    private var compactStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: active ? "waveform" : "pause.circle")
            Text(controller.status)
            Spacer()
            Text(controller.outputRouteName).lineLimit(1)
        }
        .font(.footnote).foregroundStyle(StudioStyle.muted)
        .padding(.horizontal, 4)
    }

    private var liveControls: some View {
        VStack(spacing: 13) {
            LiveLanguagePicker(preferences: preferences, fallback: controller.lastOtherLanguage)
            HStack(spacing: 34) {
                VStack(spacing: 7) {
                    Button {
                        if active { controller.pause() }
                        else { Task { await controller.start() } }
                    } label: {
                        Image(systemName: active ? "pause.fill" : "mic.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 94, height: 94)
                            .background(StudioStyle.blue, in: Circle())
                    }
                    .disabled(controller.isPreparing || controller.isBroadcastMode ||
                              (controller.phase == .replaying && !controller.isRunning))
                    Text(controller.isBroadcastMode ? "屏幕音频中" : active ? "暂停" : "麦克风")
                }
                VStack(spacing: 7) {
                    ScreenBroadcastControl()
                        .frame(width: 94, height: 94)
                        .background(StudioStyle.violet, in: Circle())
                    Text("屏幕广播")
                }
            }
            .font(.subheadline.weight(.semibold))
            Text(controller.isBroadcastMode ? "屏幕音频正在翻译，停止请点屏幕广播" :
                 "选择麦克风，或广播其他 App 的屏幕音频")
                .font(.footnote.weight(.medium))
                .foregroundStyle(StudioStyle.ink)
            if !controller.lines.isEmpty { sessionActions }
        }
        .padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 9)
        .background(Color.clear)
    }

    private var dialogueControls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                dialogueButton(preferences.preferredLanguage, tint: StudioStyle.cyan)
                dialogueButton(controller.lastOtherLanguage, tint: StudioStyle.violet)
            }
            if !controller.lines.isEmpty { sessionActions }
        }
        .padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 9)
        .background(Color.clear)
    }

    private func dialogueButton(_ language: String, tint: Color) -> some View {
        let selected = controller.activeDialogueLanguage == language
        return Button {
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
                Button("结束") { controller.end() }
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(StudioStyle.blue)
        .padding(.horizontal, 14)
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
