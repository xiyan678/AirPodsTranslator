import Foundation

@MainActor
struct OfflineLanguageResources {
    struct SpeechAsset {
        var isInstalled: () async -> Bool
        var install: () async throws -> Void
    }

    var speechAsset: (String) async -> SpeechAsset?

    static var live: Self { Self(speechAsset: { _ in nil }) }

    /// Returns languages for which the device has no supported speech model.
    func prepare(source: String, target: String,
                 translation: () async throws -> Void) async throws -> [String] {
        try await translation()
        return []
    }
}
