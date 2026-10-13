import XCTest
@testable import JMDownloader

private actor LibraryLoadingProbe: ComicAPI {
    var failFavorites = true
    var failSearch = true
    var recommendationCalls = 0
    func recover() { failFavorites = false; failSearch = false }
    func calls() -> Int { recommendationCalls }
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] {
        try await Task.sleep(for: .milliseconds(15))
        if failFavorites { throw URLError(.notConnectedToInternet) }
        return [Comic(id: "fresh", title: "fresh", tags: ["剧情"])]
    }
    func search(_ query: String, page: Int) async throws -> [Comic] {
        if failSearch { throw JMError.authenticationExpired }
        return [Comic(id: "searched", title: "searched")]
    }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] {
        recommendationCalls += 1
        return [Comic(id: "fresh-result", title: "fresh-result")]
    }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
}

final class LibraryLoadingTests: XCTestCase {
    @MainActor func testFailedFavoriteRefreshKeepsCacheAndCannotRankStaleFavorites() async throws {
        let store = AppStore(inMemory: true), api = LibraryLoadingProbe()
        store.log("download-only")
        store.account = "fixture"; store.clients[store.account] = api
        let cached = Comic(id: "cached", title: "cached")
        store.libraries[store.account] = Library(favorites: [cached])
        store.recommendations = [cached]
        store.refreshFavorites(silently: true); store.loadRecommendations(silently: true)
        for _ in 0..<100 {
            if !store.refreshing && !store.recommending { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.favoriteFailure); XCTAssertNotNil(store.recommendationFailure)
        XCTAssertEqual(store.recommendations.map(\.id), ["cached"])
        let calls = await api.calls(); XCTAssertEqual(calls, 0)
        await api.recover()
        store.loadRecommendations(silently: true)
        for _ in 0..<100 {
            if !store.refreshing && !store.recommending { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(store.favoriteFailure); XCTAssertNil(store.recommendationFailure)
        XCTAssertEqual(store.recommendations.map(\.id), ["fresh-result"])
        XCTAssertEqual(store.favorites.map(\.id), ["fresh"])
        let retryCalls = await api.calls(); XCTAssertEqual(retryCalls, 1)
        XCTAssertEqual(store.logs.map(\.text), ["download-only"])
    }
    @MainActor func testSearchSessionExpiryHasOwnFailureStateAndRetryClearsIt() async throws {
        let store = AppStore(inMemory: true), api = LibraryLoadingProbe()
        store.account = "fixture"; store.clients[store.account] = api; store.preferences.remember = false
        store.recommendations = [Comic(id: "cached", title: "cached")]
        store.search("tag")
        for _ in 0..<100 { if !store.searching { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(store.searchFailure); XCTAssertNil(store.recommendationFailure); XCTAssertNil(store.alert)
        await api.recover(); store.search("tag")
        for _ in 0..<100 { if !store.searching { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(store.searchFailure); XCTAssertEqual(store.searchResults.map(\.id), ["searched"])
        XCTAssertEqual(store.recommendations.map(\.id), ["cached"])
        store.cancelSearch(); XCTAssertNil(store.searchFailure)
        XCTAssertTrue(store.logs.isEmpty)
    }
}
