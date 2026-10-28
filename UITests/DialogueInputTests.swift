import XCTest

final class DialogueInputTests: XCTestCase {
    func testSpeechButtonsRemainAvailableWhileUsingKeyboard() {
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
        XCTAssertTrue(chinese.exists, "键盘输入不能移除中文语音入口")
        XCTAssertTrue(english.exists, "键盘输入不能移除英语语音入口")
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        let keyboardShot = XCTAttachment(screenshot: app.screenshot())
        keyboardShot.name = "对话页-展开键盘仍保留双语麦克风"
        keyboardShot.lifetime = .keepAlways
        add(keyboardShot)

        app.buttons["收起键盘"].tap()
        XCTAssertFalse(input.exists)
        XCTAssertTrue(chinese.isHittable)
        XCTAssertTrue(english.isHittable)
        let speechShot = XCTAttachment(screenshot: app.screenshot())
        speechShot.name = "对话页-中文和英语语音入口"
        speechShot.lifetime = .keepAlways
        add(speechShot)
    }
}
