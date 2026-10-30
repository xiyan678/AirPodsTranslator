import XCTest

final class PageCaptureTests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(fixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if fixture { app.launchArguments.append("--ui-review-fixture") }
        app.launch()
        return app
    }

    func testCaptureAllMainPages() {
        let app = launch()
        XCTAssertTrue(app.buttons["实时同传"].waitForExistence(timeout: 10))
        capture("01-同传首页", app: app)
        app.buttons["实时同传"].tap()
        app.buttons["文本翻译"].tap()
        XCTAssertTrue(app.navigationBars["文本翻译"].waitForExistence(timeout: 5))
        capture("02-文本翻译", app: app)
        app.buttons["完成"].tap()
        app.buttons["实时同传"].tap()
        app.buttons["图片翻译"].tap()
        XCTAssertTrue(app.navigationBars["拍照翻译"].waitForExistence(timeout: 5))
        capture("03-图片翻译", app: app)
        app.buttons["完成"].tap()
        app.buttons["对话"].tap()
        XCTAssertTrue(app.buttons["说中文"].waitForExistence(timeout: 5))
        capture("04-双语语音对话", app: app)
        app.buttons["键盘"].tap()
        let input = app.textFields["输入文字，自动识别语言"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Hello")
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.exists && keyboardIntroduction.isHittable { keyboardIntroduction.tap() }
        capture("05-键盘翻译", app: app)
        app.buttons["语音"].tap()
        app.buttons["历史"].tap()
        capture("06-历史记录空状态", app: app)
        app.buttons["设置"].tap()
        capture("07-设置上半页", app: app)
        app.buttons["离线语言包"].tap()
        XCTAssertTrue(app.navigationBars["离线语言包"].waitForExistence(timeout: 5))
        capture("08-离线语言包", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        capture("09-设置下半页及AI总结", app: app)
        app.swipeUp()
        capture("10-设置关于", app: app)
        app.buttons["使用条款"].tap()
        XCTAssertTrue(app.navigationBars["使用条款"].waitForExistence(timeout: 5))
        capture("11-使用条款", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["隐私政策"].tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 5))
        capture("12-隐私政策", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let pro = app.buttons["查看月度与年度订阅"]
        if !pro.isHittable { app.swipeDown() }
        XCTAssertTrue(pro.isHittable)
        pro.tap()
        XCTAssertTrue(app.navigationBars["声译 Pro"].waitForExistence(timeout: 10))
        capture("13-Pro订阅", app: app)
    }

    func testCaptureTranscriptAndHistory() {
        let app = launch(fixture: true)
        let original = app.staticTexts["The meeting starts at nine tomorrow morning."]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        capture("14-同传内容-示例数据", app: app)
        app.buttons["实时同传"].tap()
        app.buttons["AI 总结"].tap()
        XCTAssertTrue(app.staticTexts["实时总结"].waitForExistence(timeout: 5))
        capture("15-AI总结", app: app)
        app.buttons["关闭"].tap()
        app.staticTexts["好的，我会提前准备好资料。"].press(forDuration: 1)
        app.buttons["修改并重译"].tap()
        XCTAssertTrue(app.navigationBars["修改上一句"].waitForExistence(timeout: 5))
        capture("16-修改并重译", app: app)
        app.buttons["取消"].tap()
        app.buttons["历史"].tap()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        capture("17-历史记录-示例数据", app: app)
        app.buttons["编辑"].tap()
        capture("18-历史编辑", app: app)
        app.buttons["完成"].tap()
        app.cells.element(boundBy: 0).tap()
        capture("19-历史详情-示例数据", app: app)
    }

    func testHistoryDoneButtonRemainsAfterDeletingAllRecords() {
        let app = launch(fixture: true)
        app.buttons["历史"].tap()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.buttons["编辑"].tap()
        let count = app.cells.count
        XCTAssertGreaterThan(count, 0)
        for index in 0..<count { app.cells.element(boundBy: index).tap() }
        app.buttons["删除所选（\(count)）"].tap()
        XCTAssertTrue(app.buttons["撤销删除"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["完成"].exists)
        app.buttons["完成"].tap()
        XCTAssertFalse(app.buttons["完成"].exists)
    }
}
