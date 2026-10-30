import XCTest
import os
@testable import AirPodsTranslator

@MainActor
final class BroadcastAudioInboxTests: XCTestCase {
    func testUnavailableDirectoryIsResolvedOffMainThreadOnlyOnce() async {
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let inbox = BroadcastAudioInbox(directory: {
            XCTAssertFalse(Thread.isMainThread, "App Group 查询不能阻塞界面线程")
            lookups.withLock { $0 += 1 }
            return nil
        })
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(lookups.withLock { $0 }, 1, "没有共享目录权限时不能持续重复查询")
    }

    func testBacklogIsDeliveredInBoundedOrderedBatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<10 {
            let samples = [Float(index)]
            let name = String(format: "%06d", index)
            try samples.withUnsafeBytes { Data($0) }.write(to:
                directory.appendingPathComponent(BroadcastStorage.chunkPrefix + name + ".pcm"))
        }
        let inbox = BroadcastAudioInbox(directory: { directory })
        var received: [Float] = []
        inbox.canConsume = { true }
        inbox.onSamples = { received.append(contentsOf: $0) }
        await inbox.poll()
        XCTAssertEqual(received, [0, 1, 2, 3], "一次轮询不能把全部积压音频集中送到主线程")
        XCTAssertTrue(inbox.active)
        await inbox.poll()
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(received, (0..<10).map { Float($0) })
        XCTAssertFalse(inbox.active)
    }

    func testOverlappingPollsDoNotDeliverTheSameChunkTwice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [Float] = [0.1, 0.2]
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        let inbox = BroadcastAudioInbox(directory: { directory })
        var received: [Float] = []
        inbox.canConsume = { true }
        inbox.onSamples = { received.append(contentsOf: $0) }
        async let first: Void = inbox.poll()
        async let second: Void = inbox.poll()
        _ = await (first, second)
        XCTAssertEqual(received, samples)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testFinalAudioArrivesBeforeBroadcastEnd() async throws {
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
        await inbox.poll()
        let samples: [Float] = [0.1, 0.2, 0.3]
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        try FileManager.default.removeItem(at: marker)
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"])
        XCTAssertEqual(received, samples)
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
        await inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"], "尾部音频只能交付一次")
    }

    func testPausedConsumerRetainsEndingAudioUntilResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(BroadcastStorage.activeFile)
        try Data().write(to: marker)
        let inbox = BroadcastAudioInbox(directory: { directory })
        inbox.canConsume = { false }
        var deliveries = 0
        inbox.onSamples = { _ in deliveries += 1 }
        await inbox.poll()
        let samples: [Float] = [0.2]
        let chunk = directory.appendingPathComponent(BroadcastStorage.chunkPrefix + "000001.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: chunk)
        try FileManager.default.removeItem(at: marker)
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(inbox.active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
        inbox.canConsume = { true }
        await inbox.poll()
        XCTAssertEqual(deliveries, 1)
        await inbox.poll()
        XCTAssertFalse(inbox.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testBacklogFromFinishedBroadcastIsDeliveredAfterAppStarts() async throws {
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
        await inbox.poll()
        XCTAssertEqual(events, ["start"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
        ready = true
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(events, ["start", "audio", "end"])
        XCTAssertEqual(received, samples)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testCorruptBacklogReportsErrorAndDoesNotBlockFollowingAudio() async throws {
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
        await inbox.poll()
        await inbox.poll()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(received, samples)
        XCTAssertFalse(inbox.active)
    }
}
