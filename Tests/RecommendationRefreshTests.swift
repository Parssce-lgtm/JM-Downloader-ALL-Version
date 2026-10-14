import XCTest
@testable import JMDownloader

private final class TagCatalogProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let id = query.first { $0.name == "id" }?.value ?? ""
        let tags = ["200": ["别的"], "201": ["剧情", "校园"], "202": ["剧情扩展", "校园"], "203": ["无关"],
                    "204": ["純愛", "彩漫"], "205": ["純愛", "彩漫扩展"]][id] ?? ["剧情"]
        var rows = [["id": "200", "name": "剧情标题但没有该标签"], ["id": "201", "name": "真正含标签"], ["id": "202", "name": "仅含相似标签"]]
        let searchQuery = query.first { $0.name == "search_query" }?.value ?? ""
        if searchQuery.contains("+") && (searchQuery.contains("纯爱") || searchQuery.contains("純愛")) {
            // A broad first-tag page has no matching comic. The combined
            // traditional query finds one on the server, plus a partial tag.
            rows = searchQuery.contains("純愛")
                ? [["id": "204", "name": "正确的双标签漫画"], ["id": "205", "name": "相似标签漫画"]] : []
        }
        if query.first(where: { $0.name == "main_tag" })?.value == "0" {
            rows.append(["id": "203", "name": "服务器混入的无关漫画"])
        }
        let data: [String: Any] = url.path == "/search"
            ? ["content": rows]
            : ["id": id, "name": "fixture", "tags": tags]
        let payload = try! JSONSerialization.data(withJSONObject: ["code": 200, "data": data])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
