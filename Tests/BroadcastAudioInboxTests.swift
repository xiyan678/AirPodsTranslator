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
        inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"])
        XCTAssertEqual(received, samples)
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
        inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"], "尾部音频只能交付一次")
    }

    func testPausedConsumerRetainsEndingAudioUntilResume() throws {
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
        XCTAssertTrue(inbox.active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
        inbox.canConsume = { true }
        inbox.poll()
        XCTAssertEqual(deliveries, 1)
        inbox.poll()
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testBacklogFromFinishedBroadcastIsDeliveredAfterAppStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = BroadcastAudioInbox(directory: { directory })
        var events: [String] = []
        var received: [Float] = []
        var ready = false
        inbox.canConsume = { ready }
        inbox.onActiveChange = { events.append($0 ? "start" : "end") }
        inbox.onSamples = { received.append(contentsOf: $0); events.append("audio") }
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        let samples: [Float] = [0.1, 0.2, 0.3]
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        inbox.poll()
        XCTAssertEqual(events, ["start"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
        ready = true
        inbox.poll()
        inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"])
        XCTAssertEqual(received, samples)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testCorruptBacklogReportsErrorAndDoesNotBlockFollowingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let damaged = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        let valid = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000002.pcm")
        try Data([1, 2, 3]).write(to: damaged)
        let samples: [Float] = [0.1, 0.2]
        try samples.withUnsafeBytes { Data($0) }.write(to: valid)
        let inbox = BroadcastAudioInbox(directory: { directory })
        var errors: [String] = []
        var received: [Float] = []
        inbox.canConsume = { true }
        inbox.onError = { errors.append($0) }
        inbox.onSamples = { received.append(contentsOf: $0) }
        inbox.poll()
        inbox.poll()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(received, samples)
        XCTAssertFalse(inbox.active)
    }
}
