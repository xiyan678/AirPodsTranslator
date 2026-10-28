import SwiftUI

@main
struct TranslatorApp: App {
    @StateObject private var controller = ConversationController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
        }
    }
}
