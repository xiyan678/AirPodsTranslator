import Combine
import DeviceCheck
import Foundation
import Security

struct ReferralStatus: Decodable {
    let code: String?
    let activated: Bool
    let friendsActivated: Int
    let friendsSubscribed: Int
    let rewardDays: Int
    let rewardExpiresAt: Double
    let serverTime: Double
}

@MainActor
final class ReferralManager: ObservableObject {
    @Published private(set) var status: ReferralStatus?
    @Published private(set) var busy = false
    @Published var message: String?
    private var receivedAt: TimeInterval = 0
    private var identity: Identity?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private struct Identity: Codable { let id: UUID; let secret: String }

    var accountToken: UUID? { try? loadIdentity().id }
    var rewardActive: Bool {
        guard let status else { return false }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - receivedAt)
        return status.rewardExpiresAt > status.serverTime + elapsed * 1000
    }
    func refresh() async { await perform("status") }
    func generate() async { await perform("generate") }
    func activate(_ code: String) async { await perform("activate", code: code.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func submitPurchase(_ signedTransaction: String) async {
        // The status operation will create the authenticated installation on first use.
        await perform("purchase", signedTransaction: signedTransaction)
    }
    private func loadIdentity() throws -> Identity {
        if let identity { return identity }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "shengyi.referral.installation", kSecAttrAccount as String: "identity"]
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &result)
        if found == errSecSuccess, let data = result as? Data {
            let saved = try JSONDecoder().decode(Identity.self, from: data)
            identity = saved
            return saved
        }
        guard found == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
        let saved = Identity(id: UUID(), secret: UUID().uuidString + UUID().uuidString)
        let attributes = query.merging([kSecValueData as String: try JSONEncoder().encode(saved),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw URLError(.cannotCreateFile)
        }
        identity = saved
        return saved
    }
    private func perform(_ action: String, code: String? = nil, signedTransaction: String? = nil) async {
        // Serialize network operations without dropping a purchase proof during a status refresh.
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
        message = nil
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        do {
            try Task.checkCancellation()
            let identity = try loadIdentity()
            guard DCDevice.current.isSupported,
                  let speechURL = CloudSpeechAPI.endpoint(summaryAddress: Bundle.main.object(forInfoDictionaryKey: "EarYiSummaryServiceURL") as? String) else {
                throw URLError(.unsupportedURL)
            }
            let url = speechURL.deletingLastPathComponent().appendingPathComponent("referrals").appendingPathComponent(action)
            let token = try await DCDevice.current.generateToken()
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token.base64EncodedString(), forHTTPHeaderField: "X-Device-Token")
            var body = ["installationID": identity.id.uuidString, "installationSecret": identity.secret]
            if let code { body["code"] = code }
            if let signedTransaction { body["signedTransaction"] = signedTransaction }
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                struct Failure: Decodable { let error: String }
                message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "活动服务暂不可用，请稍后重试"
                return
            }
            status = try JSONDecoder().decode(ReferralStatus.self, from: data)
            receivedAt = ProcessInfo.processInfo.systemUptime
            if action == "activate" { message = "激活成功，已获得 1 天无限制使用" }
        } catch is CancellationError { }
        catch { message = "连接失败，请稍后重试" }
    }
}
