import XCTest
import UIKit

final class NativeControlsPDFTests: XCTestCase {
    @MainActor func testPDFSheetAppearanceAndNativePullToDismiss() {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-fixture-v120", "--pdf-reader-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launchArguments += [dark ? "--dark-fixture" : "--light-fixture"]
            app.launch()
            let tabs = app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            tabs.buttons["PDF 预览"].tap()
            let file = app.buttons["localPDF-连续阅读检查 [JMComic 90001].pdf"]
            XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
            let scroll = app.scrollViews["pdfContinuousReader"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let bar = app.navigationBars.containing(.button, identifier: "完成").firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            capture(app, dark ? "pdf-dark-native-header" : "pdf-light-native-header")
            // Average the navigation bar, rather than reading an app-provided
            // flag: this catches a white sheet over an otherwise dark app.
            let brightness = averageBrightness(bar.screenshot().image)
            if dark { XCTAssertLessThan(brightness, 0.4) }
            else { XCTAssertGreaterThan(brightness, 0.6) }
            scroll.swipeUp()
            XCTAssertTrue(scroll.exists)
            // Dismiss from the native top bar, even while the PDF is scrolled.
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.05, thenDragTo: end)
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: scroll)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(file.isHittable)
            file.tap()
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            app.buttons["完成"].tap()
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    private func averageBrightness(_ image: UIImage) -> Double {
        guard let image = image.cgImage else { XCTFail("Missing header image"); return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
    }
    @MainActor func testMoreMenusStayOpenAndKeepTextFramesDuringProgress() {
        for (moduleIndex, module) in ["下载任务", "漫画收藏", "漫画推荐"].enumerated() {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-fixture-v120", "--menu-progress-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
            let tabs = app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
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
        let tabs = app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
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
            let tabs = app.descendants(matching: .any).matching(identifier: "libraryTabs").firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            XCTAssertTrue(tabs.buttons["漫画收藏"].isSelected)
            capture(app, reference ? "reference-dark-picker-start" : "app-dark-picker-start")
            let left = tabs.buttons["下载任务"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let right = tabs.buttons["漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            print("CONTROL_CAPTURE \(reference ? "picker-reference" : "picker-app") \(Date().timeIntervalSince1970) 6")
            left.press(forDuration: 0.3, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 2)
            XCTAssertTrue(tabs.buttons["漫画推荐"].isSelected)
            capture(app, reference ? "reference-dark-picker-drag-end" : "app-dark-picker-drag-end")
            let selected = tabs.buttons["漫画推荐"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            print("CONTROL_CAPTURE \(reference ? "selected-reference" : "selected-app") \(Date().timeIntervalSince1970) 6")
            selected.press(forDuration: 0.3, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 2)
            XCTAssertTrue(tabs.buttons["下载任务"].isSelected)
            capture(app, reference ? "reference-selected-drag-end" : "app-selected-drag-end")
            app.terminate()
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
