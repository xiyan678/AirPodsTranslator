import Combine
import DeviceCheck
import Foundation
import Security
import SwiftUI

struct ServiceCredential: Codable {
    let token: String
    let expiresAt: Double
    var isValid: Bool { expiresAt > Date().timeIntervalSince1970 * 1000 }
}

enum ServiceAccessError: LocalizedError {
    case unavailable, pairingRequired, rejected(String), storage
    var errorDescription: String? {
        switch self {
        case .unavailable: "服务地址未配置，请更新 App 后重试。"
        case .pairingRequired: "请先在设置的“服务连接”中输入服务器连接码。"
        case .rejected(let text): text
        case .storage: "连接凭证未能保存，请解锁设备，并重新生成连接码后重试。"
        }
    }
}

@MainActor
final class ServiceAccess: ObservableObject {
    static let shared = ServiceAccess()
    @Published private(set) var credential: ServiceCredential?
    @Published private(set) var busy = false
    @Published var message: String?
    var isConnected: Bool { credential?.isValid == true }
    var token: String? { isConnected ? credential?.token : nil }
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "shengyi.service-access", kSecAttrAccount as String: "credential"]

    private init() {
        var item: CFTypeRef?
        let read = query.merging([kSecReturnData as String: true]) { _, new in new }
        if SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            credential = try? JSONDecoder().decode(ServiceCredential.self, from: data)
        }
    }
    func connect(code: String) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            guard let base = CloudSpeechAPI.endpoint(summaryAddress: Bundle.main.object(forInfoDictionaryKey: "EarYiSummaryServiceURL") as? String) else {
                throw ServiceAccessError.unavailable
            }
            let url = base.deletingLastPathComponent().appendingPathComponent("client").appendingPathComponent("pair")
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                struct Failure: Decodable { let error: String }
                throw ServiceAccessError.rejected((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "连接失败，请重新生成连接码后重试。")
            }
            let value = try JSONDecoder().decode(ServiceCredential.self, from: data)
            guard value.isValid, value.token.count == 43,
                  value.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
                throw URLError(.badServerResponse)
            }
            let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            let saved = update == errSecItemNotFound
                ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
            guard saved == errSecSuccess else { throw ServiceAccessError.storage }
            credential = value
            message = "连接成功，可以使用安娜语音与 AI 总结。"
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}

enum ServiceAuthorization {
    static func authorized(_ original: URLRequest) async throws -> URLRequest {
        guard original.url?.scheme == "https" else { throw ServiceAccessError.unavailable }
        var request = original
        if let token = await MainActor.run(body: { ServiceAccess.shared.token }) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            guard DCDevice.current.isSupported else { throw ServiceAccessError.pairingRequired }
            let token: Data
            do { token = try await DCDevice.current.generateToken() }
            catch { throw ServiceAccessError.pairingRequired }
            request.setValue(token.base64EncodedString(), forHTTPHeaderField: "X-Device-Token")
        }
        try Task.checkCancellation()
        return request
    }
}

struct ServiceConnectionView: View {
    @ObservedObject private var access = ServiceAccess.shared
    @State private var code = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("连接状态", value: access.isConnected ? "已连接" : "未连接")
                TextField("服务器连接码", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .accessibilityIdentifier("service-pairing-code")
                Button {
                    Task {
                        await access.connect(code: code)
                        if access.isConnected { code = "" }
                    }
                } label: {
                    HStack { Text("连接服务"); if access.busy { Spacer(); ProgressView() } }
                }
                .disabled(access.busy || code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "").count != 12)
                .accessibilityIdentifier("service-pairing-connect")
            } footer: {
                Text("在服务器生成连接码后输入一次，用于安娜语音和 AI 总结。连接码 10 分钟有效。")
            }
            if let message = access.message { Section { Text(message).font(.subheadline) } }
        }
        .navigationTitle("服务连接").navigationBarTitleDisplayMode(.inline)
    }
}
