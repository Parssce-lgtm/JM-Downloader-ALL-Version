import XCTest
@testable import JMDownloader

private actor SearchSessionProbe: ComicAPI {
    var pending: [String: CheckedContinuation<[Comic], Error>] = [:]
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] { [] }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] { [] }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
    func search(_ query: String, page: Int) async throws -> [Comic] {
        try await withCheckedThrowingContinuation { pending["\(query):\(page)"] = $0 }
    }
    func has(_ key: String) -> Bool { pending[key] != nil }
    func finish(_ key: String, rows: [Comic]) { pending.removeValue(forKey: key)?.resume(returning: rows) }
    func fail(_ key: String) { pending.removeValue(forKey: key)?.resume(throwing: URLError(.timedOut)) }
}

final class SearchSessionTests: XCTestCase {
    private func wait(_ api: SearchSessionProbe, _ key: String) async throws {
        for _ in 0..<200 { if await api.has(key) { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Search request never started: " + key)
    }
    @MainActor private func settled(_ store: AppStore, _ scope: ComicSearchScope) async throws {
        for _ in 0..<200 { if !store.searchState(scope).searching { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Search request never finished")
    }
    func testMultipleTagGrammarRequiresExactANDWithoutTitleFallback() {
        XCTAssertEqual(ComicSearchQuery("  #剧情 + ＃校园  "), .tags(["剧情", "校园"]))
        XCTAssertEqual(ComicSearchQuery("剧情＋校园+剧情"), .tags(["剧情", "校园", "剧情"]))
        let comic = Comic(id: "1", title: "校园", tags: ["剧情", "校园扩展"])
        XCTAssertTrue(ComicSearchQuery.matchesText(comic, "校园"))
        XCTAssertFalse(ComicSearchQuery.hasTag(comic, "校园"))
    }
    func testMalformedMultipleTagsFailWithoutRequest() async throws {
        let api = SearchSessionProbe()
        for text in ["剧情+", "+校园", "剧情++校园", "#"] {
            do { _ = try await ComicSearchQuery(text).results(using: api, page: 1); XCTFail("Incomplete query must fail") }
            catch JMError.message { }
        }
    }
    @MainActor func testPagesSearchIndependentlyAndCancelOnlyOwnSession() async throws {
        let store = AppStore(inMemory: true), api = SearchSessionProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.search("推荐查询", scope: .recommendations); store.search("收藏查询", scope: .favorites)
        try await wait(api, "推荐查询:1"); try await wait(api, "收藏查询:1")
        await api.finish("推荐查询:1", rows: [Comic(id: "r", title: "推荐查询")])
        await api.finish("收藏查询:1", rows: [Comic(id: "f", title: "收藏查询")])
        try await settled(store, .recommendations); try await settled(store, .favorites)
        store.cancelSearch(scope: .favorites)
        XCTAssertEqual(store.searchState(.recommendations).results.map(\.id), ["r"])
        XCTAssertTrue(store.searchState(.favorites).results.isEmpty)
    }
    @MainActor func testRefreshRetainsResultsAndRecommendationUpdatesCannotReplaceThem() async throws {
        let store = AppStore(inMemory: true), api = SearchSessionProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.search("查询", scope: .recommendations); try await wait(api, "查询:1")
        await api.finish("查询:1", rows: [Comic(id: "found", title: "查询")]); try await settled(store, .recommendations)
        store.search("查询", scope: .recommendations); try await wait(api, "查询:1")
        store.recommendations = [Comic(id: "feed", title: "推荐")]
        XCTAssertEqual(store.searchState(.recommendations).results.map(\.id), ["found"])
        await api.fail("查询:1"); try await settled(store, .recommendations)
        XCTAssertEqual(store.searchState(.recommendations).results.map(\.id), ["found"])
        XCTAssertNotNil(store.searchState(.recommendations).failure)
    }
    @MainActor func testFailedPaginationRetriesSamePageAndDeduplicates() async throws {
        let store = AppStore(inMemory: true), api = SearchSessionProbe()
        store.account = "fixture"; store.clients[store.account] = api
        let first = Comic(id: "1", title: "查询")
        store.search("查询"); try await wait(api, "查询:1")
        await api.finish("查询:1", rows: [first]); try await settled(store, .general)
        store.search("查询", page: 2); try await wait(api, "查询:2")
        await api.fail("查询:2"); try await settled(store, .general)
        XCTAssertEqual(store.searchState().page, 1)
        store.search("查询", page: 2); try await wait(api, "查询:2")
        await api.finish("查询:2", rows: [first, Comic(id: "2", title: "查询"), Comic(id: "2", title: "重复")])
        try await settled(store, .general)
        XCTAssertEqual(store.searchResults.map(\.id), ["1", "2"])
        XCTAssertEqual(store.searchState().page, 2)
    }
    @MainActor func testLogoutInvalidatesEveryScopeIncludingLateResponses() async throws {
        let store = AppStore(inMemory: true), api = SearchSessionProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.search("查询", scope: .recommendations); try await wait(api, "查询:1")
        store.logout()
        await api.finish("查询:1", rows: [Comic(id: "late", title: "旧账号")])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.searchState(.recommendations).results.isEmpty)
        XCTAssertFalse(store.searchState(.recommendations).searching)
    }
}
