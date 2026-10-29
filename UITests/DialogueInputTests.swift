import XCTest

final class DialogueInputTests: XCTestCase {
    private func assertSpeechControlsAboveNavigation(_ app: XCUIApplication,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        let navigation = app.buttons["main-tab-1"]
        XCTAssertTrue(navigation.exists, file: file, line: line)
        for title in ["说中文", "说英语"] {
            let button = app.buttons[title]
            XCTAssertGreaterThan(button.frame.height, 40, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxY, navigation.frame.minY,
                                     "\(title)不能被底部导航遮住", file: file, line: line)
        }
    }

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
        assertSpeechControlsAboveNavigation(app)

        app.buttons["键盘"].tap()
        let input = app.textFields["输入文字，自动识别语言"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("hello")
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.exists && keyboardIntroduction.isHittable { keyboardIntroduction.tap() }
        XCTAssertFalse(chinese.exists, "文字输入模式只显示键盘输入控件")
        XCTAssertFalse(english.exists)
        XCTAssertTrue(app.staticTexts["开始一段对话"].exists)
        XCTAssertTrue(app.staticTexts["输入任一语言，自动识别并翻译成另一种语言。"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY,
                                 "输入框应完整显示在系统键盘上方")
        let keyboardShot = XCTAttachment(screenshot: app.screenshot())
        keyboardShot.name = "对话页-键盘文字翻译"
        keyboardShot.lifetime = .keepAlways
        add(keyboardShot)

        app.buttons["语音"].tap()
        XCTAssertFalse(input.exists)
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        assertSpeechControlsAboveNavigation(app)
        app.buttons["键盘"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "hello", "切换语音不能丢失文字草稿")
        app.buttons["语音"].tap()
        app.buttons["历史"].tap()
        app.buttons["对话"].tap()
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        assertSpeechControlsAboveNavigation(app)
        XCTAssertFalse(input.exists)
        let speechShot = XCTAttachment(screenshot: app.screenshot())
        speechShot.name = "对话页-中文和英语语音入口"
        speechShot.lifetime = .keepAlways
        add(speechShot)
    }
}
