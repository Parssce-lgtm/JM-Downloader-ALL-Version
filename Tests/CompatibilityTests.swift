import XCTest
import Combine
import SwiftUI
import UIKit
@testable import JMDownloader

final class CompatibilityTests: XCTestCase {
    @MainActor func testNativeSegmentVisualsMoveBetweenFractionalPagePositions() async throws {
        let paging = LibraryPagingPosition()
        let control = TrackingLibraryTabs(paging: paging)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 100))
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window.windowScene = previous?.windowScene
        window.overrideUserInterfaceStyle = .light
        let controller = UIViewController()
        controller.view.backgroundColor = .systemGroupedBackground
        window.rootViewController = controller
        control.frame = CGRect(x: 12, y: 24, width: 390, height: 36)
        controller.view.addSubview(control)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        func capture(_ name: String) -> CGFloat {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let cg = image.cgImage!
            let width = cg.width, height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let scale = image.scale
            let row = Int((control.frame.minY + 7) * scale)
            let white = (Int(control.frame.minX * scale)..<Int(control.frame.maxX * scale)).filter { x in
                let offset = (row * width + x) * 4
                return pixels[offset] > 247 && pixels[offset + 1] > 247 && pixels[offset + 2] > 247
            }
            XCTAssertGreaterThan(white.count, 30, "Native selected capsule must be visible")
            return CGFloat(white.reduce(0, +)) / CGFloat(max(1, white.count)) / scale
        }
        paging.report(1.2)
        try await Task.sleep(for: .milliseconds(400))
        let early = capture("native-tabs-page-20-percent")
        paging.report(1.8)
        try await Task.sleep(for: .milliseconds(100))
        let late = capture("native-tabs-page-80-percent")
        XCTAssertGreaterThan(late - early, 50, "The native selection must visibly move between the two fractional positions")
        paging.report(2)
        XCTAssertEqual(control.selectedSegmentIndex, 2)
    }
    @MainActor func testPDFProgressDoesNotInvalidateNavigationButThemeAndAlertsDo() {
        let store = AppStore(inMemory: true)
        let navigation = AppNavigationState(store: store)
        var changes = 0
        let subscription = navigation.objectWillChange.sink { changes += 1 }
        store.jobs = [DownloadJob(owner: "fixture", comic: Comic(id: "42", title: "PDF"), state: .exporting)]
        for count in 1...100 { store.jobs[0].renderedPages = count }
        XCTAssertEqual(changes, 0)
        store.preferences.themeColor = "蓝"
        XCTAssertEqual(changes, 1)
        store.alert = "验证提示"
        XCTAssertEqual(changes, 2)
        store.account = "fixture"
        XCTAssertEqual(changes, 3)
        subscription.cancel()
    }
    func testRequestedPhoneSizesKeepCardsInsideViewport() {
        let sizes: [(CGFloat, CGFloat)] = [(375, 812), (390, 844), (393, 852), (402, 874), (414, 896), (430, 932)]
        for (width, height) in sizes {
            let layout = AppLayout(width: width, height: height - 93)
            XCTAssertGreaterThanOrEqual(layout.sideInset, 12)
            XCTAssertEqual(layout.cardWidth + layout.sideInset * 2, width)
            XCTAssertGreaterThanOrEqual(layout.noticeInset(bottomSafeArea: 34), 20)
            XCTAssertLessThanOrEqual(layout.noticeInset(bottomSafeArea: 34), 24)
            XCTAssertGreaterThan(layout.cardWidth - 48 - 24 - 10 - 44, 190)
            XCTAssertLessThanOrEqual(layout.previewHeight, height - 93)
        }
    }
    func testLandscapeAndWideWindowsRemainBounded() {
        let landscape = AppLayout(width: 812, height: 290)
        XCTAssertEqual(landscape.contentWidth, 600)
        XCTAssertLessThan(landscape.previewHeight, 290)
        XCTAssertEqual(AppLayout(width: 320, height: 400).cardWidth, 296)
    }
    @MainActor func testNestedLibraryChangesPublishAndUpdateDerivedFavorites() {
        let store = AppStore(inMemory: true)
        store.account = "fixture"
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        store.libraries[store.account, default: Library()].favorites = [Comic(id: "42", title: "收藏更新")]
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(store.favorites.map(\.id), ["42"])
        subscription.cancel()
    }
    @MainActor func testThemeChangesPublishForTraditionalAndModernViews() {
        let store = AppStore(inMemory: true)
        var values: [String?] = []
        let subscription = store.$preferences.sink { values.append($0.themeColor) }
        store.preferences.themeColor = "蓝"
        XCTAssertEqual(values.last!, "蓝")
        subscription.cancel()
    }
    @MainActor func testFractionalPagingReportsNoticePositionBeforeSelectingNextTab() {
        let paging = LibraryPagingPosition()
        let pager = LibraryPagerController()
        pager.onPosition = { paging.report($0) }
        var selections: [Int] = []
        pager.onSelection = { selections.append($0) }
        pager.update(pages: LibraryTab.allCases.map { AnyView(Text($0.rawValue)) }, selectedIndex: 1, animated: false)
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 560)
        pager.view.layoutIfNeeded()
        let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first!
        scroll.setContentOffset(CGPoint(x: 390 * 1.25, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 1.25, accuracy: 0.001)
        XCTAssertTrue(selections.isEmpty)
        scroll.setContentOffset(CGPoint(x: 390 * 1.75, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 1.75, accuracy: 0.001)
        XCTAssertTrue(selections.isEmpty)
        scroll.setContentOffset(CGPoint(x: 780, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(selections, [2])
    }
    @MainActor func testCancelledPagingRestoresNoticePositionAcrossViewportChanges() {
        let paging = LibraryPagingPosition()
        let pager = LibraryPagerController()
        pager.onPosition = { paging.report($0) }
        var selections: [Int] = []
        pager.onSelection = { selections.append($0) }
        pager.update(pages: LibraryTab.allCases.map { AnyView(Text($0.rawValue)) }, selectedIndex: 1, animated: false)
        pager.view.frame = CGRect(x: 0, y: 0, width: 375, height: 560); pager.view.layoutIfNeeded()
        let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first!
        scroll.setContentOffset(CGPoint(x: 375 * 1.4, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 1.4, accuracy: 0.001)
        scroll.setContentOffset(CGPoint(x: 375, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(paging.positions.value, 1); XCTAssertTrue(selections.isEmpty)
        pager.view.frame.size.width = 430; pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        XCTAssertEqual(paging.positions.value, 1)
        scroll.setContentOffset(CGPoint(x: -20, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 0)
        scroll.setContentOffset(CGPoint(x: 430 * 3, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 2)
    }
}
