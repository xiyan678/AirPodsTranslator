import XCTest

final class VoiceSettingsTests: XCTestCase {
    func testSettingsHasInvitationAndRedemptionAndNoVoicePicker() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["main-tab-3"].tap()
        let invite = app.buttons["subscription-invite"]
        for _ in 0..<8 {
            if invite.isHittable { break }
            app.swipeUp()
        }
        XCTAssertFalse(app.buttons["目标语言声音"].exists)
        XCTAssertTrue(app.buttons["subscription-redeem"].exists)
        XCTAssertTrue(invite.isHittable)
        invite.tap()
        XCTAssertTrue(app.staticTexts["邀请好友，双方获益"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["referral-code-input"].exists)
        XCTAssertFalse(app.buttons["referral-activate"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "设置-邀请好友"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
