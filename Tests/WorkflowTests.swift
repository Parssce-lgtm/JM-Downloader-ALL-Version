import XCTest
import UIKit
@testable import JMDownloader

final class WorkflowTests: XCTestCase {
    @MainActor func testActiveDownloadsPrecedePDFAndUpdateOnStateChanges() {
        let store = AppStore(inMemory: true)
        store.account = "fixture"
        let states: [JobState] = [.queued, .preparing, .exporting, .downloading, .downloading, .paused]
        store.jobs = states.enumerated().map { index, state in
            var job = DownloadJob(owner: "fixture", comic: Comic(id: "\(index)", title: "\(index)"), state: state)
            job.created = Date(timeIntervalSince1970: Double(100 - index))
            return job
        }
        store.jobs.append(DownloadJob(owner: "other", comic: Comic(id: "other", title: "other"), state: .downloading))
        XCTAssertEqual(store.visibleJobs.map(\.comic.id), ["3", "4", "2", "1", "0", "5"])
        store.jobs[3].state = .exporting
        XCTAssertEqual(store.visibleJobs.map(\.comic.id), ["4", "2", "3", "1", "0", "5"])
        store.jobs[2].state = .completed
        XCTAssertEqual(store.visibleJobs.map(\.comic.id), ["4", "3", "1", "0", "5", "2"])
    }
    @MainActor func testHiddenFavoritesPersistWithoutChangingTasksOrOtherAccounts() throws {
        var snapshot: AppSnapshot?
        let store = AppStore(inMemory: true, snapshotWriter: { snapshot = $0 })
        store.account = "fixture"
        let comic = Comic(id: "88", title: "Hidden favorite")
        store.libraries[store.account] = Library(favorites: [comic])
        store.jobs = [DownloadJob(owner: store.account, comic: comic, state: .downloading)]
        store.hideFavorites([comic])
        XCTAssertTrue(store.isHiddenFavorite(comic))
        XCTAssertEqual(store.jobs[0].state, .downloading)
        XCTAssertTrue(store.excluded.isEmpty)
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(XCTUnwrap(snapshot)))
        XCTAssertTrue(restored.libraries["fixture"]?.hiddenComicKeys?.contains("jmcomic:88") == true)
        store.account = "other"
        XCTAssertFalse(store.isHiddenFavorite(comic))
        store.account = "fixture"
        store.showFavorite(comic)
        XCTAssertFalse(store.isHiddenFavorite(comic))
        let legacy = try JSONDecoder().decode(Library.self, from: Data(#"{"favorites":[],"excluded":[]}"#.utf8))
        XCTAssertNil(legacy.hiddenComicKeys)
    }
    @MainActor func testDeleteClearsOnlySelectedTaskCacheAndPreservesPDF() throws {
        let store = AppStore(inMemory: true)
        store.account = "fixture"
        var first = job(count: 1)
        first.state = .paused
        let second = job(count: 1)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        first.output = output
        try Data("preserved PDF fixture".utf8).write(to: output)
        for item in [first, second] {
            try DownloadStorage.prepare(DiskStore.cache(item.id))
            try image().write(to: DiskStore.raw(item.id, 0))
        }
        defer {
            for item in [first, second] { try? FileManager.default.removeItem(at: DiskStore.cache(item.id)) }
            try? FileManager.default.removeItem(at: output)
        }
        var otherAccount = second; otherAccount.owner = "other"
        store.jobs = [first, otherAccount]
        store.deleteJobs(comicIDs: [first.comic.id])
        XCTAssertEqual(store.jobs[0].state, .deleted)
        XCTAssertTrue(store.jobs[0].finished.isEmpty)
        XCTAssertTrue(store.jobs[0].pages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiskStore.cache(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiskStore.raw(second.id, 0).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
    private func image(jpeg: Bool = false) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40))
        let draw: (UIGraphicsImageRendererContext) -> Void = { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        }
        return jpeg ? renderer.jpegData(withCompressionQuality: 0.8, actions: draw) : renderer.pngData(actions: draw)
    }
    private func job(count: Int) -> DownloadJob {
        let page = PageAsset(url: URL(string: "https://fixture.invalid/page")!, chapterID: "0", filename: "page", scrambleID: Int.max)
        return DownloadJob(owner: "fixture", comic: Comic(id: "987654", title: "Test " + UUID().uuidString),
            state: .exporting, pages: Array(repeating: page, count: count), finished: Set(0..<count))
    }
    func testExportKeepsPNGAndJPEGAndSkipsOnlyUndecodableContent() async throws {
        let job = job(count: 3)
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        try image().write(to: DiskStore.raw(job.id, 0))
        try Data("<html>invalid image</html>".utf8).write(to: DiskStore.raw(job.id, 1))
        try image(jpeg: true).write(to: DiskStore.raw(job.id, 2))
        let result = try await ImagePipeline.shared.exportResult(job, bookmark: nil)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.skipped, [1])
        XCTAssertEqual(CGPDFDocument(result.url as CFURL)?.numberOfPages, 2)
        XCTAssertEqual(DownloadCatalog.key(filename: result.url.lastPathComponent), "jmcomic:987654")
    }
    func testMissingDownloadFileIsNotSilentlySkipped() async throws {
        let job = job(count: 2)
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        try image().write(to: DiskStore.raw(job.id, 0))
        do {
            _ = try await ImagePipeline.shared.exportResult(job, bookmark: nil)
            XCTFail("Missing on-disk data must remain a retryable I/O error")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiskStore.raw(job.id, 0).path))
    }
    func testDirectoryScanAcceptsValidPDFsAndLegacyNamesOnly() throws {
        let directory = DiskStore.cache(UUID())
        try DownloadStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["old [123].pdf", "new [JMComic 456].pdf", "pica [PicACG abcdef012345abcdef012345].pdf"]
        for name in names {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
            try renderer.pdfData { $0.beginPage() }.write(to: directory.appendingPathComponent(name))
        }
        try Data("broken".utf8).write(to: directory.appendingPathComponent("bad [789].pdf"))
        try Data().write(to: directory.appendingPathComponent("other [321].jpg"))
        XCTAssertEqual(try DownloadCatalog.scanDirectory(directory), ["jmcomic:123", "jmcomic:456", "picacg:abcdef012345abcdef012345"])
        XCTAssertNil(DownloadCatalog.key(filename: "Random name.pdf"))
    }
    @MainActor func testQueuePriorityBulkControlsAndPlatformIsolation() {
        let store = AppStore(inMemory: true)
        store.account = "fixture"
        let comic = Comic(id: "1", title: "one")
        let states: [JobState] = [.completed, .paused, .deleted, .failed, .downloading, .queued]
        store.jobs = states.enumerated().map { index, state in
            DownloadJob(owner: "fixture", comic: Comic(id: "\(index)", title: "\(index)"), state: state)
        }
        store.jobs.append(DownloadJob(owner: "picacg:fixture", comic: Comic(id: "abcdef012345abcdef012345", title: "other", platform: .picacg), state: .downloading))
        XCTAssertEqual(store.visibleJobs.first?.state, .downloading)
        store.pauseAll()
        XCTAssertEqual(store.jobs[4].state, .paused)
        XCTAssertEqual(store.jobs.last?.state, .downloading)
        store.startAll()
        XCTAssertEqual(store.jobs[1].state, .queued)
        XCTAssertEqual(store.jobs[3].state, .queued)
        XCTAssertEqual(store.jobs[0].state, .completed)
        XCTAssertEqual(store.jobs[2].state, .deleted)
        store.downloadedFiles = [DownloadCatalog.key(comic)]
        XCTAssertTrue(store.isDownloaded(comic))
        XCTAssertFalse(store.isDownloaded(Comic(id: comic.id, title: "other", platform: .picacg)))
    }
    @MainActor func testAutomaticResumeDoesNotResumeManualPause() async throws {
        let store = AppStore(inMemory: true)
        let comic = Comic(id: "12", title: "fixture")
        store.jobs = [DownloadJob(owner: "fixture", comic: comic, state: .paused, resumeAutomatically: true),
                      DownloadJob(owner: "fixture", comic: comic, state: .paused, resumeAutomatically: false)]
        store.engine.connect(store, configuration: .ephemeral)
        for _ in 0..<50 {
            if store.engine.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.jobs[0].state, .queued)
        XCTAssertEqual(store.jobs[0].resumeAutomatically, false)
        XCTAssertEqual(store.jobs[1].state, .paused)
    }
    @MainActor func testStoredSessionRestoresWithoutLoginAndRejectsWrongHost() async throws {
        let session = ServiceSession(platform: .jmcomic, host: Preferences.defaultJMDomains.components(separatedBy: ",")[0], cookies: ["AVS": "fixture"])
        let restored = try JSONDecoder().decode(ServiceSession.self, from: JSONEncoder().encode(session))
        let api = try AppStore.client(Preferences(), session: restored)
        let saved = await api.savedSession()
        XCTAssertEqual(saved?.cookies["AVS"], "fixture")
        var wrong = session; wrong.host = "wrong.invalid"
        XCTAssertThrowsError(try AppStore.client(Preferences(), session: wrong))
        let pica = ServiceSession(platform: .picacg, host: Preferences.defaultPicaDomain, token: "fixture")
        let picaAPI = try AppStore.client(Preferences(), session: pica)
        let picaSaved = await picaAPI.savedSession()
        XCTAssertEqual(picaSaved?.token, "fixture")
    }
    func testCoverCacheSurvivesRecreationAndClearPreservesDownloads() async throws {
        let root = DiskStore.cache(UUID())
        let directory = root.appendingPathComponent("covers")
        try DownloadStorage.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("0.raw")
        try Data([1, 2, 3]).write(to: raw)
        let data = image(), key = "jmcomic:fixture"
        let cache = CoverCache(directory: directory)
        try await cache.insert(data, key: key)
        let reopened = CoverCache(directory: directory)
        let loaded = await reopened.cached(key)
        XCTAssertEqual(loaded, data)
        try await reopened.clear()
        let missing = await reopened.cached(key)
        XCTAssertNil(missing)
        XCTAssertEqual(try Data(contentsOf: raw), Data([1, 2, 3]))
    }
    func testLegacyJobDecodingAndWorkProgress() throws {
        let original = job(count: 3)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for field in ["resumeAutomatically", "renderedPages", "skippedPages"] { object.removeValue(forKey: field) }
        var decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.resumeAutomatically)
        XCTAssertEqual(decoded.workUnits, 700)
        decoded.renderedPages = 2
        XCTAssertGreaterThan(decoded.workUnits, 700)
        XCTAssertLessThan(decoded.workUnits, 1000)
        decoded.state = .completed
        XCTAssertEqual(decoded.workUnits, 1000)
    }
}
