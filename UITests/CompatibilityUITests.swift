import XCTest

final class CompatibilityUITests: XCTestCase {
    @MainActor func testUnifiedNavigationCardsAndActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        for title in ["漫画收藏", "漫画推荐", "下载任务"] {
            tabs.buttons[title].tap()
            let card = app.descendants(matching: .any)[title == "下载任务" ? "jobCard-10002" : "comicCard-10002"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(card.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX)
            XCTAssertGreaterThanOrEqual(card.frame.height, 92)
            capture(app, "compatibility-\(title)")
        }
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["comicSettings"].tap()
        XCTAssertTrue(app.navigationBars["已排除/隐藏"].waitForExistence(timeout: 5))
        app.navigationBars["已排除/隐藏"].buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
    }
    @MainActor func testSmallScreenSearchAndBottomNotice() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.textFields["comicSearchField"].waitForExistence(timeout: 5))
        app.textFields["comicSearchField"].typeText("#AI绘图")
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 10))
        capture(app, "compatibility-search-keyboard-dismissed")
        app.buttons["exitComicSearch"].tap()
        app.buttons["scrollToTop"].tap()
        XCTAssertTrue(app.buttons["settings"].isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

// XCTest added waitForNonExistence after the older supported toolchains.
extension XCUIElement {
    func waitForDisappearance(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
