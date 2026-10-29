import XCTest
@testable import AirPodsTranslator

@MainActor
final class SherpaSpeechTests: XCTestCase {
    func testBilingualRoutingKeepsOtherLanguagesOnTheirExistingEngine() {
        XCTAssertFalse(SherpaSpeech.supports(nil), "自动模式必须先检测语言，不能直接交给双语模型")
        XCTAssertTrue(SherpaSpeech.supports("en"))
        XCTAssertTrue(SherpaSpeech.supports("zh"))
        for language in ["ja", "de", "fr", "pt", "ko"] {
            XCTAssertFalse(SherpaSpeech.supports(language))
        }
    }
}
