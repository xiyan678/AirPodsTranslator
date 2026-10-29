import XCTest

final class VoiceSettingsTests: XCTestCase {
    func testTargetVoiceSettingsOpensAndCanRestoreSystemVoice() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["设置"].tap()
        let link = app.buttons["目标语言声音"]
        for _ in 0..<5 {
            if link.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(link.isHittable)
        link.tap()
        let systemVoice = app.buttons["voice-system-default"]
        XCTAssertTrue(systemVoice.waitForExistence(timeout: 5))
        systemVoice.tap()
        XCTAssertTrue(app.navigationBars["目标语言声音"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "设置-目标语言声音"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
