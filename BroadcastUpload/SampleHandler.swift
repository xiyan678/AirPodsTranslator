import AVFoundation
import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var pending: [Float] = []
    private var sequence = 0
    private var lastHeartbeat = Date.distantPast
    private var cachedConverter: AVAudioConverter?
    private var storageFailed = false
    private static let chunkSamples = 8_000
    private static let maximumQueuedChunks = 1_200

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        storageFailed = false
        pending = []
        sequence = 0
        cachedConverter = nil
        lastHeartbeat = .distantPast
        guard let directory = BroadcastStorage.directory else {
            finishBroadcastWithError(NSError(domain: "EarTranslation", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "请先启用 App Group 后重试"]))
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        if old.contains(where: { $0.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) && $0.pathExtension == "pcm" }) {
            finishBroadcastWithError(NSError(domain: "EarTranslation", code: 3,
                                             userInfo: [NSLocalizedDescriptionKey: "上次屏幕音频尚未处理，请先打开 App 等待处理完成。"]))
            return
        }
        setActive(true)
    }

    override func broadcastPaused() { flushChunks(includeTail: true); setActive(false) }
    override func broadcastResumed() { setActive(true) }
    override func broadcastFinished() {
        flushChunks(includeTail: true)
        setActive(false)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard !storageFailed else { return }
        if Date().timeIntervalSince(lastHeartbeat) > 2 {
            setActive(true)
            lastHeartbeat = Date()
        }
        guard sampleBufferType == .audioApp,
              let inputDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(inputDescription),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              let converter = audioConverter(for: inputFormat) else { return }
        let outputFormat = converter.outputFormat
        do {
            let samples: [Float] = try sampleBuffer.withAudioBufferList(
                flags: .audioBufferListAssure16ByteAlignment
            ) { bufferList, _ in
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                   bufferListNoCopy: bufferList.unsafePointer) else { return [] }
                input.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 /
                                                      inputFormat.sampleRate)) + 32
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, state in
                    guard !supplied else { state.pointee = .noDataNow; return nil }
                    supplied = true
                    state.pointee = .haveData
                    return input
                }
                guard conversionError == nil, output.frameLength > 0,
                      let channel = output.floatChannelData?.pointee else { return [] }
                return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            pending.append(contentsOf: samples)
            flushChunks()
        } catch { }
    }

    /// 复用同一个转换器。每个缓冲区新建转换器会丢掉重采样器内部缓存的尾部样本，
    /// 每段音频都缺一小截，长时间广播后识别的音频会断断续续。
    private func audioConverter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if let cachedConverter, cachedConverter.inputFormat == inputFormat { return cachedConverter }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        cachedConverter = converter
        return converter
    }

    private func flushChunks(includeTail: Bool = false) {
        guard !storageFailed else { return }
        // 音频缓冲区每秒到达几十次，没写新块时不必遍历目录。
        guard pending.count >= Self.chunkSamples || (includeTail && !pending.isEmpty),
              let directory = BroadcastStorage.directory else { return }
        // 每 0.5 秒写一块，缩短屏幕音频进入识别前的等待。
        while pending.count >= Self.chunkSamples || (includeTail && !pending.isEmpty) {
            let count = min(pending.count, Self.chunkSamples)
            let samples = Array(pending.prefix(count))
            let data = samples.withUnsafeBytes { Data($0) }
            let name = String(format: "%020ld", sequence)
            sequence += 1
            do {
                try data.write(to: directory.appendingPathComponent(BroadcastStorage.chunkPrefix + name + ".pcm"),
                               options: .atomic)
            } catch {
                failStorage("屏幕音频保存失败：\(error.localizedDescription)")
                return
            }
            pending.removeFirst(count)
        }
        let chunks: [URL]
        do {
            chunks = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) && $0.pathExtension == "pcm" }
        } catch {
            failStorage("屏幕音频目录无法读取：\(error.localizedDescription)")
            return
        }
        // Keep the backlog intact so a suspended App can consume it on return.
        if chunks.count >= Self.maximumQueuedChunks {
            failStorage("屏幕音频积压超过 10 分钟，已停止录制；已保存的音频不会被覆盖。")
        }
    }

    private func failStorage(_ message: String) {
        guard !storageFailed else { return }
        storageFailed = true
        setActive(false)
        finishBroadcastWithError(NSError(domain: "EarTranslation", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func setActive(_ value: Bool) {
        guard let directory = BroadcastStorage.directory else { return }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        if value {
            try? Data().write(to: marker, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
