import Foundation

/// Reuse the on-disk model before calling the SDK's network-backed download API.
enum LocalWhisperModel {
    static func find(home: URL, relativePath: String?, manager: FileManager = .default) -> URL? {
        if let relativePath, !relativePath.hasPrefix("/"),
           !relativePath.split(separator: "/").contains("..") {
            let folder = home.appendingPathComponent(relativePath)
            if containsModels(folder, manager: manager) { return folder }
        }
        // Older versions did not store the path. Discover their existing Hub cache once.
        for name in ["Documents", "Library/Caches", "Library/Application Support"] {
            guard let entries = manager.enumerator(at: home.appendingPathComponent(name),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let folder as URL in entries {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if ["mlmodelc", "mlpackage"].contains(folder.pathExtension) {
                    entries.skipDescendants()
                    continue
                }
                if folder.lastPathComponent.hasPrefix("openai_whisper-base"),
                   !folder.lastPathComponent.contains("base.en"), containsModels(folder, manager: manager) {
                    return folder
                }
            }
        }
        return nil
    }

    static func relativePath(of folder: URL, home: URL) -> String? {
        let prefix = home.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func containsModels(_ folder: URL, manager: FileManager) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { suffix in
                var directory: ObjCBool = false
                let path = folder.appendingPathComponent("\(name).\(suffix)").path
                return manager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            }
        }
    }
}