private actor RankingBatchProbe {
    var batches: [[String]] = []
    var active = 0, peak = 0
    func detail(_ comic: Comic) async throws -> Comic {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        return comic
    }
    func results(_ comics: [Comic]) { batches.append(comics.map(\.id)) }
    func snapshot() -> ([[String]], Int) { (batches, peak) }
}
private actor DefaultOrderProbe: ComicAPI {
    var orders: [RecommendationSort] = []
    var queries: [String] = []
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] { [] }
    func search(_ query: String, page: Int) async throws -> [Comic] { queries.append("text:" + query); return [] }
    func searchTag(_ tag: String, page: Int) async throws -> [Comic] { queries.append("tag:" + tag); return [] }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] { [] }
    func recommendations(from favorites: [Comic], sort: RecommendationSort) async throws -> [Comic] {
        orders.append(sort); return []
    }
    func recorded() -> [RecommendationSort] { orders }
    func recordedQueries() -> [String] { queries }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
}
final class RecommendationRefreshTests: XCTestCase {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    func testTagCacheSurvivesNewInstancesAndKeepsAccountsAndPlatformsSeparate() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let jm = Comic(id: "same", title: "JM"), pica = Comic(id: "same", title: "Pica", platform: .picacg)
        let first = ComicTagCache.persistent(account: "a", root: root)
        await first.store(["剧情"], for: jm); await first.store([], for: pica)
        let restored = ComicTagCache.persistent(account: "a", root: root)
        let jmTags = await restored.tags(for: jm), picaTags = await restored.tags(for: pica)
        XCTAssertEqual(jmTags, ["剧情"]); XCTAssertEqual(picaTags, [])
        let other = await ComicTagCache.persistent(account: "b", root: root).tags(for: jm)
        XCTAssertNil(other)
    }
    func testSixtyFavoritesOnlyReadNewTagsAfterRestartAndRefresh() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var preferences = Preferences(); preferences.domains = "tags.invalid"
        func client() throws -> JMAPI {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TagCatalogProtocol.self]
            return try JMAPI(preferences: preferences, configuration: config, tagCache: .persistent(account: "fixture", root: root))
        }
        TagCatalogProtocol.reset()
        let favorites = (1...60).map { Comic(id: "\($0)", title: "Favorite \($0)") }
        let initial = try await client().recommendations(from: favorites, sort: .likes)
        XCTAssertEqual(initial.map(\.id), ["201"])
        XCTAssertEqual(TagCatalogProtocol.recorded().filter { $0.url?.path == "/album" }.count, 63)
        TagCatalogProtocol.reset()
        let restarted = try client()
        _ = try await restarted.recommendations(from: favorites, sort: .likes)
        XCTAssertTrue(TagCatalogProtocol.recorded().allSatisfy { $0.url?.path != "/album" })
        TagCatalogProtocol.reset()
        _ = try await restarted.recommendations(from: favorites + [Comic(id: "61", title: "New")], sort: .likes)
        let reads = TagCatalogProtocol.recorded().filter { $0.url?.path == "/album" }
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(reads[0].url!.absoluteString.contains("id=61"))
    }
    func testExactTagSearchUsesTagEndpointAndExcludesTitleAndPartialTagMatches() async throws {
        TagCatalogProtocol.reset()
        var preferences = Preferences(); preferences.domains = "tags.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TagCatalogProtocol.self]
        let api = try JMAPI(preferences: preferences, configuration: config)
        let exact = try await api.searchTag("剧情", page: 1)
        XCTAssertEqual(exact.map(\.id), ["201"])
        let exactRequest = TagCatalogProtocol.recorded().first { $0.url?.path == "/search" }!
        let exactQuery = URLComponents(url: exactRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(exactQuery.first { $0.name == "main_tag" }?.value, "3")
        TagCatalogProtocol.reset()
        let broad = try await api.search("剧情", page: 1)
        XCTAssertEqual(broad.map(\.id), ["200", "201", "202"])
        let broadQuery = URLComponents(url: TagCatalogProtocol.recorded()[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(broadQuery.first { $0.name == "main_tag" }?.value, "0")
    }
    func testSearchQueryAndExactTagsNormalizeCaseWidthAndWhitespace() {
        XCTAssertEqual(ComicSearchQuery("  #AI绘图  "), .tag("AI绘图"))
        XCTAssertEqual(ComicSearchQuery("＃剧情"), .tag("剧情"))
        XCTAssertEqual(ComicSearchQuery("剧情"), .text("剧情"))
        let comic = Comic(id: "1", title: "AI", tags: ["ＡＩ绘图", "剧情扩展"])
        XCTAssertTrue(ComicSearchQuery.hasTag(comic, "ai绘图"))
        XCTAssertFalse(ComicSearchQuery.hasTag(comic, "剧情"))
        XCTAssertFalse(ComicSearchQuery.hasTag(comic, "AI"))
    }
    func testJMMultipleTagsVerifyCompleteMetadataAndExcludePartialMatches() async throws {
        var preferences = Preferences(); preferences.domains = "tags.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TagCatalogProtocol.self]
        let api = try JMAPI(preferences: preferences, configuration: config)
        let result = try await ComicSearchQuery("剧情+校园").results(using: api, page: 1)
        XCTAssertEqual(result.map(\.id), ["201"])
    }
    func testJMMultipleTagsSearchAllTermsAndTraditionalVariant() async throws {
        TagCatalogProtocol.reset()
        var preferences = Preferences(); preferences.domains = "tags.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TagCatalogProtocol.self]
        let api = try JMAPI(preferences: preferences, configuration: config)
        for input in ["纯爱+彩漫", "#纯爱+#彩漫"] {
            let results = try await ComicSearchQuery(input).results(using: api, page: 1)
            XCTAssertEqual(results.map(\.id), ["204"])
        }
        let queries = TagCatalogProtocol.recorded().filter { $0.url?.path == "/search" }.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "search_query" }!.value!
        }
        XCTAssertTrue(queries.contains("+纯爱 +彩漫"))
        XCTAssertTrue(queries.contains("+純愛 +彩漫"))
        XCTAssertFalse(queries.contains("纯爱"), "Never page through only the first broad tag")
    }
    func testLargeRecommendationFeedIsCompleteButPublishedInBatches() async throws {
        let probe = RankingBatchProbe()
        let favorite = Comic(id: "favorite", title: "Favorite", tags: ["剧情"], tagsVerified: true)
        let candidates = (1...120).map { Comic(id: "\($0)", title: "Candidate \($0)", tags: ["剧情"]) }
        let result = try await RecommendationRanking.recommendations(from: [favorite], blacklist: [],
            detail: { try await probe.detail($0) }, search: { _ in candidates }, results: { await probe.results($0) }, detailConcurrency: 6)
        let (batches, peak) = await probe.snapshot()
        XCTAssertEqual(result.map(\.id), candidates.map(\.id))
        XCTAssertEqual(batches.last, result.map(\.id))
        XCTAssertGreaterThan(batches.count, 1); XCTAssertLessThan(batches.count, 30)
        XCTAssertLessThanOrEqual(peak, 6)
        XCTAssertLessThan(batches.first!.count, result.count)
    }
    func testVerifiedFavoriteTagsDoNotRequestDetailsAgain() async throws {
        let favorite = Comic(id: "favorite", title: "Favorite", tags: ["剧情"], tagsVerified: true)
        let candidate = Comic(id: "candidate", title: "Candidate", tags: ["剧情"])
        let result = try await RecommendationRanking.recommendations(from: [favorite], blacklist: [], detail: { comic in
            if comic.id == "favorite" { throw JMError.message("Verified favorite must be reused") }
            return comic
        }, search: { _ in [candidate] })
        XCTAssertEqual(result.map(\.id), ["candidate"])
    }
    func testOnlyTransportErrorsUseNetworkFailureStatus() {
        XCTAssertEqual(LibraryFailureKind.classify(URLError(.timedOut)), .network)
        XCTAssertEqual(LibraryFailureKind.classify(JMTransportError(host: "fixture", underlying: URLError(.notConnectedToInternet))), .network)
        XCTAssertEqual(LibraryFailureKind.classify(JMError.authenticationExpired), .load)
        XCTAssertEqual(LibraryFailureKind.classify(RecommendationDetailUnavailable()), .load)
        XCTAssertEqual(LibraryFailureKind.classify(JMError.message("接口数据不完整")), .load)
    }
    @MainActor func testTitleBlacklistIsFuzzyAndKeepsOrdinaryComics() {
        let store = AppStore(inMemory: true)
        store.preferences.titleBlacklist = "侦探，猫\nABC"
        XCTAssertTrue(store.isBlocked(Comic(id: "1", title: "名侦探的故事")))
        XCTAssertTrue(store.isBlocked(Comic(id: "2", title: "ａｂｃ 外传")))
        XCTAssertFalse(store.isBlocked(Comic(id: "3", title: "冒险故事")))
    }
    @MainActor func testExcludedTaskIsSkippedByStartAllAndRequiresConfirmedResume() {
        let store = AppStore(inMemory: true); store.account = "fixture"
        let excluded = Comic(id: "1", title: "Excluded"), normal = Comic(id: "2", title: "Normal")
        store.jobs = [DownloadJob(owner: store.account, comic: excluded, state: .paused), DownloadJob(owner: store.account, comic: normal, state: .paused)]
        store.exclude([excluded]); store.startAll()
        XCTAssertEqual(store.jobs[0].state, .paused); XCTAssertEqual(store.jobs[1].state, .queued)
        let id = store.jobs[0].id
        store.resumeJob(id); XCTAssertEqual(store.jobs[0].state, .paused)
        store.resumeJob(id, confirmedExcluded: true)
        XCTAssertEqual(store.jobs[0].state, .queued); XCTAssertEqual(store.jobs[0].exclusionApproved, true)
        store.engine.pause(id); store.startAll()
        XCTAssertEqual(store.jobs[0].state, .paused, "Even a previously confirmed task is skipped by All Start")
    }
    @MainActor func testDislikedComicStaysDimmedUntilRefreshAndCanBeRestored() {
        let store = AppStore(inMemory: true); store.account = "fixture"
        let comic = Comic(id: "1", title: "Disliked")
        store.clients[store.account] = DefaultOrderProbe()
        store.recommendations = [comic]; store.exclude([comic], disliked: true)
        XCTAssertEqual(store.recommendations, [comic]); XCTAssertEqual(store.excluded, [comic])
        XCTAssertTrue(store.isPendingDislike(comic)); XCTAssertTrue(store.isDisliked(comic))
        store.loadRecommendations()
        XCTAssertTrue(store.recommendations.isEmpty); XCTAssertFalse(store.isPendingDislike(comic))
        store.restoreAutomatic(comic); XCTAssertFalse(store.isAutomaticExcluded(comic))
        XCTAssertFalse(store.isDisliked(comic))
    }
    func testFavoriteVisibilityKeepsOnlyOneStatusAndCanShowHiddenDownloadedComic() {
        XCTAssertTrue(FavoriteVisibility.regular.includes(downloaded: false, hidden: false))
        XCTAssertFalse(FavoriteVisibility.regular.includes(downloaded: true, hidden: false))
        XCTAssertFalse(FavoriteVisibility.regular.includes(downloaded: false, hidden: true))
        XCTAssertTrue(FavoriteVisibility.downloaded.includes(downloaded: true, hidden: false))
        XCTAssertFalse(FavoriteVisibility.downloaded.includes(downloaded: false, hidden: true))
        XCTAssertFalse(FavoriteVisibility.downloaded.includes(downloaded: true, hidden: true))
        XCTAssertTrue(FavoriteVisibility.hidden.includes(downloaded: true, hidden: true))
        XCTAssertFalse(FavoriteVisibility.hidden.includes(downloaded: false, hidden: false))
    }
    @MainActor func testHiddenMetadataSurvivesServerFavoriteRemovalAndLegacySnapshots() throws {
        let store = AppStore(inMemory: true); store.account = "fixture"
        let comic = Comic(id: "1", title: "Hidden", coverURL: URL(string: "https://fixture.invalid/cover"))
        store.libraries[store.account] = Library(favorites: [comic])
        store.hideFavorites([comic]); store.libraries[store.account]?.favorites = []
        let encoded = try JSONEncoder().encode(store.libraries[store.account]!)
        let restored = AppStore(inMemory: true); restored.account = store.account
        restored.libraries[store.account] = try JSONDecoder().decode(Library.self, from: encoded)
        XCTAssertEqual(restored.hiddenComics, [comic]); XCTAssertEqual(restored.restrictedComics, [comic])
        restored.showFavorite(comic); XCTAssertTrue(restored.restrictedComics.isEmpty)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "hiddenComics"); legacy.removeValue(forKey: "dislikedComicKeys")
        restored.libraries[store.account] = try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.hiddenComics.map(\.id), ["1"])
        restored.showFavorite(restored.hiddenComics[0]); XCTAssertTrue(restored.hiddenComics.isEmpty)
    }
    @MainActor func testCombinedRestrictionsRestoreAllReasonsAndStayAccountScoped() {
        let store = AppStore(inMemory: true); store.account = "first"
        let comic = Comic(id: "1", title: "Both reasons")
        store.hideFavorites([comic]); store.exclude([comic], disliked: true)
        XCTAssertEqual(store.restrictedComics, [comic])
        XCTAssertTrue(store.isHiddenFavorite(comic)); XCTAssertTrue(store.isDisliked(comic))
        store.removeRestrictions(comic)
        XCTAssertTrue(store.restrictedComics.isEmpty); XCTAssertFalse(store.isPendingDislike(comic))
        store.exclude([comic], disliked: true); store.account = "second"
        XCTAssertTrue(store.restrictedComics.isEmpty); XCTAssertTrue(store.pendingDislikedComics.isEmpty)
        store.account = "first"
        XCTAssertEqual(store.restrictedComics, [comic]); XCTAssertTrue(store.isDisliked(comic))
        XCTAssertFalse(store.isPendingDislike(comic), "Feedback in an old account feed must not leak into a new feed")
    }
    @MainActor func testRecommendationDefaultOrderIsLikes() async throws {
        let store = AppStore(inMemory: true), api = DefaultOrderProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.loadRecommendations()
        for _ in 0..<100 { if !store.recommending { break }; try await Task.sleep(for: .milliseconds(5)) }
        let orders = await api.recorded()
        XCTAssertEqual(orders, [.likes]); XCTAssertEqual(store.recommendationSort, .likes)
    }
    @MainActor func testTagAndOrdinarySearchDoNotRestartRecommendations() async throws {
        let store = AppStore(inMemory: true), api = DefaultOrderProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.loadRecommendations()
        for _ in 0..<100 { if !store.recommending { break }; try await Task.sleep(for: .milliseconds(5)) }
        for query in ["#剧情", "剧情"] {
            store.search(query)
            for _ in 0..<100 { if !store.searching { break }; try await Task.sleep(for: .milliseconds(5)) }
        }
        let queries = await api.recordedQueries(), orders = await api.recorded()
        XCTAssertEqual(queries, ["tag:剧情", "text:剧情"])
        XCTAssertEqual(orders, [.likes])
    }
    func testTitleBlacklistPersistsAndLegacyPreferencesStillDecode() throws {
        var preferences = Preferences(); preferences.titleBlacklist = "侦探"
        let encoded = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: encoded).titleBlacklist, "侦探")
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "titleBlacklist")
        let legacy = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.titleBlacklist)
    }
}
