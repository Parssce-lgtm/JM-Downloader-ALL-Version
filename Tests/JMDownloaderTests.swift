import XCTest
import UIKit
@testable import JMDownloader

final class JMDownloaderTests: XCTestCase {
    @MainActor func testSaveCommitsDefaultsBeforeReportingSuccess() throws {
        var committed: AppSnapshot?
        let store = AppStore(inMemory: true, snapshotWriter: { committed = $0 })
        var draft = store.preferences
        draft.domains = " "; draft.imageDomain = ""; draft.picaDomain = ""
        draft.concurrency = 9
        store.alert = "Previous unrelated error"
        XCTAssertTrue(store.savePreferences(draft))
        XCTAssertNil(store.alert)
        XCTAssertEqual(committed?.preferences.concurrency, 9)
        XCTAssertEqual(committed?.preferences.domains, Preferences.defaultJMDomains)
        XCTAssertEqual(committed?.preferences.imageDomain, Preferences.defaultImageDomain)
        XCTAssertEqual(committed?.preferences.picaDomain, Preferences.defaultPicaDomain)
        XCTAssertEqual(store.preferences, committed?.preferences)
    }
    @MainActor func testSaveFailureDoesNotApplyDraft() {
        let store = AppStore(inMemory: true, snapshotWriter: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let previous = store.preferences
        var draft = previous; draft.concurrency = 11
        XCTAssertFalse(store.savePreferences(draft))
        XCTAssertEqual(store.preferences, previous)
        XCTAssertTrue(store.alert?.contains("未保存") == true)
    }
    @MainActor func testInvalidSettingsDoNotWriteSnapshot() {
        var writes = 0
        let store = AppStore(inMemory: true, snapshotWriter: { _ in writes += 1 })
        var draft = store.preferences; draft.domains = "http://example.com"
        XCTAssertFalse(store.savePreferences(draft))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.preferences.domains, Preferences.defaultJMDomains)
    }
    func testNetworkErrorsAreSpecificAndDoNotExposePaths() {
        let error = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://example.com/private?token=fixture"])
        let text = NetworkFailure.describe(error)
        XCTAssertTrue(text.contains("DNS")); XCTAssertTrue(text.contains("example.com")); XCTAssertTrue(text.contains("-1003"))
        XCTAssertFalse(text.contains("fixture")); XCTAssertFalse(text.contains("private"))
        XCTAssertTrue(NetworkFailure.describe(URLError(.notConnectedToInternet)).contains("网络权限"))
        XCTAssertTrue(NetworkFailure.describe(URLError(.timedOut)).contains("超时"))
        XCTAssertTrue(NetworkFailure.describe(URLError(.secureConnectionFailed)).contains("TLS"))
    }
    func testPicaSigningAndMediaURL() throws {
        XCTAssertEqual(PicaAPI.signature(route: "auth/sign-in", method: "POST", time: "1700000000", nonce: "fixture"), "d660d9013c4c37ff622b41e3e023ebbf3dd2d678719ca6f4404d02ab7e4c4543")
        XCTAssertEqual(try PicaAPI.mediaURL(["fileServer": "https://example.com", "path": "a/b.jpg"]).absoluteString, "https://example.com/static/a/b.jpg")
        XCTAssertEqual(try PicaAPI.mediaURL(["fileServer": "https://example.com/static/", "path": "a.jpg"]).absoluteString, "https://example.com/static/a.jpg")
        XCTAssertThrowsError(try PicaAPI.mediaURL(["fileServer": "http://example.com", "path": "a.jpg"]))
        XCTAssertThrowsError(try PicaAPI.comicID("../invalid"))
    }
    @MainActor func testPlatformIsolationAndOptionalNetworking() throws {
        let store = AppStore(inMemory: true)
        var preferences = Preferences(); preferences.domains = ""; preferences.imageDomain = ""; preferences.picaDomain = ""
        store.savePreferences(preferences)
        XCTAssertNil(store.alert)
        XCTAssertEqual(store.preferences.effectivePicaDomain, "picaapi.picacomic.com")
        let jm = Comic(id: "123", title: "JM")
        let pica = Comic(id: "0123456789abcdef01234567", title: "Pica", platform: .picacg)
        store.jobs = [DownloadJob(owner: "user", comic: jm), DownloadJob(owner: "picacg:user", comic: pica)]
        XCTAssertEqual(store.visibleJobs.map(\.comic), [jm])
        store.switchPlatform(.picacg)
        XCTAssertEqual(store.visibleJobs.map(\.comic), [pica])
        XCTAssertFalse(store.connected)
        XCTAssertNotEqual(ComicPlatform.jmcomic.accountKey("user"), ComicPlatform.picacg.accountKey("user"))
    }
    @MainActor func testPicaResumePreservesServerAndStalePlatformLoginIsIgnored() async {
        let store = AppStore(inMemory: true)
        let comic = Comic(id: "0123456789abcdef01234567", title: "Pica", platform: .picacg)
        let url = URL(string: "https://example.com/static/page.jpg")!
        let page = PageAsset(url: url, chapterID: "0", filename: "1.jpg", scrambleID: Int.max)
        let job = DownloadJob(owner: "picacg:fixture", comic: comic, state: .paused, pages: [page])
        store.jobs = [job]
        store.engine.resume(job.id)
        XCTAssertEqual(store.jobs[0].pages[0].url, url)
        // A queued login from a previously selected platform must not send credentials to the new platform.
        await store.login(username: "fixture", password: "fixture", platform: .picacg)
        XCTAssertFalse(store.connected)
        XCTAssertNil(store.alert)
    }
    func testVersionOnePreferencesMigration() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        for key in ["picaDomain", "selectedPlatform", "appearance", "themeColor"] { object.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.effectivePicaDomain, Preferences.defaultPicaDomain)
        XCTAssertNil(restored.selectedPlatform)
    }
    func testDecryptKnownProtocolResponse() throws {
        let data = try JMCrypto.decrypt("5SUexhrF2nEqr0up6W+pVgqCCBbMe21kEVfyb+cF2/Q=", timestamp: "1700000000")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object, ["uid": "123", "s": "fixture"])
        XCTAssertThrowsError(try JMCrypto.decrypt("not-base64", timestamp: "1700000000"))
    }
    @MainActor func testExcludedComicBlocksAutomaticButAllowsManualDownload() throws {
        let store = AppStore(inMemory: true)
        store.account = "a"
        store.clients["a"] = try JMAPI(preferences: Preferences())
        let comic = Comic(id: "123", title: "Fixture")
        store.exclude([comic])
        store.enqueue([comic], automatic: true)
        XCTAssertTrue(store.jobs.isEmpty)
        store.enqueue([comic])
        XCTAssertTrue(store.jobs.isEmpty, "Excluded comics require explicit confirmation")
        store.enqueue([comic], confirmedExcluded: true)
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs.first?.exclusionApproved, true)
        store.enqueue([comic])
        XCTAssertEqual(store.jobs.count, 1, "Duplicate queue entries must be suppressed")
        store.deleteJobs(comicIDs: [comic.id])
        XCTAssertEqual(store.jobs.first?.state, .deleted)
        store.enqueue([comic], automatic: true)
        XCTAssertEqual(store.jobs.first?.state, .deleted)
        store.account = "b"
        XCTAssertTrue(store.excluded.isEmpty, "Exclusions must stay account-scoped")
    }
    func testHostValidationRejectsCredentialAndPathInjection() throws {
        XCTAssertEqual(try Validation.hosts("https://example.com,api.example.org"), ["example.com", "api.example.org"])
        for host in ["http://example.com", "https://user:pass@example.com", "example.com/path", "example.com?q=x", ""] {
            XCTAssertThrowsError(try Validation.hosts(host))
        }
        XCTAssertThrowsError(try Validation.numericID("../123"))
        XCTAssertEqual(Validation.safeName("../../test"), ".._.._test")
    }
    func testProtocolMD5AndSegmentationBoundaries() {
        XCTAssertEqual(JMCrypto.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(JMCrypto.strips(chapterID: 100, filename: "00001", scrambleID: 220980), 0)
        XCTAssertEqual(JMCrypto.strips(chapterID: 220980, filename: "00001", scrambleID: 220980), 10)
        for id in [268850, 421925, 421926, 999999] {
            let value = JMCrypto.strips(chapterID: id, filename: "00001", scrambleID: 220980)
            XCTAssertTrue(value >= 2 && value <= (id < 421926 ? 20 : 16) && value % 2 == 0)
        }
    }
    func testStripsCoverEveryPixelOnceWithRemainder() {
        for height in [101, 201, 2048] {
            let slices = JMCrypto.slices(height: height, count: 10)
            let source = slices.flatMap { Array($0.source..<($0.source + $0.height)) }.sorted()
            let destination = slices.flatMap { Array($0.destination..<($0.destination + $0.height)) }.sorted()
            XCTAssertEqual(source, Array(0..<height)); XCTAssertEqual(destination, source)
            XCTAssertEqual(slices.first?.source, height - height / 10 - height % 10)
        }
    }
    func testQueueRoundtripPreservesOwnershipAndExclusions() throws {
        let comic = Comic(id: "123", title: "测试", folders: ["默认收藏"])
        let job = DownloadJob(owner: "account-a", comic: comic, state: .paused, finished: [0, 3])
        var snapshot = AppSnapshot()
        snapshot.jobs = [job]
        snapshot.libraries = ["account-a": Library(favorites: [comic], excluded: [comic]), "account-b": Library()]
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.jobs[0].state, .paused)
        XCTAssertEqual(restored.jobs[0].finished, [0, 3])
        XCTAssertEqual(restored.jobs[0].owner, "account-a")
        XCTAssertEqual(restored.libraries["account-a"]?.excluded, [comic])
        XCTAssertEqual(restored.libraries["account-b"]?.excluded, [])
    }
    func testTransferIdentifierValidation() {
        let id = UUID()
        XCTAssertEqual(DownloadEngine.parse("\(id):42")?.1, 42)
        XCTAssertNil(DownloadEngine.parse("\(id):-1"))
        XCTAssertNil(DownloadEngine.parse("bad:3"))
    }
    func testInvalidImageFailsRatherThanSavingHTML() {
        let page = PageAsset(url: URL(string: "https://example.com/1.jpg")!, chapterID: "1", filename: "1.jpg", scrambleID: 220980)
        XCTAssertThrowsError(try ImagePipeline.decoded(Data("<html>Error</html>".utf8), page: page))
    }
    func testNativePDFExport() async throws {
        let comic = Comic(id: "123456", title: "Unit Test " + UUID().uuidString)
        let page = PageAsset(url: URL(string: "https://example.com/1.png")!, chapterID: "1", filename: "1.png", scrambleID: 220980)
        let job = DownloadJob(owner: "unit-test", comic: comic, state: .exporting, pages: [page], finished: [0])
        try FileManager.default.createDirectory(at: DiskStore.cache(job.id), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30)).pngData { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        try image.write(to: DiskStore.raw(job.id, 0))
        let output = try await ImagePipeline.shared.export(job, bookmark: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 1)
    }
}
