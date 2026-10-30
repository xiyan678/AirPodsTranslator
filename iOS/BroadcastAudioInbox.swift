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
    private let directory: () -> URL?

    init(directory: @escaping () -> URL? = { BroadcastStorage.directory }) {
        self.directory = directory
    }

    func poll() {
        guard let directory = directory() else { return }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        let modified = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let chunks = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) && $0.pathExtension == "pcm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let nowActive = (modified.map { Date().timeIntervalSince($0) < 5 } ?? false) || !chunks.isEmpty
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
        for url in chunks {
            guard let data = try? Data(contentsOf: url) else { return }
            guard !data.isEmpty, data.count.isMultiple(of: 4) else {
                onError?("屏幕音频缓存已损坏，无法识别该片段")
                do { try FileManager.default.removeItem(at: url) }
                catch { return }
                continue
            }
            do { try FileManager.default.removeItem(at: url) }
            catch { onError?("屏幕音频缓存无法清理：\(error.localizedDescription)"); return }
            var samples = [Float](repeating: 0, count: data.count / 4)
            samples.withUnsafeMutableBytes { bytes in bytes.copyBytes(from: data) }
            onSamples?(samples)
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
