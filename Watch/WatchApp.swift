import SwiftUI
import WatchConnectivity

@main
struct TranslatorWatchApp: App {
    @StateObject private var bridge = WatchController()
    var body: some Scene {
        WindowGroup { WatchView().environmentObject(bridge) }
    }
}

@MainActor
final class WatchController: NSObject, ObservableObject, WCSessionDelegate {
    @Published var isRunning = false
    @Published var latest = "打开 iPhone 上的耳译"

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func command(_ value: String) {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": value], replyHandler: nil)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let running = applicationContext["running"] as? Bool ?? false
        let text = applicationContext["latest"] as? String ?? ""
        Task { @MainActor in
            isRunning = running
            latest = text
        }
    }
}

struct WatchView: View {
    @EnvironmentObject private var bridge: WatchController
    var body: some View {
        VStack(spacing: 10) {
            Text("耳译").font(.headline)
            Text(bridge.latest).font(.caption).lineLimit(4)
            Button(bridge.isRunning ? "暂停" : "继续") { bridge.command("toggle") }
                .buttonStyle(.borderedProminent)
            Button("重播") { bridge.command("replay") }
        }.padding()
    }
}
