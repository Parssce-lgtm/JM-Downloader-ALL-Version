import XCTest
@testable import JMDownloader

private final class RouteProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.record(request)
        if request.url?.host == "timeout.invalid" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let payload = request.url?.path == "/login"
            ? #"{"code":200,"data":{"uid":"fixture","s":"test-session"}}"#
            : #"{"code":200,"data":{"jm3_version":"2.1.7","list":[],"total":0}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor RecommendationProbe: ComicAPI {
    var calls: [RecommendationSort] = []
    func orders() -> [RecommendationSort] { calls }
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] { [] }
    func search(_ query: String, page: Int) async throws -> [Comic] { [] }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] { [] }
    func recommendations(from favorites: [Comic], sort: RecommendationSort) async throws -> [Comic] {
        calls.append(sort)
        // Deliberately ignore cancellation to verify old responses cannot overwrite a new sort.
        try? await Task.sleep(for: .milliseconds(sort == .latest ? 150 : 10))
        return [Comic(id: sort == .latest ? "1" : "2", title: sort.rawValue)]
    }
}

final class NetworkRoutingTests: XCTestCase {
    func testPicaModernAndLegacyMediaRoutes() throws {
        let transformed = try PicaAPI.mediaURL(["fileServer": "https://storage1.picacomic.com", "path": "tobeimg/rs:fill:300:400/a.jpg"])
        XCTAssertEqual(transformed.absoluteString, "https://img.picacomic.com/rs:fill:300:400/a.jpg")
        let legacy = MediaRequest.picaURLs(URL(string: "https://storage-b.picacomic.com/static/static/tobs/a.jpg")!)
        XCTAssertEqual(legacy.first?.absoluteString, "https://storage-b.picacomic.com/static/a.jpg")
        XCTAssertEqual(legacy.count, 4)
        XCTAssertEqual(Set(legacy.map(\.path)), ["/static/a.jpg"])
        let custom = URL(string: "https://custom.invalid/static/a.jpg")!
        XCTAssertEqual(MediaRequest.picaURLs(custom), [custom])
    }
    func testPicaMediaRequestsNeverIncludeAccountHeaders() {
        let request = MediaRequest.make(url: URL(string: "https://img.picacomic.com/a.jpg")!, platform: .picacg, preferences: Preferences())
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "okhttp/3.8.1")
        XCTAssertTrue(MediaRequest.canRetry(ImageHTTPError(status: 403)))
        XCTAssertFalse(MediaRequest.canRetry(ImageHTTPError(status: 401)))
        XCTAssertFalse(MediaRequest.canRetry(CancellationError()))
    }
    func testJMPinnedTimeoutFallsBackWithoutLeakingCookie() async throws {
        RouteProtocol.reset()
        var preferences = Preferences(); preferences.domains = "timeout.invalid,healthy.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RouteProtocol.self]
        let api = try JMAPI(preferences: preferences, savedSession: ServiceSession(platform: .jmcomic, host: "timeout.invalid", cookies: ["AVS": "test-old-cookie"]), configuration: config)
        do { _ = try await api.favorites(); XCTFail("Changed backend must renew its session") }
        catch JMError.authenticationExpired { }
        let requests = RouteProtocol.recorded()
        XCTAssertEqual(requests.map { $0.url!.host! }, ["timeout.invalid", "healthy.invalid"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "AVS=test-old-cookie")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    }
    func testJMLoginUsesHealthyBackupAfterTimeout() async throws {
        RouteProtocol.reset()
        var preferences = Preferences(); preferences.domains = "timeout.invalid,healthy.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RouteProtocol.self]
        let api = try JMAPI(preferences: preferences, configuration: config)
        try await api.login(username: "fixture", password: "fixture")
        let saved = await api.savedSession()
        XCTAssertEqual(saved?.host, "healthy.invalid")
        XCTAssertEqual(saved?.cookies["AVS"], "test-session")
    }

    @MainActor func testBlacklistIsFuzzyAndDoesNotCrossPlatforms() {
        let store = AppStore(inMemory: true)
        var prefs = store.preferences; prefs.tagBlacklist = "AI绘"; store.preferences = prefs
        let blocked = Comic(id: "1", title: "blocked", tags: ["AI绘图"], platform: .jmcomic)
        let allowed = Comic(id: "2", title: "allowed", tags: ["真人", "剧情"], platform: .jmcomic)
        XCTAssertTrue(store.isBlocked(blocked)); XCTAssertFalse(store.isBlocked(allowed))
    }

    @MainActor func testStartupPreloadsRecommendationsAndNewSortWins() async throws {
        let store = AppStore(inMemory: true), api = RecommendationProbe()
        store.account = "fixture"; store.clients[store.account] = api
        store.preferences.recommendationOrder = .latest // Exercise replacement of an older in-flight order.
        store.start()
        for _ in 0..<100 {
            if !(await api.orders()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initial = await api.orders()
        XCTAssertEqual(initial, [.latest])
        store.setRecommendationSort(.likes)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.recommendations.map(\.title), ["最多爱心"])
        XCTAssertFalse(store.recommending)
        XCTAssertEqual(store.preferences.recommendationOrder, .likes)
    }
}

