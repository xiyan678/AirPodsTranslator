import Foundation

enum BroadcastStorage {
    // 替换为你在 Apple Developer 创建的 App Group ID 和广播扩展 Bundle ID
    static let groupID = "group.com.example.AirPodsTranslator.shared"  // 例如 group.com.yourcompany.AirPodsTranslator.shared
    static let extensionBundleID = "com.example.AirPodsTranslator.broadcast"  // 例如 com.yourcompany.AirPodsTranslator.broadcast
    static let activeFile = "broadcast-active"
    static let chunkPrefix = "audio-"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("BroadcastAudio", isDirectory: true)
    }
}
