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
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasing = false
    @Published var errorMessage: String?
    let referrals = ReferralManager()
    var hasUnlimitedAccess: Bool { isPro || referrals.rewardActive }
    private var updatesTask: Task<Void, Never>?
    private var referralObserver: AnyCancellable?

    init() {
        referralObserver = referrals.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { await refresh(); await referrals.refresh(); await loadProducts() }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   Self.productIDs.contains(transaction.productID) {
                    await transaction.finish()
                    await self.referrals.submitPurchase(result.jwsRepresentation)
                }
                await self.refresh()
            }
        }
    }
    deinit { updatesTask?.cancel() }

    func loadProducts() async {
        do { products = try await Product.products(for: Self.productIDs) }
        catch { products = [] }
    }
    func price(for id: String, fallback: String) -> String {
        products.first(where: { $0.id == id })?.displayPrice ?? fallback
    }
    func purchase(_ id: String) async {
        guard !purchasing else { return }
        purchasing = true; errorMessage = nil
        defer { purchasing = false }
        do {
            if products.isEmpty { products = try await Product.products(for: Self.productIDs) }
            guard let product = products.first(where: { $0.id == id }) else {
                errorMessage = "暂时无法加载订阅商品，请稍后重试"
                return
            }
            guard let account = referrals.accountToken else {
                errorMessage = "无法保存购买身份，请解锁设备后重试"
                return
            }
            let result = try await product.purchase(options: [.appAccountToken(account)])
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "未能验证苹果购买凭证，请尝试恢复购买"
                    return
                }
                await transaction.finish()
                await refresh()
                await referrals.submitPurchase(verification.jwsRepresentation)
            case .pending: errorMessage = "购买正在等待批准，批准后将自动开通"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func refresh() async {
        var active: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.expirationDate == nil || transaction.expirationDate! > Date() else { continue }
            active = transaction.productID
        }
        activeProductID = active
        isPro = active != nil
    }
    func refreshRewards() async {
        await referrals.refresh()
        guard referrals.status?.activated == true else { return }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, Self.productIDs.contains(tx.productID),
                  tx.revocationDate == nil else { continue }
            await referrals.submitPurchase(result.jwsRepresentation)
        }
    }
    func restore() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await refresh()
            await refreshRewards()
        } catch { errorMessage = error.localizedDescription }
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
        let now = Date()
        refreshDay()
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

    func refreshDay() {
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
            Form {
                Section {
                    Text("声译 Pro").font(.largeTitle.bold())
                    Text("解锁无限同传与对话").foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await subscriptions.purchase(SubscriptionManager.monthlyID) }
                    } label: {
                        LabeledContent("月度 Pro", value: subscriptions.price(for: SubscriptionManager.monthlyID, fallback: "¥68.00") + "/月")
                    }
                    Button {
                        Task { await subscriptions.purchase(SubscriptionManager.yearlyID) }
                    } label: {
                        LabeledContent("年度 Pro", value: subscriptions.price(for: SubscriptionManager.yearlyID, fallback: "¥498.00") + "/年")
                    }
                }.disabled(subscriptions.purchasing)
                Section {
                    Text("自动续订，可随时在 Apple 账户中取消。实际价格以苹果购买确认页为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("使用条款") { LegalPageView(document: AppLegal.terms) }
                    NavigationLink("隐私政策") { LegalPageView(document: AppLegal.privacy) }
                }
            }
            .navigationTitle("声译 Pro")
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
