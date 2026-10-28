import Combine
import Foundation
import StoreKit
import SwiftUI

@MainActor
final class SubscriptionManager: ObservableObject {
    private static let productPrefix = Bundle.main.bundleIdentifier ?? "com.example.AirPodsTranslator"
    static let monthlyID = "\(productPrefix).pro.monthly"
    static let yearlyID = "\(productPrefix).pro.yearly"
    static let productIDs = [monthlyID, yearlyID]

    @Published private(set) var isPro = false
    @Published private(set) var activeProductID: String?
    @Published var errorMessage: String?
    private var updatesTask: Task<Void, Never>?

    init() {
        Task { await refresh() }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        var active: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            active = transaction.productID
        }
        activeProductID = active
        isPro = active != nil
    }

    func restore() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class UsageMeter: ObservableObject {
    static let freeLiveSeconds = 10 * 60
    static let freeDialogueLines = 20
    @Published private(set) var liveSeconds = 0
    @Published private(set) var dialogueLines = 0
    private var day = ""
    private var previousTick = Date()
    private var fractionalSeconds: TimeInterval = 0

    init() { refreshDay() }

    var remainingLiveSeconds: Int { max(0, Self.freeLiveSeconds - liveSeconds) }
    var remainingDialogueLines: Int { max(0, Self.freeDialogueLines - dialogueLines) }

    func track(active: Bool) {
        refreshDay()
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(previousTick))
        previousTick = now
        guard active else { return }
        fractionalSeconds += elapsed
        let whole = Int(fractionalSeconds)
        guard whole > 0 else { return }
        fractionalSeconds -= TimeInterval(whole)
        liveSeconds += whole
        UserDefaults.standard.set(liveSeconds, forKey: "usage.liveSeconds")
    }

    func recordDialogueLine() {
        refreshDay()
        dialogueLines += 1
        UserDefaults.standard.set(dialogueLines, forKey: "usage.dialogueLines")
    }

    private func refreshDay() {
        let today = String(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970))
        guard day != today else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "usage.day") != today {
            defaults.set(today, forKey: "usage.day")
            defaults.set(0, forKey: "usage.liveSeconds")
            defaults.set(0, forKey: "usage.dialogueLines")
        }
        day = today
        liveSeconds = defaults.integer(forKey: "usage.liveSeconds")
        dialogueLines = defaults.integer(forKey: "usage.dialogueLines")
        fractionalSeconds = 0
        previousTick = Date()
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscriptions: SubscriptionManager

    var body: some View {
        NavigationStack {
            SubscriptionStoreView(productIDs: SubscriptionManager.productIDs) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 38)).foregroundStyle(.cyan)
                    Text("让每次交流都更自由")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Pro 解锁无限同传与对话。翻译、语音识别和记录仍在你的设备上处理。")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        NavigationLink("使用条款") { LegalPageView(document: AppLegal.terms) }
                        NavigationLink("隐私政策") { LegalPageView(document: AppLegal.privacy) }
                    }
                    .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("耳译 Pro")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("恢复购买") { Task { await subscriptions.restore() } }
                }
            }
            .onChange(of: subscriptions.isPro) { _, active in if active { dismiss() } }
            .alert("购买未完成", isPresented: Binding(get: { subscriptions.errorMessage != nil },
                                                 set: { if !$0 { subscriptions.errorMessage = nil } })) {
                Button("知道了") { subscriptions.errorMessage = nil }
            } message: { Text(subscriptions.errorMessage ?? "") }
        }
    }
}
