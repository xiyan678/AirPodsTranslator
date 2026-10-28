import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit
import os

/// Live subtitle frames, without a silent audio track or a remote video URL.
@MainActor
final class SubtitlePictureInPicture: NSObject, ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var active = false
    var onPlaybackChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private var controller: AVPictureInPictureController?
    private weak var layer: AVSampleBufferDisplayLayer?
    private var possibleObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var startTimeout: Task<Void, Never>?
    private var wantsStart = false
    private var original = "等待识别语音…"
    private var translation = ""
    private nonisolated let pausedState = OSAllocatedUnfairLock(initialState: false)

    func start() {
        guard !enabled else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onError?("当前设备不支持画中画")
            return
        }
        enabled = true
        wantsStart = true
        startIfPossible()
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.enabled, !self.active else { return }
            self.stop()
            self.onError?("画中画暂时无法启动，请保持同传运行后重试。")
        }
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard self.layer !== layer else { return }
        self.layer = layer
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                          timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.startIfPossible() }
        }
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    func update(original: String, translation: String) {
        self.original = original.isEmpty ? "等待识别语音…" : original
        self.translation = translation
        if enabled { render() }
    }

    func setPaused(_ paused: Bool) {
        pausedState.withLock { $0 = paused }
        controller?.invalidatePlaybackState()
        if enabled { render() }
    }

    func stop() {
        wantsStart = false
        startTimeout?.cancel()
        startTimeout = nil
        controller?.stopPictureInPicture()
        // Keep the source view alive until the system completes its closing animation.
        if !active { tearDown() }
    }

    private func tearDown() {
        wantsStart = false
        startTimeout?.cancel()
        startTimeout = nil
        timer?.invalidate()
        timer = nil
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        layer?.flushAndRemoveImage()
        layer = nil
        active = false
        enabled = false
    }

    private func startIfPossible() {
        guard wantsStart, let controller, controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        wantsStart = false
        controller.startPictureInPicture()
    }

    /// 字幕放不下时保留最新的内容。原来按尾部截断，长句只显示开头，
    /// 正在说的部分反而被省略号盖掉。
    private static func latestPart(of text: String, fitting size: CGSize,
                                   attributes: [NSAttributedString.Key: Any]) -> String {
        // 截断模式下测出来只有一行高，测量时改用自动换行。
        var measuring = attributes
        if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byWordWrapping
            measuring[.paragraphStyle] = style
        }
        func fits(_ value: String) -> Bool {
            let height = (value as NSString).boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: measuring, context: nil).height
            return height <= size.height
        }
        guard !fits(text) else { return text }
        let characters = Array(text)
        var low = 1, high = characters.count  // 从第 low 个字符起保留，找到能放下的最小起点
        while low < high {
            let middle = (low + high) / 2
            if fits("…" + String(characters[middle...])) { high = middle } else { low = middle + 1 }
        }
        return low < characters.count ? "…" + String(characters[low...]) : ""
    }

    private func render() {
        guard let layer else { return }
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        let size = CGSize(width: 960, height: 540)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.lineSpacing = 9
            func draw(_ text: String, rect: CGRect, size: CGFloat, color: UIColor) {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .medium),
                    .foregroundColor: color, .paragraphStyle: paragraph]
                (Self.latestPart(of: text, fitting: rect.size, attributes: attributes) as NSString)
                    .draw(in: rect, withAttributes: attributes)
            }
            draw(pausedState.withLock { $0 } ? "声译 · 已暂停" : "声译 · 实时翻译",
                 rect: CGRect(x: 40, y: 28, width: 880, height: 38), size: 25, color: .lightGray)
            draw(original, rect: CGRect(x: 40, y: 95, width: 880, height: 165), size: 35, color: .lightGray)
            draw(translation.isEmpty ? "正在等待译文…" : translation,
                 rect: CGRect(x: 40, y: 285, width: 880, height: 220), size: 43,
                 color: UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1))
        }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 960, 540, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 540,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.translateBy(x: 0, y: 540)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &description) == noErr, let description else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }
}

extension SubtitlePictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === pictureInPictureController else { return }
            self.active = true
            self.startTimeout?.cancel()
            self.startTimeout = nil
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === pictureInPictureController else { return }
            self.tearDown()
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                              failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            guard self.controller === pictureInPictureController else { return }
            self.tearDown()
            self.onError?("画中画启动失败，请保持同传运行后重试。")
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension SubtitlePictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            guard self.controller === pictureInPictureController else { return }
            self.onPlaybackChange?(playing)
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        pausedState.withLock { $0 }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                               didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}

private final class SubtitleVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var onReady: ((AVSampleBufferDisplayLayer) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, let layer = layer as? AVSampleBufferDisplayLayer { onReady?(layer) }
    }
}

private struct SubtitleVideoSource: UIViewRepresentable {
    let manager: SubtitlePictureInPicture
    func makeUIView(context: Context) -> SubtitleVideoView {
        let view = SubtitleVideoView()
        view.onReady = { [weak manager] in manager?.attach($0) }
        (view.layer as? AVSampleBufferDisplayLayer)?.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: SubtitleVideoView, context: Context) {}
}

struct SubtitlePictureInPicturePanel: View {
    @ObservedObject var manager: SubtitlePictureInPicture
    var body: some View {
        if manager.enabled {
            HStack {
                Spacer()
                SubtitleVideoSource(manager: manager)
                    .frame(width: 224, height: 126).clipShape(RoundedRectangle(cornerRadius: 12))
                Button { manager.stop() } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("关闭画中画")
                Spacer()
            }.padding(.vertical, 6)
        }
    }
}
