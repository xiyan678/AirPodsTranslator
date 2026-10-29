import XCTest
@testable import AirPodsTranslator

@MainActor
final class SherpaSpeechTests: XCTestCase {
    func testLegacyAutomaticSourceMigratesToAnExplicitDifferentLanguage() {
        XCTAssertEqual(Preferences.manualSource("auto", target: "zh"), "en")
        XCTAssertEqual(Preferences.manualSource(nil, target: "en"), "zh")
        XCTAssertEqual(Preferences.manualSource("ja", target: "zh"), "ja")
        XCTAssertEqual(Preferences.manualSource("zh", target: "zh"), "en")
        XCTAssertEqual(Preferences.manualSource("invalid", target: "zh"), "en")
    }
    func testBilingualRoutingKeepsOtherLanguagesOnTheirExistingEngine() {
        XCTAssertFalse(SherpaSpeech.supports(nil), "自动模式必须先检测语言，不能直接交给双语模型")
        XCTAssertTrue(SherpaSpeech.supports("en"))
        XCTAssertTrue(SherpaSpeech.supports("zh"))
        for language in ["ja", "de", "fr", "pt", "ko"] {
            XCTAssertFalse(SherpaSpeech.supports(language))
        }
    }
}
