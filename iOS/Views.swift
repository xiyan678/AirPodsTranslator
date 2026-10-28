import PhotosUI
import StoreKit
import SwiftUI
import Translation
import UIKit

struct RootView: View {
    @EnvironmentObject private var controller: ConversationController
    @State private var selectedTab: MainTab = .listen
    var body: some View {
        page
            .safeAreaInset(edge: .top, spacing: 0) {
                SubtitlePictureInPicturePanel(manager: controller.pictureInPicture)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !controller.isKeyboardInputFocused { bottomNavigation }
            }
            .background(Color(red: 0.95, green: 0.95, blue: 0.97))
            .tint(StudioStyle.blue)
            .sheet(isPresented: $controller.showPaywall) {
                PaywallView(subscriptions: controller.subscriptions)
            }
            .alert("提示", isPresented: Binding(get: { controller.errorMessage != nil },
                                               set: { if !$0 { controller.errorMessage = nil } })) {
                Button("知道了") { controller.errorMessage = nil }
            } message: { Text(controller.errorMessage ?? "") }
            .translationTask(controller.languagePackRequest?.configuration) { session in
                guard let request = controller.languagePackRequest else { return }
                do {
                    try await prepareLanguagePack(session)
                    await controller.languagePackReady(for: request.id, session: session)
                } catch {
                    controller.languagePackFailed(error, for: request.id)
                }
            }
    }

    @ViewBuilder private var page: some View {
        switch selectedTab {
        case .listen: CleanSessionView(preferences: controller.preferences, mode: .listen)
        case .dialogue: CleanSessionView(preferences: controller.preferences, mode: .dialogue)
        case .history: HistoryView(store: controller.store)
        case .settings: SettingsView(preferences: controller.preferences)
        }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 3) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    if tab == .listen, !controller.selectMode(.listen) { return }
                    if tab == .dialogue, !controller.selectMode(.dialogue) { return }
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 23, weight: .semibold))
                            .frame(height: 26)
                        Text(tab.title).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? StudioStyle.blue : Color.black)
                    .frame(maxWidth: .infinity).frame(height: 58)
                    .background(selectedTab == tab ? Color(red: 0.93, green: 0.93, blue: 0.94) :
                                Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .disabled(controller.isEnding)
        .background(.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.gray.opacity(0.18)))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
}

private enum MainTab: Int, CaseIterable, Identifiable {
    case listen, dialogue, history, settings
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .listen: "同传"
        case .dialogue: "对话"
        case .history: "历史"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .listen: "mic.fill"
        case .dialogue: "person.2.fill"
        case .history: "clock.fill"
        case .settings: "gearshape.fill"
        }
    }
}

private enum LanguagePreparationError: LocalizedError {
    case timedOut
    var errorDescription: String? { "语言包下载未完成，请检查网络后重试" }
}

private func prepareLanguagePack(_ session: TranslationSession) async throws {
    try await session.prepareTranslation()

}

struct ReviseLineView: View {
    @EnvironmentObject private var controller: ConversationController
    @Environment(\.dismiss) private var dismiss
    let line: TranscriptLine
    @State private var text: String
    @State private var source: String
    @State private var target: String
    @State private var submitting = false

