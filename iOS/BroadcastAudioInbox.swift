import Foundation
import ReplayKit
import SwiftUI

@MainActor
final class BroadcastAudioInbox {
    var onActiveChange: ((Bool) -> Void)?
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?
    var canConsume: (() -> Bool)?
    private(set) var active = false
    private let files: BroadcastAudioFiles
    private var polling = false
    // A delivered chunk remains acknowledged while its deletion is retried.
    private var deliveredFile: URL?

    init(directory: @escaping @Sendable () -> URL? = { BroadcastStorage.directory }) {
        files = BroadcastAudioFiles(directory: directory)
    }

    func poll() async {
        // Slow storage must not accumulate overlapping polls or duplicate delivery.
        guard !polling else { return }
        polling = true
        defer { polling = false }
        guard await removeDeliveredFile(), let snapshot = await files.scan() else { return }
        let nowActive = (snapshot.modified.map { Date().timeIntervalSince($0) < 5 } ?? false) || !snapshot.chunks.isEmpty
        let ending = active && !nowActive
        // The extension writes its tail before removing the marker. Deliver it
        // while capture is still running, then let the controller end/save.
        defer {
            if ending { active = false; onActiveChange?(false) }
        }
        if nowActive != active, !ending {
            active = nowActive
            onActiveChange?(nowActive)
        }
        guard canConsume?() == true || !active else { return }
        // Catch up with a backlog in bounded batches, yielding between deliveries.
        for url in snapshot.chunks.prefix(4) {
            guard canConsume?() == true else { return }
            let chunk = await files.read(url)
            // Pausing can run while disk I/O is in progress. Leave unread audio on disk.
            guard canConsume?() == true else { return }
            switch chunk {
            case .unavailable: return
            case .corrupt:
                deliveredFile = url
                onError?("屏幕音频缓存已损坏，无法识别该片段")
            case .samples(let samples):
                deliveredFile = url
                onSamples?(samples)
            }
            guard await removeDeliveredFile() else { return }
        }
    }

    private func removeDeliveredFile() async -> Bool {
        guard let deliveredFile else { return true }
        if let message = await files.remove(deliveredFile) {
            onError?(message)
            return false
        }
        self.deliveredFile = nil
        return true
    }
}

/// Directory lookup, scanning and PCM file operations stay off the UI actor.
private actor BroadcastAudioFiles {
    struct Snapshot: Sendable {
        let modified: Date?
        let chunks: [URL]
    }
    enum Chunk: Sendable {
        case unavailable, corrupt, samples([Float])
    }
    private let resolveDirectory: @Sendable () -> URL?
    // App Group entitlement does not change while this process is running.
    private lazy var directory = resolveDirectory()

    init(directory: @escaping @Sendable () -> URL?) { resolveDirectory = directory }

    func scan() -> Snapshot? {
        guard let directory else { return nil }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return Snapshot(modified: nil, chunks: [])
        }
        // A transient scan failure must not falsely end an active broadcast.
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) else { return nil }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        let modified = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let chunks = entries
            .filter { $0.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) && $0.pathExtension == "pcm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Snapshot(modified: modified, chunks: chunks)
    }

    func read(_ url: URL) -> Chunk {
        guard let data = try? Data(contentsOf: url) else { return .unavailable }
        guard !data.isEmpty, data.count.isMultiple(of: 4) else { return .corrupt }
        var samples = [Float](repeating: 0, count: data.count / 4)
        samples.withUnsafeMutableBytes { bytes in bytes.copyBytes(from: data) }
        return samples.allSatisfy(\.isFinite) ? .samples(samples) : .corrupt
    }

    func remove(_ url: URL) -> String? {
        do { try FileManager.default.removeItem(at: url); return nil }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { return nil }
            return "屏幕音频缓存无法清理：\(error.localizedDescription)"
        }
    }
}

struct ScreenBroadcastControl: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = BroadcastStorage.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
            button.setImage(UIImage(systemName: "rectangle.on.rectangle"), for: .normal)
            button.tintColor = .white
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { }
}
