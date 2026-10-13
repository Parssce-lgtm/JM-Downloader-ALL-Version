import XCTest
@testable import JMDownloader

private actor SearchAndFavoritesProbe: ComicAPI {
    var seeds: [[String]] = []
    var overrides: [[String]] = []
    var pending: [String: CheckedContinuation<[Comic], Error>] = [:]
    func recordedSeeds() -> [[String]] { seeds }
    func recordedOverrides() -> [[String]] { overrides }
    func hasPending(_ query: String) -> Bool { pending[query] != nil }
    func finish(_ query: String) { pending.removeValue(forKey: query)?.resume(returning: [Comic(id: query, title: query)]) }
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] {
        try await Task.sleep(for: .milliseconds(40))
        return [Comic(id: "fresh", title: "fresh", tags: ["剧情"])]
    }
    func search(_ query: String, page: Int) async throws -> [Comic] {
        try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] { favorites }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String]) async throws -> [Comic] {
        seeds.append(favorites.map(\.id)); overrides.append(preferredTags)
        return [Comic(id: "recommended", title: "推荐")]
    }
}

final class RecommendationTests: XCTestCase {
    func testMissingFavoriteTagsDoNotBlockValidFavorites() async throws {
        let favorites = [Comic(id: "missing", title: "missing"), Comic(id: "valid", title: "valid", tags: ["剧情"])]
        let candidate = Comic(id: "candidate", title: "candidate", tags: ["剧情"])
        let result = try await RecommendationRanking.recommendations(from: favorites, blacklist: [], detail: {
            if $0.id == "missing" { throw RecommendationDetailUnavailable() }
            return $0
        }, search: { _ in [candidate] })
        XCTAssertEqual(result.map(\.id), ["candidate"])
    }
    func testAllFavoriteDetailsUnavailableReportsFailure() async throws {
        do {
            _ = try await RecommendationRanking.recommendations(from: [Comic(id: "missing", title: "missing")], blacklist: [],
                detail: { _ in throw RecommendationDetailUnavailable() }, search: { _ in [] })
            XCTFail("Unavailable details must not appear as an empty successful feed")
        } catch is RecommendationDetailUnavailable { }
    }
    func testOneFailedSeedDoesNotDiscardOtherSeedResults() async throws {
        let favorite = Comic(id: "favorite", title: "favorite", tags: ["冒险", "剧情"])
        let candidate = Comic(id: "candidate", title: "candidate", tags: ["剧情"])
        let result = try await RecommendationRanking.recommendations(from: [favorite], blacklist: [], detail: { $0 }, search: {
            if $0 == "冒险" { throw URLError(.timedOut) }
            return [candidate]
        })
        XCTAssertEqual(result.map(\.id), ["candidate"])
    }
    func testAllSeedsFailReportsNetworkFailure() async throws {
        do {
            _ = try await RecommendationRanking.recommendations(from: [Comic(id: "favorite", title: "favorite", tags: ["剧情", "冒险"])],
                blacklist: [], detail: { $0 }, search: { _ in throw URLError(.notConnectedToInternet) })
            XCTFail("All failed searches must not appear as an empty successful feed")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
    }
    func testSeedSessionExpiryStillRequestsRenewal() async throws {
        do {
            _ = try await RecommendationRanking.recommendations(from: [Comic(id: "favorite", title: "favorite", tags: ["剧情", "冒险"])],
                blacklist: [], detail: { $0 }, search: {
                    if $0 == "冒险" { throw JMError.authenticationExpired }
                    return [Comic(id: "candidate", title: "candidate", tags: ["剧情"])]
                })
            XCTFail("Session expiry must propagate even when another search succeeds")
        } catch JMError.authenticationExpired { }
    }
    func testFavoriteNetworkFailureCannotSilentlyChangeTasteWeights() async throws {
        do {
            _ = try await RecommendationRanking.recommendations(from: [Comic(id: "offline", title: "offline")],
                blacklist: [], detail: { _ in throw URLError(.timedOut) }, search: { _ in [] })
            XCTFail("Transport failures must not be treated as missing tags")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }
    func testFullCandidateTagsDetermineRankingAndBlacklist() async throws {
        let favorites = [Comic(id: "f1", title: "f1"), Comic(id: "f2", title: "f2")]
        let details = [
            "f1": ["剧情", "剧情", "冒险", "中文"], "f2": ["剧情"],
            "multi": ["剧情", "冒险"], "single": ["剧情"],
            "unrelated": ["科幻"], "blocked": ["剧情", "AI绘图"]
        ]
        let rows = ["unrelated", "blocked", "single", "multi"].map { Comic(id: $0, title: $0) }
        let result = try await RecommendationRanking.recommendations(from: favorites, blacklist: ["ai"], detail: { comic in
            var full = comic; full.tags = details[comic.id] ?? []; return full
        }, search: { _ in rows })
        XCTAssertEqual(result.map(\.id), ["multi", "single"])
        XCTAssertTrue(result.allSatisfy { $0.reason.contains("收藏标签匹配") })
        XCTAssertEqual(result.first?.tags, ["剧情", "冒险"])
    }
    func testEmptyFavoritesNeverFallBackToUnrelatedFeed() async throws {
        let result = try await RecommendationRanking.recommendations(from: [], blacklist: [], detail: { _ in
            throw JMError.message("Unexpected detail request")
        }, search: { _ in throw JMError.message("Unexpected search request") })
        XCTAssertTrue(result.isEmpty)
    }
    func testDuplicateFavoriteAndTagCannotSkewRanking() async throws {
        let favorite = Comic(id: "f", title: "f", tags: ["冒险", "冒险", "冒险", "剧情"])
        let candidates = [Comic(id: "story", title: "story", tags: ["剧情"]), Comic(id: "adventure", title: "adventure", tags: ["冒险"])]
        let result = try await RecommendationRanking.recommendations(from: [favorite, favorite], blacklist: [], detail: { $0 }, search: { _ in candidates })
        XCTAssertEqual(result.map(\.id), ["story", "adventure"])
    }
    @MainActor func testRecommendationWaitsForFreshFavoritesAndIgnoresLegacyTags() async throws {
        let api = SearchAndFavoritesProbe(), store = AppStore(inMemory: true)
        store.account = "fixture"; store.clients[store.account] = api
        store.preferences.recommendationTags = ["obsolete"]
        store.refreshFavorites(silently: true); store.loadRecommendations(silently: true)
        for _ in 0..<100 {
            if !store.recommending && !store.refreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let seeds = await api.recordedSeeds(), overrides = await api.recordedOverrides()
        XCTAssertEqual(seeds, [["fresh"]]); XCTAssertEqual(overrides, [[]])
        XCTAssertEqual(store.recommendations.map(\.id), ["recommended"])
    }
    @MainActor func testSearchCancellationDoesNotChangeNewSearchOrRecommendations() async throws {
        let api = SearchAndFavoritesProbe(), store = AppStore(inMemory: true)
        store.account = "fixture"; store.clients[store.account] = api
        store.recommendations = [Comic(id: "recommended", title: "推荐")]
        store.search("old")
        for _ in 0..<100 { if await api.hasPending("old") { break }; try await Task.sleep(for: .milliseconds(5)) }
        store.search("new")
        for _ in 0..<100 { if await api.hasPending("new") { break }; try await Task.sleep(for: .milliseconds(5)) }
        await api.finish("old")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.searching); XCTAssertTrue(store.searchResults.isEmpty)
        await api.finish("new")
        for _ in 0..<100 { if !store.searching { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.searchResults.map(\.id), ["new"])
        store.cancelSearch()
        XCTAssertFalse(store.searching); XCTAssertTrue(store.searchResults.isEmpty)
        XCTAssertEqual(store.recommendations.map(\.id), ["recommended"])
    }
}
