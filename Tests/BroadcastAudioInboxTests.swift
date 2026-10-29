import XCTest
@testable import AirPodsTranslator

@MainActor
final class BroadcastAudioInboxTests: XCTestCase {
    func testFinalAudioArrivesBeforeBroadcastEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        try Data().write(to: marker)
        let inbox = BroadcastAudioInbox(directory: { directory })
        var events: [String] = []
        var received: [Float] = []
        inbox.canConsume = { true }
        inbox.onActiveChange = { events.append($0 ? "start" : "end") }
        inbox.onSamples = { received.append(contentsOf: $0); events.append("audio") }
        inbox.poll()
        let samples: [Float] = [0.1, 0.2, 0.3]
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        try FileManager.default.removeItem(at: marker)
        inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"])
        XCTAssertEqual(received, samples)
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
        inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"], "尾部音频只能交付一次")
    }

    func testPausedConsumerDoesNotReceiveEndingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        try Data().write(to: marker)
        let inbox = BroadcastAudioInbox(directory: { directory })
        inbox.canConsume = { false }
        var deliveries = 0
        inbox.onSamples = { _ in deliveries += 1 }
        inbox.poll()
        let samples: [Float] = [0.2]
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        try FileManager.default.removeItem(at: marker)
        inbox.poll()
        inbox.poll()
        XCTAssertEqual(deliveries, 0)
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }
}
