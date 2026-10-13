import XCTest

final class JMDownloaderUITests: XCTestCase {
    @MainActor func testActiveDownloadsAppearAbovePDFAndPreparingTasks() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--mixed-download-states-fixture", "--dark-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10)); tabs.buttons["下载任务"].tap()
        let rows = ["10006", "10002", "10004", "10005"].map { app.descendants(matching: .any)["jobCard-" + $0].firstMatch }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 5)) }
        for index in 0..<rows.count - 1 { XCTAssertLessThan(rows[index].frame.maxY, rows[index + 1].frame.minY) }
        XCTAssertEqual(app.staticTexts["jobProgressLabel-10004"].label, "25%")
        attach(app, name: "42-downloads-before-pdf-and-preparing-dark")
        let comic = app.staticTexts["正在生成 PDF 的漫画"]
        let deletion = app.buttons["删除任务及下载缓存"]
        comic.press(forDuration: 1.5)
        if !deletion.waitForExistence(timeout: 3) {
            rows[2].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 2)
        }
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        deletion.tap()
        let confirm = app.buttons["confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(confirm.frame.width, 200)
        attach(app, name: "43-wide-neutral-confirmation-dark")
        app.buttons["scrollToTop"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(confirm.waitForDisappearance(timeout: 5))
        XCTAssertTrue(comic.exists)
    }
    @MainActor func testFavoriteVisibilityHiddenSelectionAndManagedThumbnails() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 10))
        let hidden = app.staticTexts["等待继续的漫画"]
        hidden.press(forDuration: 1.5)
        XCTAssertFalse(app.buttons["下载漫画"].exists)
        app.buttons["隐藏漫画"].tap()
        XCTAssertTrue(hidden.waitForDisappearance(timeout: 5))
        app.buttons["更多"].tap(); app.buttons["查看已下载"].tap()
        XCTAssertTrue(app.staticTexts["已保存的漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在下载的漫画"].exists)
        XCTAssertFalse(hidden.exists)
        attach(app, name: "38-favorites-downloaded-only")
        app.buttons["更多"].tap(); app.buttons["查看隐藏漫画"].tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已保存的漫画"].exists)
        XCTAssertFalse(app.staticTexts["正在下载的漫画"].exists)
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["查看已下载"].exists)
        XCTAssertFalse(app.buttons["隐藏已下载"].exists)
        app.buttons["收起隐藏漫画"].tap()
        app.buttons["更多"].tap(); app.buttons["选择隐藏漫画"].tap()
        XCTAssertTrue(app.staticTexts["已选 0"].waitForExistence(timeout: 5))
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["关闭隐藏漫画"].waitForExistence(timeout: 5))
        app.buttons["关闭隐藏漫画"].tap()
        XCTAssertTrue(app.staticTexts["已选 0"].waitForDisappearance(timeout: 5))
        app.buttons["settings"].tap(); app.buttons["comicSettings"].tap()
        XCTAssertTrue(app.navigationBars["已排除/隐藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["hiddenReason-10003"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["dislikedReason-10003"].firstMatch.exists)
        let thumbnail = app.descendants(matching: .any)["restrictedCover-10003"].firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5)); thumbnail.tap()
        XCTAssertFalse(app.navigationBars["封面详情"].exists)
        XCTAssertTrue(app.navigationBars["已排除/隐藏"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["hiddenReason-10003"].firstMatch.exists)
        XCTAssertTrue(app.buttons["restoreRestricted-10003"].exists)
        attach(app, name: "39-hidden-management-static-thumbnail")
        app.buttons["restoreRestricted-10003"].tap()
        XCTAssertTrue(thumbnail.waitForDisappearance(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["hiddenReason-10003"].firstMatch.exists)
        app.navigationBars["已排除/隐藏"].buttons["BackButton"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
    }
    @MainActor func testUnifiedCardDimensionsAndTitleReturnsLargeLibraryToTop() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        let favorite = app.descendants(matching: .any)["comicCard-10003"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        let height = favorite.frame.height
        tabs.buttons["漫画推荐"].tap()
        let recommendation = app.descendants(matching: .any)["comicCard-10003"].firstMatch
        XCTAssertTrue(recommendation.waitForExistence(timeout: 5))
        XCTAssertEqual(recommendation.frame.height, height, accuracy: 1)
        XCTAssertFalse(app.buttons["recommendationSort"].exists)
        tabs.buttons["下载任务"].tap()
        let download = app.descendants(matching: .any)["jobCard-10003"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.frame.height, height, accuracy: 1)
        tabs.buttons["漫画收藏"].tap()
        let scroll = app.scrollViews["libraryScroll-漫画收藏"]
        for _ in 0..<6 { scroll.swipeUp() }
        XCTAssertFalse(app.buttons["cover-10002"].isHittable)
        app.buttons["scrollToTop"].tap()
        XCTAssertTrue(app.buttons["cover-10002"].waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["cover-10002"])
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["cover-10002"].isHittable)
        attach(app, name: "32-unified-card-size-and-scroll-to-top")
    }
    @MainActor func testDislikeExclusionAndSingleConfirmationMenus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["漫画推荐"].tap()
        let comic = app.staticTexts["等待继续的漫画"]
        XCTAssertTrue(comic.waitForExistence(timeout: 5))
        comic.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["不喜欢该漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["隐藏漫画"].exists)
        XCTAssertFalse(app.buttons["排除该漫画"].exists)
        XCTAssertFalse(app.buttons["删除任务及下载缓存"].exists)
        XCTAssertFalse(app.buttons["下载漫画"].exists)
        app.buttons["不喜欢该漫画"].tap()
        XCTAssertTrue(comic.exists)
        XCTAssertEqual(app.descendants(matching: .any)["comicCard-10003"].firstMatch.value as? String, "已标记不喜欢，刷新后隐藏")
        attach(app, name: "40-disliked-card-dimmed-before-refresh")
        app.buttons["更多"].tap(); app.buttons["刷新列表"].tap()
        XCTAssertTrue(comic.waitForDisappearance(timeout: 5))
        app.buttons["settings"].tap(); app.buttons["comicSettings"].tap()
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已排除/隐藏")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["dislikedReason-10003"].firstMatch.exists)
        attach(app, name: "33-disliked-excluded-settings")
        app.navigationBars["已排除/隐藏"].buttons["BackButton"].tap()
        app.buttons["完成"].tap()
        tabs.buttons["下载任务"].tap()
        app.buttons["startAll"].tap()
        XCTAssertEqual(app.staticTexts["jobState-10003"].label, "已暂停")
        app.buttons["resume-10003"].tap()
        let confirm = app.buttons["confirmExcludedDownload"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "确认")
        XCTAssertGreaterThan(confirm.frame.width, 200)
        let excludedPrompt = app.staticTexts["该漫画已被排除，是否下载？"]
        XCTAssertTrue(excludedPrompt.exists)
        XCTAssertLessThan(excludedPrompt.frame.height, 30)
        XCTAssertFalse(app.staticTexts["是否下载该漫画？"].exists)
        XCTAssertFalse(app.buttons["取消"].exists)
        attach(app, name: "34-excluded-download-single-confirmation")
        app.buttons["scrollToTop"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(confirm.waitForDisappearance(timeout: 5))
        XCTAssertEqual(app.staticTexts["jobState-10003"].label, "已暂停")
        app.buttons["resume-10003"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["jobState-10003"], containing: "等待下载"))
        comic.press(forDuration: 1.5)
        let delete = app.buttons["删除任务及下载缓存"]
        if !delete.waitForExistence(timeout: 4) { comic.press(forDuration: 1.5) }
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        XCTAssertTrue(app.buttons["confirmDelete"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["confirmDelete"].label, "确认")
        XCTAssertGreaterThan(app.buttons["confirmDelete"].frame.width, 200)
        let deletePrompt = app.staticTexts["删除任务及缓存？PDF 会保留。"]
        XCTAssertTrue(deletePrompt.exists)
        XCTAssertLessThan(deletePrompt.frame.height, 30)
        XCTAssertFalse(app.buttons["取消"].exists)
        attach(app, name: "37-delete-cache-single-confirmation")
        app.buttons["confirmDelete"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(comic.waitForDisappearance(timeout: 5))
    }
    @MainActor func testBlacklistTitleFieldAndExactTagSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap(); app.buttons["tagBlacklist"].tap()
        XCTAssertTrue(app.navigationBars["黑名单"].waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["titleBlacklistField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("侦探")
        app.buttons["保存"].tap()
        app.buttons["tagBlacklist"].tap()
        XCTAssertEqual(field.value as? String, "侦探")
        attach(app, name: "35-tag-and-title-blacklist")
        app.navigationBars["黑名单"].buttons["BackButton"].tap()
        app.buttons["完成"].tap()
        app.segmentedControls["libraryTabs"].buttons["漫画推荐"].tap()
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.textFields["comicSearchField"].typeText("#AI绘图")
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recommendationSort"].exists)
        attach(app, name: "36-exact-tag-search")
        app.buttons["exitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].waitForExistence(timeout: 5))
    }
    @MainActor func testNativePagingCancelsShortDragAndKeepsOnlyCurrentPageAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        let pager = app.scrollViews["libraryPager"]
        XCTAssertTrue(pager.exists)
        attach(app, name: "29-light-liquid-glass-rounded-cards")
        let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let end = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
        XCTAssertEqual(app.buttons.matching(identifier: "openComicSearch").count, 1)
        XCTAssertFalse(app.buttons["startAll"].exists)
        pager.swipeLeft()
        XCTAssertTrue(app.scrollViews["libraryScroll-漫画推荐"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
        pager.swipeRight()
        XCTAssertTrue(app.scrollViews["libraryScroll-漫画收藏"].waitForExistence(timeout: 5))
        pager.swipeRight()
        XCTAssertTrue(app.buttons["startAll"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["下载任务"].isSelected)
        app.terminate()
        app.launchArguments += ["--dark-fixture"]
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["下载任务"].tap()
        XCTAssertTrue(app.buttons["logCapsule"].waitForExistence(timeout: 5))
        attach(app, name: "30-dark-liquid-glass-rounded-cards")
    }

    @MainActor func testFavoritesUseLoadingIconAndReadOnlyProgressNotice() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--favorite-loading-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let status = app.staticTexts["librarySearching"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "正在加载")
        let notice = app.descendants(matching: .any)["libraryLoadNotice-漫画收藏"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(notice, containing: "4/20"))
        XCTAssertTrue(notice.label.contains("4/20"))
        XCTAssertTrue(notice.label.contains("20%"))
        XCTAssertFalse(app.buttons["libraryLoadNotice-漫画收藏"].exists)
        notice.tap()
        XCTAssertFalse(app.buttons["closeLogHistory"].exists)
        XCTAssertTrue(status.exists)
        attach(app, name: "23-favorites-loading-independent-notice")
    }
    @MainActor func testPartialRecommendationsUseHiddenDefaultSortAndReadOnlyCenteredNotice() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--recommendation-stream-fixture", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.segmentedControls["libraryTabs"].buttons["漫画推荐"].tap()
        XCTAssertFalse(app.buttons["recommendationSort"].exists)
        XCTAssertTrue(app.buttons["cover-10003"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["librarySearching"].exists)
        XCTAssertFalse(app.staticTexts["libraryDisconnected"].exists)
        let notice = app.descendants(matching: .any)["libraryLoadNotice-漫画推荐"].firstMatch
        XCTAssertTrue(waitForLabel(notice, containing: "核验推荐漫画"))
        XCTAssertFalse(notice.label.contains("提示记录"))
        XCTAssertFalse(app.buttons["libraryLoadNotice-漫画推荐"].exists)
        attach(app, name: "24-recommendation-results-with-progress")
        app.swipeRight()
        XCTAssertTrue(app.buttons["收藏夹"].waitForExistence(timeout: 5))
    }
    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: 20) == .completed
    }
    @MainActor func testRecommendationLoadingAndDisconnectedStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--recommendation-loading-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["libraryTabs"].waitForExistence(timeout: 10))
        app.segmentedControls["libraryTabs"].buttons["漫画推荐"].tap()
        XCTAssertTrue(app.staticTexts["librarySearching"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["librarySearching"].label, "正在搜索…")
        attach(app, name: "20-recommendations-searching")
        app.terminate()
        app.launchArguments = ["--ui-fixture-v120", "--recommendation-failure-fixture", "--dark-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["libraryTabs"].waitForExistence(timeout: 10))
        app.segmentedControls["libraryTabs"].buttons["漫画推荐"].tap()
        XCTAssertTrue(app.staticTexts["libraryFailed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["libraryFailed"].label, "加载失败")
        XCTAssertFalse(app.staticTexts["libraryDisconnected"].exists)
        XCTAssertFalse(app.buttons["重试"].exists)
        attach(app, name: "31-recommendations-load-failed-dark")
        app.terminate()
        app.launchArguments = ["--ui-fixture-v120", "--recommendation-offline-fixture", "--dark-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["libraryTabs"].waitForExistence(timeout: 10))
        app.segmentedControls["libraryTabs"].buttons["漫画推荐"].tap()
        XCTAssertTrue(app.staticTexts["libraryDisconnected"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["libraryDisconnected"].label, "网络已断开")
        XCTAssertFalse(app.staticTexts["libraryFailed"].exists)
        XCTAssertFalse(app.staticTexts["libraryEmpty"].exists)
        XCTAssertFalse(app.buttons["重试"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach(app, name: "21-recommendations-disconnected-dark")
    }
    @MainActor func testFavoriteAndRecommendationBottomRowsRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture-v120", "--long-library-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["libraryTabs"].waitForExistence(timeout: 10))
        for module in ["漫画收藏", "漫画推荐"] {
            app.segmentedControls["libraryTabs"].buttons[module].tap()
            let scroll = app.scrollViews["libraryScroll-" + module]
            let lastCover = app.buttons["cover-10075"]
            for _ in 0..<20 { if lastCover.isHittable { break }; scroll.swipeUp() }
            // Scroll to the actual bottom, then verify the complete card clears
            // the home-indicator region and its action can still be tapped.
            scroll.swipeUp()
            XCTAssertTrue(lastCover.isHittable)
            XCTAssertLessThan(lastCover.frame.maxY, app.frame.maxY - 20)
            let notice = app.descendants(matching: .any)["libraryLoadNotice-" + module].firstMatch
            XCTAssertLessThan(lastCover.frame.maxY, notice.frame.minY)
            attach(app, name: "22-bottom-clear-" + module)
            lastCover.tap()
            XCTAssertTrue(app.navigationBars["封面详情"].waitForExistence(timeout: 5))
            app.buttons["完成"].tap()
        }
    }
    @MainActor func testProgressLogsRemainTouchableAndCanPause() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-fixture-v120", "--progress-stress-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["libraryTabs"].waitForExistence(timeout: 10))
        app.segmentedControls["libraryTabs"].buttons["下载任务"].tap()
        let exportLabel = app.staticTexts["jobProgressLabel-10002"]
        XCTAssertTrue(exportLabel.label.hasSuffix("%"))
        XCTAssertFalse(exportLabel.label.contains("/"))
        XCTAssertTrue(app.descendants(matching: .any)["jobProgress-10002"].firstMatch.label.contains("从右向左"))
        attach(app, name: "25-pdf-export-percent-right-to-left")
        app.buttons["logCapsule"].tap()
        XCTAssertTrue(app.navigationBars["提示记录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["closeLogHistory"].exists)
        XCTAssertFalse(app.buttons["完成"].exists)
        attach(app, name: "19-log-history-during-pdf-progress")
        app.navigationBars["提示记录"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["pauseAll"].waitForExistence(timeout: 5))
        app.buttons["pauseAll"].tap()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["accountSettings"].waitForExistence(timeout: 5))
    }
    @MainActor func testCreateAndSelectDownloadDirectory() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap(); app.buttons["accountSettings"].tap()
        let directoryLink = app.buttons["downloadDirectorySettings"]
        for _ in 0..<5 { if directoryLink.isHittable { break }; app.swipeUp() }
        directoryLink.tap()
        let field = app.textFields["newDownloadFolderName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<5 { if field.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        field.tap()
        // A hittable SwiftUI field can still miss focus during a cold simulator
        // transition. Retry the touch once, then require the keyboard before typing.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("UI-PDF-" + String(Int(Date().timeIntervalSince1970)))
        app.buttons["createDownloadFolder"].tap()
        // Bookmark/write validation is asynchronous and can be slow on the first
        // simulator filesystem operation. Still require actual success below.
        XCTAssertTrue(app.staticTexts["directoryNotice"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["directoryNotice"].label.contains("已选择"))
        attach(app, name: "20-new-download-directory")
        app.buttons["chooseDownloadDirectory"].tap()
        // The simulator's Files provider can cold-start slowly. Require the same
        // native confirmation control, allowing its first launch to finish.
        let openFolder = app.buttons["打开"]
        let localStorage = app.staticTexts["我的 iPhone"]
        let browserReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            openFolder.exists || localStorage.exists
        }, object: app)
        let browserResult = XCTWaiter.wait(for: [browserReady], timeout: 90)
        XCTAssertEqual(browserResult, .completed)
        guard browserResult == .completed else { return }
        // Files can start at Browse instead of honoring directoryURL on a cold
        // provider. Navigate its visible local storage, as a user would.
        if !openFolder.exists {
            localStorage.tap()
            let appFolder = app.cells.containing(.staticText, identifier: "JM downloader").firstMatch
            guard appFolder.waitForExistence(timeout: 30) else {
                XCTFail("Application folder missing from native local storage"); return
            }
            appFolder.tap()
        }
        guard openFolder.waitForExistence(timeout: 90) else {
            XCTFail("Native Files confirmation did not finish loading"); return
        }
        let pickerReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: openFolder)
        let ready = XCTWaiter.wait(for: [pickerReady], timeout: 30)
        XCTAssertEqual(ready, .completed)
        guard ready == .completed else { return }
        attach(app, name: "21-native-folder-picker")
        openFolder.tap()
        guard openFolder.waitForDisappearance(timeout: 30) else {
            XCTFail("Native Files picker did not close after confirming the folder"); return
        }
        let directoryReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: app.buttons["chooseDownloadDirectory"])
        XCTAssertEqual(XCTWaiter.wait(for: [directoryReady], timeout: 30), .completed)
        XCTAssertTrue(app.staticTexts["directoryNotice"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["directoryNotice"].label.contains("已选择"))
        app.navigationBars["下载目录"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["saveAccount"].waitForExistence(timeout: 10))
        app.buttons["saveAccount"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }
    @MainActor func testQueueLibraryAndNearbyDeletion() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        XCTAssertLessThan(tabs.buttons["下载任务"].frame.minX, tabs.buttons["漫画收藏"].frame.minX)
        XCTAssertFalse(app.descendants(matching: .any)["downloaded-10001"].exists)
        app.buttons["下载 等待继续的漫画"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["downloading-10003"].waitForExistence(timeout: 2))
        attach(app, name: "12-favorites-collapsed")
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["查看已下载"].waitForExistence(timeout: 3))
        app.buttons["查看已下载"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["downloaded-10001"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["下载 已保存的漫画"].exists)
        attach(app, name: "08-library-downloaded")
        tabs.buttons["漫画推荐"].tap()
        XCTAssertTrue(app.scrollViews["libraryScroll-漫画推荐"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openComicSearch"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["downloaded-10001"].exists)
        XCTAssertFalse(app.buttons["recommendationSort"].exists)
        attach(app, name: "13-recommendation-default-likes")
        tabs.buttons["下载任务"].tap()
        XCTAssertFalse(app.buttons["搜索"].exists)
        XCTAssertFalse(app.buttons["更多"].exists)
        XCTAssertTrue(app.buttons["startAll"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["正在下载的漫画"].frame.minY, app.staticTexts["等待继续的漫画"].frame.minY)
        attach(app, name: "09-queue-priority")
        app.buttons["pauseAll"].tap()
        XCTAssertFalse(app.staticTexts["下载中"].exists)
        app.buttons["startAll"].tap()
        XCTAssertTrue(app.staticTexts["等待下载"].firstMatch.waitForExistence(timeout: 5))
        let card = app.staticTexts["等待继续的漫画"]
        let originalY = card.frame.midY
        let deleteAction = app.buttons["删除任务及下载缓存"]
        card.press(forDuration: 1.5)
        // Simulator context menus may miss the first press during a row reorder.
        // Retry the gesture once only if the menu never appeared; still require it.
        if !deleteAction.waitForExistence(timeout: 4) { card.press(forDuration: 1.5) }
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()
        XCTAssertTrue(app.buttons["confirmDelete"].waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(app.buttons["confirmDelete"].frame.midY - originalY), 330)
        attach(app, name: "10-delete-near-card")
        app.buttons["confirmDelete"].tap()
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].waitForDisappearance(timeout: 5))
        app.buttons["settings"].tap()
        app.buttons["cacheSettings"].tap()
        app.buttons["clearCoverCache"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cacheNotice"].waitForExistence(timeout: 5))
        attach(app, name: "11-cache-cleared")
    }
    @MainActor func testSwipeSearchHidingAndAutomaticDownloadMenu() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-fixture-v120", "--dark-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        let favorite = app.staticTexts["等待继续的漫画"]
        favorite.press(forDuration: 1)
        XCTAssertFalse(app.buttons["排除该漫画"].exists)
        XCTAssertFalse(app.buttons["删除任务及下载缓存"].exists)
        app.buttons["隐藏漫画"].tap()
        XCTAssertTrue(favorite.waitForDisappearance(timeout: 3))
        app.buttons["更多"].tap(); app.buttons["查看隐藏漫画"].tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        favorite.press(forDuration: 1)
        app.buttons["取消隐藏漫画"].tap()
        // Swipe across otherwise empty content below the tabs.
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(app.scrollViews["libraryScroll-漫画推荐"].waitForExistence(timeout: 3))
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.textFields["comicSearchField"].typeText("AI")
        attach(app, name: "27-search-controls-with-keyboard")
        XCTAssertTrue(app.buttons["submitComicSearch"].isHittable)
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["downloaded-10001"].exists)
        attach(app, name: "14-dark-search-blacklist-bypass")
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertTrue(app.buttons["openComicSearch"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertTrue(app.buttons["startAll"].waitForExistence(timeout: 3))
        let task = app.staticTexts["等待继续的漫画"]
        let stopAutomatic = app.buttons["排除该漫画"]
        task.press(forDuration: 1.5)
        if !stopAutomatic.waitForExistence(timeout: 4) { task.press(forDuration: 1.5) }
        XCTAssertTrue(stopAutomatic.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["下载漫画"].exists)
        // The card still has a play button; only the context-menu action was removed.
        stopAutomatic.tap()
        task.press(forDuration: 1.5)
        if !app.buttons["取消排除该漫画"].waitForExistence(timeout: 4) { task.press(forDuration: 1.5) }
        XCTAssertTrue(app.buttons["取消排除该漫画"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["排除该漫画"].exists)
        app.buttons["取消排除该漫画"].tap()
        attach(app, name: "15-dark-queue-bordered-cards-capsule")
    }
    @MainActor func testSingleTapCoverAndSearchDismissal() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-fixture-v120", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tabs = app.segmentedControls["libraryTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        for module in ["漫画收藏", "下载任务", "漫画推荐"] {
            tabs.buttons[module].tap()
            let cover = app.buttons["cover-10003"]
            XCTAssertTrue(cover.waitForExistence(timeout: 5))
            cover.tap()
            XCTAssertTrue(app.navigationBars["封面详情"].waitForExistence(timeout: 5))
            attach(app, name: "16-single-tap-cover-" + module)
            app.buttons["完成"].tap()
            XCTAssertTrue(app.navigationBars["封面详情"].waitForDisappearance(timeout: 5))
            let card = app.descendants(matching: .any)[(module == "下载任务" ? "jobCard-" : "comicCard-") + "10003"].firstMatch
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)).tap()
            XCTAssertTrue(app.navigationBars["封面详情"].waitForExistence(timeout: 5))
            attach(app, name: "41-left-80-percent-preview-" + module)
            app.buttons["完成"].tap()
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            XCTAssertFalse(app.navigationBars["封面详情"].exists)
        }
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.textFields["comicSearchField"].typeText("AI")
        app.buttons["scrollToTop"].tap()
        XCTAssertTrue(app.textFields["comicSearchField"].waitForDisappearance(timeout: 3))
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].exists)
        app.buttons["openComicSearch"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        attach(app, name: "28-restored-search-controls-with-keyboard")
        XCTAssertTrue(app.buttons["submitComicSearch"].isHittable)
        app.buttons["submitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["主动搜索的 AI 漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["downloaded-10001"].exists)
        XCTAssertFalse(app.textFields["comicSearchField"].exists)
        XCTAssertTrue(app.buttons["exitComicSearch"].exists)
        attach(app, name: "17-search-results-keyboard-dismissed")
        app.buttons["exitComicSearch"].tap()
        XCTAssertTrue(app.staticTexts["等待继续的漫画"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["主动搜索的 AI 漫画"].exists)
        attach(app, name: "18-restored-recommendations")
    }
    @MainActor func testSettingsAndSelectionFlow() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        attach(app, name: "01-home-iPhone-17-Pro-Max")
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["accountSettings"].waitForExistence(timeout: 5))
        app.buttons["accountSettings"].tap()
        XCTAssertTrue(app.switches["记住账号"].waitForExistence(timeout: 5))
        attach(app, name: "02-account-settings")
        app.segmentedControls["platformPicker"].buttons["PicACG"].tap()
        XCTAssertTrue(app.buttons["登录 PicACG"].exists)
        let username = app.textFields["账号"]
        username.tap(); username.typeText("keyboard-fixture")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.navigationBars["账号设置"].staticTexts["账号设置"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForDisappearance(timeout: 3))
        attach(app, name: "03-picacg-settings")
        app.swipeUp()
        app.buttons["saveNetwork"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["networkNotice"].waitForExistence(timeout: 3))
        attach(app, name: "06-network-saved")
        app.buttons["saveAccount"].tap()
        XCTAssertTrue(app.navigationBars["账号设置"].waitForDisappearance(timeout: 5))
        app.buttons["settings"].tap()
        app.buttons["accountSettings"].tap()
        XCTAssertTrue(app.segmentedControls["platformPicker"].buttons["PicACG"].isSelected)
        app.buttons["saveAccount"].tap()
        app.terminate(); app.launch()
        app.buttons["settings"].tap()
        app.buttons["accountSettings"].tap()
        XCTAssertTrue(app.segmentedControls["platformPicker"].buttons["PicACG"].isSelected)
        app.navigationBars["账号设置"].buttons["BackButton"].tap()
        app.buttons["themeSettings"].tap()
        XCTAssertEqual(app.buttons["theme-橙"].value as? String, "已选择")
        attach(app, name: "07-theme-unchanged-orange")
        app.navigationBars["主题设置"].buttons["BackButton"].tap()
        app.buttons["themeSettings"].tap()
        XCTAssertEqual(app.buttons["theme-橙"].value as? String, "已选择")
        app.buttons["theme-蓝"].tap()
        XCTAssertEqual(app.buttons["theme-蓝"].value as? String, "已选择")
        attach(app, name: "04-theme-blue")
        app.segmentedControls.buttons["深色"].tap()
        attach(app, name: "05-theme-dark")
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
