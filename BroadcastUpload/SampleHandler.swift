import AVFoundation
import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var pending: [Float] = []
    private var sequence = 0
    private var lastHeartbeat = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        guard let directory = BroadcastStorage.directory else {
            finishBroadcastWithError(NSError(domain: "EarTranslation", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "请先启用 App Group 后重试"]))
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in old where url.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
        setActive(true)
    }

    override func broadcastPaused() { setActive(false) }
    override func broadcastResumed() { setActive(true) }
    override func broadcastFinished() {
        setActive(false)
        pending.removeAll()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if Date().timeIntervalSince(lastHeartbeat) > 2 {
            setActive(true)
            lastHeartbeat = Date()
        }
        guard sampleBufferType == .audioApp,
              let inputDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(inputDescription),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return }
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

    private func flushChunks() {
        guard let directory = BroadcastStorage.directory else { return }
        while pending.count >= 16_000 {
            let samples = Array(pending.prefix(16_000))
            pending.removeFirst(16_000)
            let data = samples.withUnsafeBytes { Data($0) }
            let name = String(format: "%020d", sequence)
            sequence += 1
            try? data.write(to: directory.appendingPathComponent(BroadcastStorage.chunkPrefix + name + ".pcm"),
                            options: .atomic)
        }
        let chunks = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(BroadcastStorage.chunkPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in chunks.dropLast(60) { try? FileManager.default.removeItem(at: url) }
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
