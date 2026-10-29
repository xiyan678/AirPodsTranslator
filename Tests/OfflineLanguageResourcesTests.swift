import XCTest
@testable import AirPodsTranslator

@MainActor
final class OfflineLanguageResourcesTests: XCTestCase {
    func testDownloadPreparesSpeechForBothConversationDirectionsAfterTranslation() async throws {
        var events: [String] = []
        var installed: Set<String> = []
        let resources = OfflineLanguageResources(speechAsset: { language in
            events.append("resolve \(language)")
            return .init(isInstalled: { installed.contains(language) }, install: {
                events.append("install \(language)")
                installed.insert(language)
            })
        })
        let unavailable = try await resources.prepare(source: "en", target: "zh") {
            events.append("translation")
        }
        XCTAssertEqual(events, ["translation", "resolve en", "install en", "resolve zh", "install zh"])
        XCTAssertEqual(installed, ["en", "zh"])
        XCTAssertTrue(unavailable.isEmpty)
    }

    func testInstalledSpeechIsReusedWithoutAnotherDownload() async throws {
        var resolved: [String] = []
        let resources = OfflineLanguageResources(speechAsset: { language in
            resolved.append(language)
            return .init(isInstalled: { true }, install: { XCTFail("已安装的资源不能重复下载") })
        })
        _ = try await resources.prepare(source: "en", target: "en", translation: {})
        XCTAssertEqual(resolved, ["en"])
    }

    func testUnsupportedSpeechDoesNotHideSuccessfulTranslationPreparation() async throws {
        let resources = OfflineLanguageResources(speechAsset: { _ in nil })
        let unavailable = try await resources.prepare(source: "en", target: "zh", translation: {})
        XCTAssertEqual(unavailable, ["en", "zh"])
    }

    func testTranslationFailureNeverStartsSpeechDownload() async {
        let resources = OfflineLanguageResources(speechAsset: { _ in
            XCTFail("翻译下载已失败，不能继续启动其他下载")
            return nil
        })
        do {
            _ = try await resources.prepare(source: "en", target: "zh") { throw URLError(.notConnectedToInternet) }
            XCTFail("应保留下载错误")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testCancelledSpeechPreparationDoesNotReportReadyOrStartTheOtherLanguage() async {
        var resolved: [String] = []
        let resources = OfflineLanguageResources(speechAsset: { language in
            resolved.append(language)
            return .init(isInstalled: { false }, install: { throw CancellationError() })
        })
        do {
            _ = try await resources.prepare(source: "en", target: "zh", translation: {})
            XCTFail("取消下载不能报告就绪")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(resolved, ["en"])
    }

    func testIncompleteInstallationCannotReportReady() async {
        let resources = OfflineLanguageResources(speechAsset: { _ in
            .init(isInstalled: { false }, install: {})
        })
        do {
            _ = try await resources.prepare(source: "en", target: "zh", translation: {})
            XCTFail("系统安装调用返回但资源仍不可用时，不能报告就绪")
        } catch { }
    }
}
