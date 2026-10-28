import Foundation

enum BroadcastStorage {
    static let groupID = "group.com.example.AirPodsTranslator.shared"
    static let extensionBundleID = "com.example.AirPodsTranslator.broadcast"
    static let activeFile = "broadcast-active"
    static let chunkPrefix = "audio-"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("BroadcastAudio", isDirectory: true)
    }
}