    init(line: TranscriptLine) {
        self.line = line
        _text = State(initialValue: line.original)
        _source = State(initialValue: line.sourceLanguage)
        _target = State(initialValue: line.targetLanguage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("修改原文") { TextEditor(text: $text).frame(minHeight: 100) }
                Section("语言") {
                    Picker("原语言", selection: $source) {
                        ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    Picker("译文语言", selection: $target) {
                        ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                    }
                }
                Button("重新翻译") {
                    submitting = true
                    Task {
                        await controller.reviseLastLine(line.id, text: text, source: source, target: target)
                        submitting = false
                        if controller.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(submitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source == target)
            }
            .navigationTitle("修改上一句")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
        }
    }
}

struct TranscriptCard: View {
    let line: TranscriptLine
    let size: Double
    var onEdit: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(line.isMine ? "我说" : "听到", systemImage: line.isMine ? "person.fill" : "waveform")
                    .foregroundStyle(line.isMine ? StudioStyle.cyan : StudioStyle.violet)
                Text(AppLanguage.name(line.sourceLanguage) + " → " + AppLanguage.name(line.targetLanguage))
                Spacer()
                Text(line.time, style: .time)
            }.font(.caption).foregroundStyle(.secondary)
            Text(line.original).font(.system(size: size * 0.76)).foregroundStyle(StudioStyle.muted)
            Text(line.translated).font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(StudioStyle.ink)
            HStack {
                if let onEdit { Button("修改并重译", action: onEdit) }
                Spacer()
                ShareLink(item: line.original + "\n" + line.translated) { Image(systemName: "square.and.arrow.up") }
            }.font(.footnote.weight(.semibold)).foregroundStyle(StudioStyle.blue)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(
            line.isMine ? StudioStyle.cyan.opacity(0.25) : StudioStyle.violet.opacity(0.25)))
    }
}

