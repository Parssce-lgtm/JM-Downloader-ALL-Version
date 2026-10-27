import XCTest

final class NativeControlsPDFTests: XCTestCase {
    @MainActor func testMoreMenusStayOpenAndKeepTextFramesDuringProgress() {
        for (moduleIndex, module) in ["下载任务", "漫画收藏", "漫画推荐"].enumerated() {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-fixture-v120", "--menu-progress-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
            let tabs = app.segmentedControls["libraryTabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            tabs.buttons[module].tap()
            let more = module == "下载任务" ? app.buttons["任务操作"] : app.buttons["libraryMore-" + module]
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let item = app.buttons[module == "下载任务" ? "选择任务" : "选择漫画"]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            let original = item.frame
            capture(app, "menu-before-" + module)
            print("CONTROL_CAPTURE menu-\(moduleIndex) \(Date().timeIntervalSince1970) 12")
            // The fixture publishes progress bursts while the native menu is open.
            Thread.sleep(forTimeInterval: 11)
            XCTAssertTrue(item.exists)
            XCTAssertTrue(item.isHittable)
            XCTAssertEqual(item.frame.minY, original.minY, accuracy: 1)
            XCTAssertEqual(item.frame.height, original.height, accuracy: 1)
            capture(app, "menu-after-" + module)
            item.tap()
            XCTAssertTrue(app.staticTexts["已选 0"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    @MainActor func testPDFPagesAreSeamlessAndKeepHeightAfterReverseScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--pdf-reader-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons["PDF 预览"].tap()
        let file = app.buttons["localPDF-连续阅读检查 [JMComic 90001].pdf"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let scroll = app.scrollViews["pdfContinuousReader"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let first = app.descendants(matching: .any)["pdfReaderPage-0"].firstMatch
        let next = app.descendants(matching: .any)["pdfReaderPage-1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(next.exists)
        XCTAssertEqual(first.frame.maxY, next.frame.minY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["1 / 4"].exists)
        capture(app, "pdf-joined-pages-top")
        print("CONTROL_CAPTURE pdf-scroll \(Date().timeIntervalSince1970) 15")
        for _ in 0..<3 { scroll.swipeUp() }
        capture(app, "pdf-joined-pages-bottom")
        for _ in 0..<4 { scroll.swipeDown() }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height / first.frame.width, 1.5, accuracy: 0.02)
        XCTAssertEqual(first.frame.maxY, next.frame.minY, accuracy: 1)
        capture(app, "pdf-joined-pages-returned")
    }
    @MainActor func testDarkNativePickerDragMatchesStandaloneSystemControl() {
        for reference in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-fixture-v120", "--dark-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            if reference { app.launchArguments += ["--native-picker-reference"] }
            app.launch()
            let tabs = app.segmentedControls["libraryTabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
            capture(app, reference ? "reference-dark-picker-start" : "app-dark-picker-start")
            let left = tabs.buttons["下载任务"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let right = tabs.buttons["漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            print("CONTROL_CAPTURE \(reference ? "picker-reference" : "picker-app") \(Date().timeIntervalSince1970) 6")
            left.press(forDuration: 0.3, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 2)
            XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
            capture(app, reference ? "reference-dark-picker-drag-end" : "app-dark-picker-drag-end")
            app.terminate()
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
