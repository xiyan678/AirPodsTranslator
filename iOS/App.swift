import SwiftUI

@main
struct TranslatorApp: App {
    @StateObject private var controller = ConversationController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--ui-review-fixture") else { return }
                    controller.summary.automatic = false
                    let lines = [
                        TranscriptLine(sourceLanguage: "en", targetLanguage: "zh",
                            original: "The meeting starts at nine tomorrow morning.",
                            translated: "会议明天上午九点开始。", isMine: false),
                        TranscriptLine(sourceLanguage: "zh", targetLanguage: "en",
                            original: "好的，我会提前准备好资料。",
                            translated: "Okay, I will prepare the materials in advance.", isMine: true)
                    ]
                    controller.lines = lines
                    try? await controller.store.save(lines, id: controller.currentConversationID,
                        outline: SummaryOutline(keyPoints: ["会议明天上午九点开始"], questions: [],
                                                nextSteps: ["提前准备会议资料"]))
                }
                #endif
        }
    }
}
