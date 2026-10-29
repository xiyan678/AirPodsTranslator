import Foundation

enum CloudSpeechAPI {
    struct Body: Encodable {
        let text: String
        let rate: Double
    }

    static func endpoint(summaryAddress: String?) -> URL? {
        guard let summaryAddress, let url = URL(string: summaryAddress),
              url.scheme == "https", url.host != nil, url.query == nil, url.fragment == nil else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("speech")
    }

    static func rate(_ appleRate: Float) -> Double {
        guard appleRate.isFinite else { return 1 }
        return min(2, max(0.5, Double(appleRate) / 0.48))
    }

    static func synthesize(_ text: String, rate: Float) async throws -> Data {
        guard let url = endpoint(summaryAddress: Bundle.main.object(forInfoDictionaryKey: "EarYiSummaryServiceURL") as? String),
              url.host != nil else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 50)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(text: text, rate: Self.rate(rate)))
        request = try await ServiceAuthorization.authorized(request)
        let (audio, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "audio/mpeg", !audio.isEmpty, audio.count <= 16 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return audio
    }
}
