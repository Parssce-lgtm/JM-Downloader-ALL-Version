import XCTest
import UIKit
@testable import JMDownloader

final class DirectoryRegressionTests: XCTestCase {
    func testFilesDuplicateNamesKeepComicIdentity() {
        XCTAssertEqual(DownloadCatalog.key(filename: "title [JMComic 123] 2.pdf"), "jmcomic:123")
        XCTAssertEqual(DownloadCatalog.key(filename: "title [JMComic 456] (1).PDF"), "jmcomic:456")
        XCTAssertEqual(DownloadCatalog.key(filename: "title ［JMComic 789］.pdf"), "jmcomic:789")
        XCTAssertNil(DownloadCatalog.key(filename: "title [123] unrelated.pdf"))
    }
    @MainActor func testDefaultScanSurvivesInvalidExternalBookmarkAndMovedFiles() async throws {
        let directory = DiskStore.cache(UUID())
        let nested = directory.appendingPathComponent("Moved back", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 20, height: 20)).pdfData { $0.beginPage() }
        try data.write(to: nested.appendingPathComponent("Moved [JMComic 345] (1).pdf"))
        try Data("not a PDF".utf8).write(to: nested.appendingPathComponent("Invalid [JMComic 999].pdf"))
        let result = try await DownloadCatalog.scanAll(bookmark: Data("expired".utf8), defaultDirectory: directory)
        XCTAssertEqual(result.keys, ["jmcomic:345"])
        XCTAssertNotNil(result.warning)
        let store = AppStore(inMemory: true)
        store.downloadedFiles = result.keys
        XCTAssertTrue(store.isDownloaded(Comic(id: "345", title: "Moved")))
        XCTAssertFalse(store.isDownloaded(Comic(id: "999", title: "Invalid")))
    }
    @MainActor func testReturningToAppRescansDefaultDirectory() async throws {
        let id = "876543210"
        let file = DiskStore.documents.appendingPathComponent("Moved back [JMComic \(id)] 2.pdf")
        try FileManager.default.createDirectory(at: DiskStore.documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(inMemory: true)
        XCTAssertFalse(store.isDownloaded(Comic(id: id, title: "Moved")))
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 20, height: 20)).pdfData { $0.beginPage() }
        try data.write(to: file)
        store.becameActive()
        let deadline = Date().addingTimeInterval(15)
        while store.scanningDownloads && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isDownloaded(Comic(id: id, title: "Moved")))
        XCTAssertFalse(store.scanningDownloads)
    }
}
