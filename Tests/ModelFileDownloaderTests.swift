import Foundation
import XCTest
@testable import AirPodsTranslator

@MainActor
final class ModelFileDownloaderTests: XCTestCase {
    func testSameLengthCorruptionFailsContentVerification() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("abc".utf8).write(to: path)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let valid = try await ModelFileChecksum.matches(path, expected: expected)
        XCTAssertTrue(valid)
        try Data("xyz".utf8).write(to: path)
        let corrupted = try await ModelFileChecksum.matches(path, expected: expected)
        XCTAssertFalse(corrupted, "同样大小的文件也必须校验内容")
    }
    private let url = URL(string: "https://example.com/model.onnx")!

    private func fixture(_ size: Int) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: size).write(to: path)
        return path
    }

    func testLostConnectionRetriesAndUsesResumeDataBeforeSucceeding() async throws {
        let path = try fixture(8)
        defer { try? FileManager.default.removeItem(at: path) }
        var calls = 0
        var retries: [Int] = []
        let resume = Data([1, 2])
        let downloader = ModelFileDownloader(download: { url, data in
            calls += 1
            if calls == 1 {
                XCTAssertNil(data)
                throw NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
                              userInfo: ["NSURLSessionDownloadTaskResumeData": resume])
            }
            XCTAssertEqual(data, resume)
            return (path, HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        }, delay: { _ in })
        let result = try await downloader.fetch(url, expectedSize: 8) { retries.append($0) }
        XCTAssertEqual(result, path)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(retries, [2])
    }

    func testRepeatedFailureStopsAfterThreeAttempts() async {
        var calls = 0
        let downloader = ModelFileDownloader(download: { _, _ in
            calls += 1
            throw URLError(.networkConnectionLost)
        }, delay: { _ in })
        do {
            _ = try await downloader.fetch(url, expectedSize: 8) { _ in }
            XCTFail("持续断线不能报告下载成功")
        } catch { XCTAssertEqual(calls, 3) }
    }

    func testCancellationDoesNotRetry() async {
        var calls = 0
        let downloader = ModelFileDownloader(download: { _, _ in
            calls += 1
            throw URLError(.cancelled)
        }, delay: { _ in XCTFail("取消不能继续等待重试") })
        do {
            _ = try await downloader.fetch(url, expectedSize: 8) { _ in XCTFail("取消不能重试") }
            XCTFail("应返回取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testIncompleteResponseIsRemovedAndNotAcceptedAsAnInstalledModel() async throws {
        var paths: [URL] = []
        defer { for path in paths { try? FileManager.default.removeItem(at: path) } }
        let downloader = ModelFileDownloader(download: { url, _ in
            let path = try self.fixture(2)
            paths.append(path)
            return (path, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, delay: { _ in })
        do {
            _ = try await downloader.fetch(url, expectedSize: 8) { _ in }
            XCTFail("残缺文件不能报告成功")
        } catch { }
        XCTAssertEqual(paths.count, 3)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
