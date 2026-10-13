import XCTest
import Combine
import SwiftUI
import UIKit
@testable import JMDownloader

final class CompatibilityTests: XCTestCase {
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
    @MainActor func testFractionalPagingMovesIndicatorBeforeSelectingNextTab() {
        let paging = LibraryPagingPosition()
        let tabs = TrackingLibraryTabs(paging: paging)
        tabs.frame = CGRect(x: 0, y: 0, width: 358, height: 34)
        tabs.selectedSegmentIndex = 1; tabs.layoutIfNeeded()
        let pager = LibraryPagerController()
        pager.onPosition = { paging.report($0) }
        var selections: [Int] = []
        pager.onSelection = { selections.append($0); tabs.selectedSegmentIndex = $0 }
        pager.update(pages: LibraryTab.allCases.map { AnyView(Text($0.rawValue)) }, selectedIndex: 1, animated: false)
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 560)
        pager.view.layoutIfNeeded()
        let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first!
        let initial = tabs.indicatorFrame
        scroll.setContentOffset(CGPoint(x: 390 * 1.25, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 1.25, accuracy: 0.001)
        XCTAssertEqual(tabs.indicatorFrame.midX - initial.midX, initial.width / 4, accuracy: 0.5)
        XCTAssertEqual(tabs.selectedSegmentIndex, 1)
        XCTAssertTrue(selections.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: tabs.bounds).image { tabs.layer.render(in: $0.cgContext) }
        let shot = XCTAttachment(image: image); shot.name = "tab-indicator-mid-swipe-25-percent"; shot.lifetime = .keepAlways; add(shot)
        scroll.setContentOffset(CGPoint(x: 390 * 1.75, y: 0), animated: false)
        XCTAssertEqual(tabs.indicatorFrame.midX - initial.midX, initial.width * 0.75, accuracy: 0.5)
        XCTAssertEqual(tabs.selectedSegmentIndex, 1)
        scroll.setContentOffset(CGPoint(x: 780, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(selections, [2]); XCTAssertEqual(tabs.selectedSegmentIndex, 2)
    }
    @MainActor func testCancelledPagingRestoresIndicatorAndResizesWithoutLosingPosition() {
        let paging = LibraryPagingPosition()
        let tabs = TrackingLibraryTabs(paging: paging)
        tabs.frame = CGRect(x: 0, y: 0, width: 351, height: 34)
        tabs.selectedSegmentIndex = 1; tabs.layoutIfNeeded()
        let pager = LibraryPagerController()
        pager.onPosition = { paging.report($0) }
        var selections: [Int] = []
        pager.onSelection = { selections.append($0) }
        pager.update(pages: LibraryTab.allCases.map { AnyView(Text($0.rawValue)) }, selectedIndex: 1, animated: false)
        pager.view.frame = CGRect(x: 0, y: 0, width: 375, height: 560); pager.view.layoutIfNeeded()
        let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first!
        let initial = tabs.indicatorFrame
        scroll.setContentOffset(CGPoint(x: 375 * 1.4, y: 0), animated: false)
        XCTAssertGreaterThan(tabs.indicatorFrame.minX, initial.minX)
        scroll.setContentOffset(CGPoint(x: 375, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(tabs.indicatorFrame, initial); XCTAssertTrue(selections.isEmpty)
        pager.view.frame.size.width = 430; pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        tabs.frame.size.width = 398; tabs.layoutIfNeeded()
        XCTAssertEqual(paging.positions.value, 1)
        XCTAssertEqual(tabs.indicatorFrame.midX, tabs.bounds.midX, accuracy: 0.5)
        scroll.setContentOffset(CGPoint(x: -20, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 0)
        XCTAssertGreaterThanOrEqual(tabs.indicatorFrame.minX, 0)
        scroll.setContentOffset(CGPoint(x: 430 * 3, y: 0), animated: false)
        XCTAssertEqual(paging.positions.value, 2)
        XCTAssertLessThanOrEqual(tabs.indicatorFrame.maxX, tabs.bounds.maxX)
    }
}
