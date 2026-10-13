import XCTest
import UIKit
@testable import JMDownloader

private final class SnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AppSnapshot] = []
    private var mainThreadWrites = 0
    func write(_ value: AppSnapshot) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        if Thread.isMainThread { mainThreadWrites += 1 }
    }
    func result() -> ([AppSnapshot], Int) { lock.lock(); defer { lock.unlock() }; return (values, mainThreadWrites) }
}
private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func result() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ResponsivenessTests: XCTestCase {
    @MainActor func testThousandsOfProgressEventsCoalesceAndWriteOffMainThread() async throws {
        let probe = SnapshotProbe()
        let store = AppStore(inMemory: true, snapshotWriter: probe.write)
        let page = PageAsset(url: URL(string: "https://fixture.invalid/image")!, chapterID: "0", filename: "image", scrambleID: Int.max)
        let job = DownloadJob(owner: "fixture", comic: Comic(id: "1", title: "Large album"), state: .exporting,
                              pages: Array(repeating: page, count: 3000), finished: Set(0..<3000))
        store.jobs = [job]
        for count in 1...3000 { store.change(job.id) { $0.renderedPages = count } }
        XCTAssertTrue(probe.result().0.isEmpty)
        await store.flushProgress()
        let result = probe.result()
        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(result.0.last?.jobs.first?.renderedPages, 3000)
        XCTAssertEqual(result.1, 0)
        XCTAssertNil(store.alert)
        var preferences = store.preferences; preferences.concurrency = 3
        XCTAssertTrue(store.savePreferences(preferences))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(probe.result().0.count, 2)
        XCTAssertEqual(probe.result().0.last?.preferences.concurrency, 3)
    }
    @MainActor func testProgressDiskFailureDoesNotPresentModalOrRepeatLogs() async {
        let store = AppStore(inMemory: true, snapshotWriter: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let first = await store.flushProgress(), second = await store.flushProgress()
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertNil(store.alert)
        XCTAssertEqual(store.logs.count, 1)
        XCTAssertTrue(store.logs[0].text.contains("存储空间"))
    }
    @MainActor func testLargePDFReportsBoundedProgressAndAllowsMainActorWork() async throws {
        let page = PageAsset(url: URL(string: "https://offline.invalid/image")!, chapterID: "0", filename: "image", scrambleID: Int.max)
        let job = DownloadJob(owner: "fixture", comic: Comic(id: "987653", title: "Large offline " + UUID().uuidString),
                              state: .exporting, pages: Array(repeating: page, count: 600), finished: Set(0..<600))
        let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 50)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 50))
        }
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        for index in job.pages.indices { try data.write(to: DiskStore.raw(job.id, index)) }
        let progress = ProgressProbe()
        let task = Task { try await ImagePipeline.shared.exportResult(job, bookmark: nil, onProgress: { count, _ in progress.record(count) }) }
        // The renderer starts on its own actor; the main actor must be schedulable meanwhile.
        var heartbeat = 0
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(5)); heartbeat += 1 }
        let result = try await task.value
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(heartbeat, 10)
        XCTAssertEqual(CGPDFDocument(result.url as CFURL)?.numberOfPages, 600)
        XCTAssertEqual(progress.result().last, 600)
        XCTAssertLessThan(progress.result().count, 150)
    }
    func testCreateDirectoryBookmarkReopensAndExportsPDF() async throws {
        let name = "Directory fixture " + UUID().uuidString
        try FileManager.default.createDirectory(at: DiskStore.documents, withIntermediateDirectories: true)
        let selection = try DownloadDirectory.select(DiskStore.documents, newFolder: name)
        let folder = try DownloadDirectory.resolve(selection.bookmark)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(folder.lastPathComponent, name)
        XCTAssertTrue(DownloadDirectory.isAppDirectory(folder))
        XCTAssertFalse(DownloadDirectory.isAppDirectory(DiskStore.documents.deletingLastPathComponent().appendingPathComponent("Documents-other")))
        XCTAssertThrowsError(try DownloadDirectory.select(folder, newFolder: "../escape"))
        let page = PageAsset(url: URL(string: "https://offline.invalid/a")!, chapterID: "0", filename: "a", scrambleID: Int.max)
        let job = DownloadJob(owner: "fixture", comic: Comic(id: "987652", title: "Directory test"), pages: [page], finished: [0])
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        let data = await MainActor.run { UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) } }
        try data.write(to: DiskStore.raw(job.id, 0))
        let result = try await ImagePipeline.shared.exportResult(job, bookmark: selection.bookmark)
        XCTAssertEqual(result.url.deletingLastPathComponent().resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        let scanned = try await DownloadCatalog.scan(bookmark: selection.bookmark)
        XCTAssertTrue(scanned.contains("jmcomic:987652"))
    }
}
