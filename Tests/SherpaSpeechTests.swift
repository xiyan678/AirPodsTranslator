import XCTest
@testable import AirPodsTranslator

@MainActor
final class SherpaSpeechTests: XCTestCase {
    func testBilingualRoutingKeepsOtherLanguagesOnTheirExistingEngine() {
        XCTAssertTrue(SherpaSpeech.supports(nil))
        XCTAssertTrue(SherpaSpeech.supports("en"))
        XCTAssertTrue(SherpaSpeech.supports("zh"))
        for language in ["ja", "de", "fr", "pt", "ko"] {
            XCTAssertFalse(SherpaSpeech.supports(language))
        }
    }
}
