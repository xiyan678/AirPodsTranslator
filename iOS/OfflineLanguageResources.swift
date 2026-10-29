import Foundation
import Speech

@MainActor
struct OfflineLanguageResources {
    struct SpeechAsset {
        var isInstalled: () async -> Bool
        var install: () async throws -> Void
    }

    var speechAsset: (String) async -> SpeechAsset?

    static var live: Self {
        Self(speechAsset: { language in
            guard let transcriber = await AppleSpeechSession.supportedTranscriber(language: language),
                  await AssetInventory.status(forModules: [transcriber]) != .unsupported else { return nil }
            return SpeechAsset(
                isInstalled: { await AssetInventory.status(forModules: [transcriber]) == .installed },
                install: {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                }
            )
        })
    }

    /// Returns languages for which the device has no supported speech model.
    func prepare(source: String, target: String,
                 translation: () async throws -> Void) async throws -> [String] {
        try Task.checkCancellation()
        try await translation()
        var unavailable: [String] = []
        for language in source == target ? [source] : [source, target] {
            try Task.checkCancellation()
            guard let asset = await speechAsset(language) else {
                unavailable.append(language)
                continue
            }
            try Task.checkCancellation()
            if !(await asset.isInstalled()) {
                try Task.checkCancellation()
                try await asset.install()
            }
            try Task.checkCancellation()
            guard await asset.isInstalled() else { throw PreparationError.notInstalled(language) }
        }
        try Task.checkCancellation()
        return unavailable
    }

    private enum PreparationError: LocalizedError {
        case notInstalled(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let language):
                "\(AppLanguage.name(language))语音资源尚未安装完成，请稍后重试"
            }
        }
    }
}
