import XCTest
import Combine
@testable import JMDownloader

final class CompatibilityTests: XCTestCase {
    func testRequestedPhoneSizesKeepCardsInsideViewport() {
        let sizes: [(CGFloat, CGFloat)] = [(375, 812), (390, 844), (393, 852), (402, 874), (414, 896), (430, 932)]
        for (width, height) in sizes {
            let layout = AppLayout(width: width, height: height - 93)
            XCTAssertGreaterThanOrEqual(layout.sideInset, 12)
            XCTAssertEqual(layout.cardWidth + layout.sideInset * 2, width)
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
}
