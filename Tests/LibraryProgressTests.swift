import XCTest
@testable import JMDownloader

private actor LibraryProgressProbe {
    var updates: [LibraryLoadProgress] = []
    var batches: [[String]] = []
    var slowFinished = false
    var receivedBeforeSlowFinished = false
    func progress(_ update: LibraryLoadProgress) { updates.append(update) }
    func results(_ comics: [Comic]) {
        batches.append(comics.map(\.id))
        if !slowFinished && !comics.isEmpty { receivedBeforeSlowFinished = true }
    }
    func detail(_ comic: Comic) async throws -> Comic {
        if comic.id == "slow" {
            try await Task.sleep(for: .milliseconds(80))
            slowFinished = true
        }
        return comic
    }
    func snapshot() -> ([LibraryLoadProgress], [[String]], Bool) { (updates, batches, receivedBeforeSlowFinished) }
}

private final class SortProgressProtocol: URLProtocol {
    static let lock = NSLock()
    static var orders: [String] = []
    static func record(_ value: String) { lock.lock(); defer { lock.unlock() }; orders.append(value) }
    static func reset() { lock.lock(); defer { lock.unlock() }; orders = [] }
    static func values() -> [String] { lock.lock(); defer { lock.unlock() }; return orders }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var data: [String: Any] = ["id": "999", "name": "fixture", "tags": ["剧情"]]
        if url.path == "/search" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            Self.record(query.first(where: { $0.name == "o" })!.value!)
            data = ["content": [["id": "999", "name": "fixture"]]]
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["code": 200, "data": data])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class LibraryProgressTests: XCTestCase {
    func testPDFDisplayProgressUsesRenderedPagesAndRestartsSeparately() {
        let page = PageAsset(url: URL(string: "https://fixture.invalid/a")!, chapterID: "0", filename: "a", scrambleID: Int.max)
        var job = DownloadJob(owner: "fixture", comic: Comic(id: "1", title: "fixture"), state: .downloading, pages: Array(repeating: page, count: 26), finished: Set(0..<13))
        XCTAssertEqual(job.displayProgress, 0.5)
        XCTAssertEqual(job.progressLabel, "13 / 26 张")
        job.finished = Set(0..<26); job.state = .exporting; job.renderedPages = 0
        XCTAssertEqual(job.displayProgress, 0)
        XCTAssertEqual(job.progressLabel, "0%")
        job.renderedPages = 13
        XCTAssertEqual(job.displayProgress, 0.5)
        XCTAssertEqual(job.progressLabel, "50%")
        job.renderedPages = 26
        XCTAssertEqual(job.progressLabel, "99%") // Publication is still pending.
    }
    func testDeadlineCancelsSlowLoadInsteadOfLeavingSpinnerRunning() async throws {
        do {
            let _: [Comic] = try await LibraryLoadDeadline.run(seconds: 0.025) {
                try await Task.sleep(for: .seconds(10))
                return []
            }
            XCTFail("Expected request deadline")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }
    func testValidResultsAndProgressArriveBeforeSlowCandidateCompletes() async throws {
        let probe = LibraryProgressProbe()
        let favorite = Comic(id: "favorite", title: "favorite", tags: ["剧情"])
        let rows = [Comic(id: "fast", title: "fast", tags: ["剧情"]), Comic(id: "slow", title: "slow", tags: ["剧情"])]
        let result = try await RecommendationRanking.recommendations(from: [favorite], blacklist: [], detail: { try await probe.detail($0) }, search: { _ in rows }, progress: { await probe.progress($0) }, results: { await probe.results($0) })
        let (updates, batches, early) = await probe.snapshot()
        XCTAssertTrue(early)
        XCTAssertEqual(batches.first, ["fast"])
        XCTAssertEqual(result.map(\.id), ["fast", "slow"])
        XCTAssertTrue(updates.contains { $0.stage == "核验推荐漫画" && $0.completed == 1 && $0.total == 2 })
        XCTAssertEqual(updates.last?.percent, 99)
    }
    func testEveryJMRecommendationSortUsesRequestedOrderAndReturnsVerifiedTags() async throws {
        SortProgressProtocol.reset()
        var preferences = Preferences(); preferences.domains = "sort.invalid"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SortProgressProtocol.self]
        let api = try JMAPI(preferences: preferences, configuration: config)
        for sort in RecommendationSort.allCases {
            let result = try await api.recommendations(from: [Comic(id: "123", title: "favorite")], sort: sort)
            XCTAssertEqual(result.map(\.id), ["999"])
            XCTAssertEqual(result.first?.tags, ["剧情"])
        }
        XCTAssertEqual(SortProgressProtocol.values(), ["mr", "tf", "mv", "mv"])
    }
}
