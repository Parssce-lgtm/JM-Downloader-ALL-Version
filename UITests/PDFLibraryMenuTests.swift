import XCTest

final class PDFLibraryMenuTests: XCTestCase {
    @MainActor func testDetailsDislikeUndoRelaunchAndBothDeletionActions() {
        let app = XCUIApplication()
        let base = ["--ui-fixture-v120", "--pdf-menu-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = base + ["--reset-pdf-menu-fixture"]
        app.launch()
        let tabs = app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15)); tabs.buttons["PDF 预览"].tap()
        let keptName = "本地保留检查 [JMComic 91001].pdf"
        let deleteName = "本地删除检查 [JMComic 91002].pdf"
        let combinedName = "本地组合检查 [JMComic 91003].pdf"
        let kept = app.buttons["localPDF-" + keptName]
        XCTAssertTrue(kept.waitForExistence(timeout: 10))
        kept.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["详细信息"].waitForExistence(timeout: 5)); app.buttons["详细信息"].tap()
        XCTAssertTrue(app.navigationBars["封面详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["JMComic 91001"].exists)
        capture(app, "pdf-cover-details")
        app.buttons["完成"].tap()
        kept.press(forDuration: 0.8); app.buttons["不喜欢该漫画"].tap()
        let disliked = NSPredicate(format: "value == %@", "不喜欢")
        expectation(for: disliked, evaluatedWith: kept); waitForExpectations(timeout: 10)
        capture(app, "pdf-disliked-dimmed")
        kept.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["取消不喜欢"].waitForExistence(timeout: 5)); app.buttons["取消不喜欢"].tap()
        XCTAssertNotEqual(kept.value as? String, "不喜欢")
        kept.press(forDuration: 0.8); app.buttons["不喜欢该漫画"].tap()
        expectation(for: disliked, evaluatedWith: kept); waitForExpectations(timeout: 10)

        let removed = app.buttons["localPDF-" + deleteName]
        removed.press(forDuration: 0.8); app.buttons["删除源文件"].tap()
        XCTAssertTrue(app.buttons["confirmDeletePDF"].waitForExistence(timeout: 5)); app.buttons["confirmDeletePDF"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: removed); waitForExpectations(timeout: 10)
        let combined = app.buttons["localPDF-" + combinedName]
        combined.press(forDuration: 0.8); app.buttons["不喜欢并删除源文件"].tap()
        XCTAssertTrue(app.buttons["confirmDeletePDF"].waitForExistence(timeout: 5)); app.buttons["confirmDeletePDF"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: combined); waitForExpectations(timeout: 10)

        app.terminate(); app.launchArguments = base; app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 15)); tabs.buttons["PDF 预览"].tap()
        XCTAssertTrue(app.staticTexts["这里还没有 PDF"].waitForExistence(timeout: 10) || !kept.exists)
        XCTAssertFalse(kept.exists); XCTAssertFalse(removed.exists); XCTAssertFalse(combined.exists)
        app.buttons["settings"].tap()
        let settings = app.buttons["comicSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let restoreKept = app.buttons["restorePDF-" + keptName]
        XCTAssertTrue(restoreKept.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["restorePDF-" + combinedName].exists)
        XCTAssertFalse(app.buttons["restorePDF-" + deleteName].exists)
        capture(app, "pdf-excluded-after-relaunch")
        restoreKept.tap(); app.buttons["restorePDF-" + combinedName].tap()
        app.navigationBars["已排除/隐藏"].buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(kept.waitForExistence(timeout: 10))
        XCTAssertFalse(removed.exists); XCTAssertFalse(combined.exists)
        kept.tap()
        XCTAssertTrue(app.scrollViews["pdfContinuousReader"].waitForExistence(timeout: 10))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