struct CameraTranslateView: View {
    @EnvironmentObject private var controller: ConversationController
    @State private var photo: PhotosPickerItem?
    @State private var showCamera = false
    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("看见即翻译")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(StudioStyle.ink)
                        HStack(spacing: 12) {
                            Button { showCamera = true } label: {
                                Label("拍照", systemImage: "camera.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                            PhotosPicker(selection: $photo, matching: .images) {
                                Label("相册", systemImage: "photo.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        if controller.imageIsProcessing {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在识别并翻译图片…")
                            }.font(.footnote).foregroundStyle(StudioStyle.muted)
                        }
                        photoResultCard(title: "识别原文", text: controller.imageOriginal.isEmpty ? "选择图片后显示文字" : controller.imageOriginal)
                        photoResultCard(title: "翻译结果", text: controller.imageTranslation.isEmpty ? "译文会显示在这里" : controller.imageTranslation)
                        if !controller.imageTranslation.isEmpty {
                            ShareLink(item: controller.imageTranslation) {
                                Label("分享译文", systemImage: "square.and.arrow.up")
                            }
                        }
                    }.padding(22)
                }
            }
            .navigationTitle("拍照翻译")
            .sheet(isPresented: $showCamera) {
                CameraPicker { data in Task { await controller.translateImage(data) } }
            }
            .onChange(of: photo) { _, value in
                Task {
                    do {
                        guard let data = try await value?.loadTransferable(type: Data.self) else {
                            controller.errorMessage = "无法读取所选图片"
                            return
                        }
                        await controller.translateImage(data)
                    } catch {
                        controller.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func photoResultCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(StudioStyle.blue)
            Text(text).font(.body).foregroundStyle(StudioStyle.ink).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(20)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct HistoryView: View {
    @ObservedObject var store: ConversationStore
    @State private var query = ""
    @State private var storageError: String?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    private var filtered: [SavedConversation] {
        store.conversations.filter {
            query.isEmpty || $0.summary.localizedCaseInsensitiveContains(query) ||
            $0.lines.contains { $0.original.localizedCaseInsensitiveContains(query) || $0.translated.localizedCaseInsensitiveContains(query) }
        }
    }
    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if let loadError = store.loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                if filtered.isEmpty, store.loadError == nil {
                    ContentUnavailableView(query.isEmpty ? "还没有对话记录" : "没有找到相关记录",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text(query.isEmpty ? "保存的同传和对话会显示在这里。" : "试试其他搜索词。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(filtered) { item in
                    NavigationLink {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                Text(item.summary)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let outline = item.outline {
                                    Text(outline.plainText).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ShareLink(item: outline.plainText) {
                                        Label("分享总结", systemImage: "square.and.arrow.up")
                                    }
                                }
                                ForEach(item.lines) { TranscriptCard(line: $0, size: 22) }
                                ShareLink(item: item.lines.map { $0.original + "\n" + $0.translated }.joined(separator: "\n\n")) {
                                    Label("导出对话", systemImage: "square.and.arrow.up")
                                }
                            }.padding()
                        }.navigationTitle(item.date.formatted(date: .abbreviated, time: .shortened))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))).font(.headline)
                            Text(item.summary).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { filtered[$0].id })
                    do { try store.delete(ids) }
                    catch { storageError = error.localizedDescription }
                }
            }
            .searchable(text: $query)
            .navigationTitle("对话记录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !filtered.isEmpty {
                        Button(editMode.isEditing ? "完成" : "编辑") {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.canUndoDelete && !store.conversations.isEmpty {
                        Button("撤销删除") {
                            do { try store.undoDelete() }
                            catch { storageError = error.localizedDescription }
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if editMode.isEditing {
                        Button("删除所选（\(selection.count)）", role: .destructive) {
                            do {
                                try store.delete(selection)
                                selection = []
                            } catch { storageError = error.localizedDescription }
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: editMode) { _, value in if !value.isEditing { selection = [] } }
            .onChange(of: query) { _, _ in selection = [] }
            .onChange(of: store.conversations.map(\.id)) { _, ids in
                selection.formIntersection(Set(ids))
                if ids.isEmpty { editMode = .inactive }
            }
            .scrollContentBackground(.hidden)
            .background(StudioBackground().ignoresSafeArea())
            .alert("删除失败", isPresented: Binding(get: { storageError != nil },
                                              set: { if !$0 { storageError = nil } })) {
                Button("知道了") { storageError = nil }
            } message: { Text(storageError ?? "") }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: ConversationController
    @ObservedObject var preferences: Preferences
    @State private var termSource = ""
    @State private var termReplacement = ""
    @State private var showManageSubscriptions = false
    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("源语言", selection: $preferences.sourceLanguage) {
                        Text("自动识别").tag("auto")
                        ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    Picker("目标语言", selection: $preferences.preferredLanguage) {
                        ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    Button("交换源语言和目标语言") {
                        let source = preferences.sourceLanguage
                        preferences.sourceLanguage = preferences.preferredLanguage
                        preferences.preferredLanguage = source == "auto" ? controller.lastOtherLanguage : source
                    }
                    Toggle("自动朗读译文", isOn: $preferences.autoReadAloud)
                    Text("佩戴耳机时开启朗读，可减少扬声器声音被麦克风再次收录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("离线语言包") { LanguagePacksView(preferences: preferences) }
                }
                Section("翻译质量") {
                    Picker("处理模式", selection: $preferences.processingMode) {
                        ForEach(ProcessingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("嘈杂环境：突出近处人声", isOn: $preferences.nearField)
                    Text("切换嘈杂环境模式后，重新开始收音可更新麦克风处理方式。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("显示和播放") {
                    HStack { Text("字幕大小"); Slider(value: $preferences.fontSize, in: 17...38) }
                    HStack {
                        Text("播报速度")
                        Slider(value: Binding(get: { Double(preferences.speechRate) },
                                              set: { preferences.speechRate = Float($0) }), in: 0.35...0.65)
                    }
                }
                SummarySettingsSection()
                Section("记录") { Toggle("自动保存对话", isOn: $preferences.saveAutomatically) }
                Section("声译 Pro") {
                    PremiumStatusCard(subscriptions: controller.subscriptions)
                    Button("查看月度与年度订阅") { controller.showPaywall = true }
                    Button("管理订阅") { showManageSubscriptions = true }
                    Button("恢复购买") {
                        Task {
                            await controller.subscriptions.restore()
                            if let error = controller.subscriptions.errorMessage {
                                controller.errorMessage = error
                                controller.subscriptions.errorMessage = nil
                            }
                        }
                    }
                }
                Section("关于") {
                    Button {
                        let application = UIApplication.shared
                        let url = application.canOpenURL(AppLegal.authorAppURL)
                            ? AppLegal.authorAppURL : AppLegal.authorProfileURL
                        application.open(url)
                    } label: {
                        Label("联系作者（抖音）", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink("使用条款") { LegalPageView(document: AppLegal.terms) }
                    NavigationLink("隐私政策") { LegalPageView(document: AppLegal.privacy) }
                    LabeledContent("发布者", value: AppLegal.publisher)
                }
                Section("专有词汇") {
                    if let termsError = preferences.termsError {
                        Text(termsError).foregroundStyle(.red)
                    } else {
                        TextField("识别到的词", text: $termSource)
                        TextField("希望显示的译词", text: $termReplacement)
                        Button("添加") {
                            let source = termSource.trimmingCharacters(in: .whitespaces)
                            let replacement = termReplacement.trimmingCharacters(in: .whitespaces)
                            guard !source.isEmpty, !replacement.isEmpty else { return }
                            preferences.terms.append(Term(source: source, replacement: replacement))
                            termSource = ""; termReplacement = ""
                        }
                        ForEach(preferences.terms) { term in
                            HStack { Text(term.source); Spacer(); Text(term.replacement).foregroundStyle(.secondary) }
                        }
                        .onDelete { preferences.terms.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("设置")
            .scrollContentBackground(.hidden)
            .background(StudioBackground().ignoresSafeArea())
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .onChange(of: preferences.sourceLanguage) { _, source in
                if source == preferences.preferredLanguage { preferences.sourceLanguage = "auto" }
            }
            .onChange(of: preferences.preferredLanguage) { _, target in
                if target == preferences.sourceLanguage { preferences.sourceLanguage = "auto" }
            }
        }
    }
}

private struct PremiumStatusCard: View {
    @ObservedObject var subscriptions: SubscriptionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(subscriptions.isPro ? "Pro 已开通" : "免费版", systemImage: "sparkles")
                .font(.headline).foregroundStyle(StudioStyle.ink)
            if subscriptions.isPro { Text("无限同传与对话").foregroundStyle(.secondary) }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct LanguagePacksView: View {
    @ObservedObject var preferences: Preferences
    @State private var selected = "en"
    @State private var reverse = false
    @State private var config: TranslationSession.Configuration?
    @State private var requestedPair: (source: String, target: String)?
    @State private var message = ""
    private var choices: [LanguageOption] {
        AppLanguage.all.filter { $0.code != preferences.preferredLanguage }
    }
    var body: some View {
        Form {
            Picker("下载语言", selection: $selected) {
                ForEach(choices) {
                    Text($0.name).tag($0.code)
                }
            }
            Picker("方向", selection: $reverse) {
                Text("听对方").tag(false)
                Text("我回复").tag(true)
            }.pickerStyle(.segmented)
            Button("下载并准备离线翻译") {
                guard selected != preferences.preferredLanguage else {
                    message = "请选择另一种语言"
                    return
                }
                let source = reverse ? preferences.preferredLanguage : selected
                let target = reverse ? selected : preferences.preferredLanguage
                requestedPair = (source, target)
                config = TranslationConfigurationFactory.make(
                    source: source, target: target, mode: preferences.processingMode
                )
            }.disabled(config != nil || choices.isEmpty)
            if config != nil {
                HStack {
                    ProgressView()
                    Text("正在准备语言包；下载进度由系统显示")
                }
            }
            Text(message)
        }
        .navigationTitle("离线语言包")
        .onAppear { syncSelection() }
        .onChange(of: preferences.preferredLanguage) { _, _ in syncSelection() }
        .translationTask(config) { session in
            guard let requestedPair else { return }
            do {
                try await prepareLanguagePack(session)
                message = "\(AppLanguage.name(requestedPair.source)) → \(AppLanguage.name(requestedPair.target)) 已就绪"
            } catch { message = error.localizedDescription }
            config = nil
            self.requestedPair = nil
        }
    }

    private func syncSelection() {
        if !choices.contains(where: { $0.code == selected }) {
            selected = choices.first?.code ?? ""
        }
    }
}
