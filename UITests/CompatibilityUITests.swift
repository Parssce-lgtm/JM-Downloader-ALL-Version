import XCTest

final class CompatibilityUITests: XCTestCase {
    @MainActor func testTopTabsDragFromUnselectedSegment() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
        let from = tabs.buttons["漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = tabs.buttons["下载任务"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.25, thenDragTo: to)
        XCTAssertTrue(tabs.buttons["下载任务"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["jobCard-10002"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "top-tabs-drag-from-unselected")
    }
    @MainActor func testUnifiedNavigationCardsAndActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(tabs.frame.height, 30)
        XCTAssertLessThanOrEqual(tabs.frame.height, 60)
        let window = app.windows.firstMatch.frame
        for title in ["漫画收藏", "漫画推荐", "下载任务"] {
            tabs.buttons[title].tap()
            let card = app.descendants(matching: .any)[title == "下载任务" ? "jobCard-10002" : "comicCard-10002"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(card.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX)
            XCTAssertGreaterThanOrEqual(card.frame.height, 91.9)
            let notice = title == "下载任务" ? app.buttons["sharedNoticeCapsule"] : app.descendants(matching: .any)["sharedNoticeCapsule"].firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 5))
            let leading = notice.frame.minX - window.minX
            let trailing = window.maxX - notice.frame.maxX
            let bottom = window.maxY - notice.frame.maxY
            XCTAssertEqual(leading, trailing, accuracy: 1.5)
            XCTAssertEqual(leading, bottom, accuracy: 1.5)
            XCTAssertGreaterThanOrEqual(bottom, 18)
            XCTAssertLessThanOrEqual(bottom, 26)
            capture(app, "compatibility-\(title)")
        }
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1.7.0 (Build 23)"].exists)
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
    @MainActor func testSearchSurvivesRefreshSwipesAndIndependentExactQueries() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons["漫画推荐"].tap()
        app.buttons["openComicSearch"].tap()
        app.textFields["comicSearchField"].typeText("AI绘图+剧情")
        app.buttons["scrollToTop"].tap()
        XCTAssertTrue(app.buttons["submitComicSearch"].exists)
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["仅含一个标签的漫画"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForDisappearance(timeout: 5))
        capture(app, "multiple-tags-before-refresh")
        // Older XCTest cannot compute the AX hit point for a SwiftUI Menu in
        // this hosting scroll view. Tap its visible frame and verify the menu opens.
        app.buttons["libraryMore-漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["刷新列表"].waitForExistence(timeout: 5))
        app.buttons["刷新列表"].tap()
        XCTAssertTrue(app.buttons["exitComicSearch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 10))
        app.scrollViews["libraryScroll-漫画推荐"].swipeDown()
        XCTAssertTrue(app.buttons["exitComicSearch"].exists)
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65))
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
        app.buttons["openComicSearch"].tap()
        app.textFields["comicSearchField"].typeText("#校园")
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["仅含一个标签的漫画"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["主动搜索的 AI 漫画"].exists)
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 5))
        app.buttons["cover-20001"].tap()
        XCTAssertTrue(app.navigationBars["封面详情"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["exitComicSearch"].waitForExistence(timeout: 5))
        capture(app, "search-preserved-multiple-exact-tags")
        let exit = app.buttons["返回推荐"]
        XCTAssertLessThan(exit.frame.width, app.windows.firstMatch.frame.width / 2)
        XCTAssertLessThan(exit.frame.height, 60)
        exit.tap()
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].waitForExistence(timeout: 5))
        app.buttons["openComicSearch"].tap()
        app.textFields["comicSearchField"].typeText("已保存的漫画")
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["comicCard-10001"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "explicit-search-includes-downloaded")
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("compatibility-shots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

// XCTest added waitForNonExistence after the older supported toolchains.
extension XCUIElement {
    func waitForDisappearance(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
