import XCTest
@testable import JMDownloader

final class LibraryComicFilterTests: XCTestCase {
    @MainActor func testCachedFavoritesFollowDownloadHiddenFolderAndSearchChanges() {
        let a = Comic(id: "1", title: "A", folders: ["one"])
        let b = Comic(id: "2", title: "B", folders: ["two"])
        let cache = LibraryComicFilterCache()
        var input = LibraryComicFilter(comics: [a, b], recommendations: false)
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1", "2"])
        input.downloaded = [DownloadCatalog.key(a)]
        XCTAssertEqual(cache.value(for: input).map(\.id), ["2"])
        input.visibility = .downloaded
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1"])
        input.hidden = [DownloadCatalog.key(a)]; input.visibility = .hidden
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1"])
        input.folder = "two"
        XCTAssertTrue(cache.value(for: input).isEmpty)
        input.isSearch = true
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1", "2"])
    }
    @MainActor func testCachedRecommendationsFollowExclusionAndBlacklistChanges() {
        let a = Comic(id: "1", title: "A", tags: ["AI绘图"])
        let b = Comic(id: "2", title: "名侦探", tags: ["剧情"])
        let cache = LibraryComicFilterCache()
        var input = LibraryComicFilter(comics: [a, b], recommendations: true)
        input.excluded = [DownloadCatalog.key(a)]
        XCTAssertEqual(cache.value(for: input).map(\.id), ["2"])
        input.pendingDislikes = input.excluded
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1", "2"])
        input.tagBlacklist = ["ai"]
        XCTAssertEqual(cache.value(for: input).map(\.id), ["2"])
        input.titleBlacklist = ["侦探"]
        XCTAssertTrue(cache.value(for: input).isEmpty)
        input.isSearch = true
        XCTAssertEqual(cache.value(for: input).map(\.id), ["1", "2"])
    }
}
