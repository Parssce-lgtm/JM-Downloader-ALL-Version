import XCTest

final class LibraryTabLayoutTests: XCTestCase {
    // Run the original Build 29 header and its replacement in the same full
    // screen. Compare real accessibility frames and keep uncropped screenshots
    // for pixel review; an isHittable-only check missed the Build 30 regression.
    @MainActor func testHeaderAndFirstRowsMatchBuild29InEveryConfiguration() {
        for dark in [false, true] {
            for preview in [false, true] {
                var original: [String: CGRect] = [:]
                for reference in [true, false] {
                    let app = launch(dark: dark, preview: preview, reference: reference)
                    let tabs = tabControl(app)
                    let variant = "\(dark ? "dark" : "light")-\(preview ? "four" : "three")-\(reference ? "build29" : "glass")"
                    if reference { original["tabs"] = tabs.frame }
                    else { assertFrame(tabs.frame, matches: original["tabs"]!) }
                    for title in titles(preview: preview) {
                        tabs.buttons[title].tap()
                        XCTAssertTrue(tabs.buttons[title].isSelected)
                        let row = firstRow(app, title: title)
                        XCTAssertTrue(row.waitForExistence(timeout: 5))
                        XCTAssertGreaterThanOrEqual(row.frame.minY, tabs.frame.maxY + 8)
                        XCTAssertGreaterThanOrEqual(row.frame.height, 18)
                        XCTAssertLessThanOrEqual(row.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
                        XCTAssertGreaterThanOrEqual(row.frame.minX, 0)
                        if reference { original[title] = row.frame }
                        else { assertFrame(row.frame, matches: original[title]!) }
                        for text in row.staticTexts.allElementsBoundByIndex {
                            XCTAssertGreaterThanOrEqual(text.frame.minY, row.frame.minY - 1)
                            XCTAssertLessThanOrEqual(text.frame.maxY, row.frame.maxY + 1)
                        }
                        capture(app, "layout-\(variant)-\(title)")
                    }
                    app.terminate()
                }
            }
        }
    }

    @MainActor func testLiveDraggingAndPageSwipeKeepFirstRowsVisible() {
        for dark in [false, true] {
            for preview in [false, true] {
                let app = launch(dark: dark, preview: preview)
                let tabs = tabControl(app)
                let leftTitle = preview ? "PDF 预览" : "下载任务"
                let left = tabs.buttons[leftTitle].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let right = tabs.buttons["漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                // Start on an unselected option, hold while crossing several
                // segments, then start on the selected option on the return.
                print("CONTROL_CAPTURE live-\(dark ? "dark" : "light")-\(preview ? "four" : "three") \(Date().timeIntervalSince1970) 20")
                left.press(forDuration: 0.3, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 1)
                XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
                assertVisibleRow(app, tabs: tabs, title: "漫画推荐")
                right.press(forDuration: 0.3, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 1)
                XCTAssertTrue(tabs.buttons[leftTitle].isSelected)
                assertVisibleRow(app, tabs: tabs, title: leftTitle)
                for _ in 0..<3 {
                    left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
                    right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
                }
                XCTAssertTrue(tabs.buttons[leftTitle].isSelected)
                assertVisibleRow(app, tabs: tabs, title: leftTitle)
                tabs.buttons["漫画收藏"].tap()
                app.swipeLeft()
                XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
                assertVisibleRow(app, tabs: tabs, title: "漫画推荐")
                let outside = tabs.coordinate(withNormalizedOffset: CGVector(dx: 1.2, dy: 2))
                right.press(forDuration: 0.2, thenDragTo: outside)
                tabs.buttons["下载任务"].tap()
                XCTAssertTrue(tabs.buttons["下载任务"].isSelected)
                assertVisibleRow(app, tabs: tabs, title: "下载任务")
                capture(app, "drag-complete-\(dark)-\(preview)")
                app.terminate()
            }
        }
    }

    @MainActor func testKeyboardRotationAndSettingsPreserveHeaderLayout() {
        var landscapeFrames: [String: CGRect] = [:]
        let app = launch(dark: false, preview: true)
        let tabs = tabControl(app)
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.textFields["comicSearchField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Fresh simulator runtimes can show the system QuickPath introduction.
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        if app.buttons["继续"].exists { app.buttons["继续"].tap() }
        XCTAssertTrue(app.keyboards.keys.firstMatch.waitForExistence(timeout: 5))
        assertVisibleRow(app, tabs: tabs, title: "漫画收藏")
        capture(app, "layout-with-keyboard")
        app.buttons["scrollToTop"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForDisappearance(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for title in titles(preview: true) {
            tabs.buttons[title].tap()
            assertVisibleRow(app, tabs: tabs, title: title)
            landscapeFrames[title] = firstRow(app, title: title).frame
            capture(app, "layout-landscape-\(title)")
        }
        XCUIDevice.shared.orientation = .portrait
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["漫画收藏"].tap()
        assertVisibleRow(app, tabs: tabs, title: "漫画收藏")
        capture(app, "layout-after-settings")
        app.terminate()

        // AX frames exclude a view's surrounding padding. In landscape the
        // native download title starts six points below the picker; compare
        // against Build 29 instead of imposing an invented eight-point gap.
        let reference = launch(dark: false, preview: true, reference: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        let referenceTabs = tabControl(reference)
        for title in titles(preview: true) {
            referenceTabs.buttons[title].tap()
            let row = firstRow(reference, title: title)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            assertFrame(landscapeFrames[title]!, matches: row.frame)
            capture(reference, "layout-landscape-build29-\(title)")
        }
        reference.terminate()
    }

    @MainActor private func launch(dark: Bool, preview: Bool, reference: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", dark ? "--dark-fixture" : "--light-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if preview { app.launchArguments.append("--pdf-reader-fixture") }
        if reference { app.launchArguments.append("--build29-tabs-fixture") }
        app.launch()
        XCTAssertTrue(tabControl(app).waitForExistence(timeout: 15))
        return app
    }

    private func titles(preview: Bool) -> [String] {
        (preview ? ["PDF 预览"] : []) + ["下载任务", "漫画收藏", "漫画推荐"]
    }
    @MainActor private func tabControl(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
    }
    @MainActor private func firstRow(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "libraryTools-" + title).firstMatch
    }
    @MainActor private func assertVisibleRow(_ app: XCUIApplication, tabs: XCUIElement, title: String) {
        let row = firstRow(app, title: title)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.minY, tabs.frame.maxY)
        XCTAssertGreaterThanOrEqual(row.frame.height, 18)
    }
    private func assertFrame(_ actual: CGRect, matches expected: CGRect) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
