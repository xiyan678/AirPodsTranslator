import XCTest
@testable import AirPodsTranslator

final class LocalWhisperModelTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func createModel(_ folder: URL, complete: Bool = true) throws {
        for name in complete ? ["MelSpectrogram", "AudioEncoder", "TextDecoder"] : ["AudioEncoder"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name + ".mlmodelc"),
                                                    withIntermediateDirectories: true)
        }
    }

    func testRestartFindsModelRelativeToNewAppContainerWithoutNetwork() throws {
        try withHome { home in
            let path = "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"
            let folder = home.appendingPathComponent(path)
            try createModel(folder)
            let oldHome = URL(fileURLWithPath: "/previous/container")
            let saved = LocalWhisperModel.relativePath(of: oldHome.appendingPathComponent(path), home: oldHome)
            XCTAssertEqual(saved, path)
            XCTAssertEqual(LocalWhisperModel.find(home: home, relativePath: saved)?.path, folder.path)
        }
    }

    func testDiscoversLegacyCacheAndSkipsEnglishOnlyAndIncompleteDownloads() throws {
        try withHome { home in
            let root = home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            try createModel(root.appendingPathComponent("openai_whisper-base.en"))
            try createModel(root.appendingPathComponent("openai_whisper-base-incomplete"), complete: false)
            XCTAssertNil(LocalWhisperModel.find(home: home, relativePath: nil))
            let folder = root.appendingPathComponent("openai_whisper-base")
            try createModel(folder)
            XCTAssertEqual(LocalWhisperModel.find(home: home, relativePath: "Documents/deleted")?.path, folder.path)
        }
    }

    func testRejectsSavedPathsOutsideContainer() throws {
        try withHome { home in
            XCTAssertNil(LocalWhisperModel.relativePath(of: home.deletingLastPathComponent(), home: home))
            XCTAssertNil(LocalWhisperModel.find(home: home, relativePath: "../another-app"))
        }
    }
}
