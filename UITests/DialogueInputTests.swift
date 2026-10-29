import XCTest

final class DialogueInputTests: XCTestCase {
    func testDialogueDefaultsToSpeechAndKeyboardSwitchesBack() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["对话"].tap()
        let chinese = app.buttons["说中文"]
        let english = app.buttons["说英语"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 10))
        XCTAssertTrue(english.exists)
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)

        app.buttons["键盘"].tap()
        let input = app.textFields["输入文字，自动识别语言"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("hello")
        XCTAssertFalse(chinese.exists, "文字输入模式只显示键盘输入控件")
        XCTAssertFalse(english.exists)
        let keyboardShot = XCTAttachment(screenshot: app.screenshot())
        keyboardShot.name = "对话页-键盘文字翻译"
        keyboardShot.lifetime = .keepAlways
        add(keyboardShot)

        app.buttons["语音"].tap()
        XCTAssertFalse(input.exists)
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        app.buttons["键盘"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "hello", "切换语音不能丢失文字草稿")
        app.buttons["语音"].tap()
        app.buttons["历史"].tap()
        app.buttons["对话"].tap()
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        XCTAssertFalse(input.exists)
        let speechShot = XCTAttachment(screenshot: app.screenshot())
        speechShot.name = "对话页-中文和英语语音入口"
        speechShot.lifetime = .keepAlways
        add(speechShot)
    }
}
