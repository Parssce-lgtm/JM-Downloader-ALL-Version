import XCTest
@testable import JMDownloader

@MainActor
final class LocalPDFLibraryTests: XCTestCase {
    private func file(_ url: URL) -> LocalPDF {
        LocalPDF(url: url, title: "本地漫画", comicID: "90001", platform: .jmcomic, tags: ["剧情"], pages: 1, bytes: 3, date: .distantPast)
    }
    private func sandbox() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return (root, documents, root.appendingPathComponent("pdf-state.json"))
    }
    func testDislikeStaysVisibleUntilRelaunchAndCanBeRestored() throws {
        let (root, documents, stateURL) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = file(documents.appendingPathComponent("漫画 [JMComic 90001].pdf"))
        try Data("source".utf8).write(to: source.url)
        let state = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        try state.dislike(source, cover: Data([1, 2, 3]))
        XCTAssertTrue(state.isDisliked(source.id)); XCTAssertTrue(state.isVisible(source.id))
        let relaunched = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        XCTAssertFalse(relaunched.isVisible(source.id))
        XCTAssertEqual(relaunched.exclusions.first?.cover, Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: source.url), Data("source".utf8))
        try relaunched.restore(source.id)
        XCTAssertTrue(relaunched.isVisible(source.id)); XCTAssertFalse(relaunched.isDisliked(source.id))
        try relaunched.dislike(source, cover: nil)
        XCTAssertTrue(relaunched.isVisible(source.id))
        try relaunched.restore(source.id)
        XCTAssertTrue(LocalPDFLibraryState(documents: documents, persistenceURL: stateURL).exclusions.isEmpty)
    }
    func testDeleteOnlyRemovesTheChosenSourceAndCombinedActionKeepsItsRecord() throws {
        let (root, documents, stateURL) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = file(documents.appendingPathComponent("a.pdf")), b = file(documents.appendingPathComponent("b.pdf"))
        let cache = documents.appendingPathComponent("cached-image.jpg")
        for url in [a.url, b.url, cache] { try Data("keep".utf8).write(to: url) }
        let state = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        try state.deleteSource(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.path)); XCTAssertTrue(state.exclusions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: b.url), Data("keep".utf8))
        try state.dislikeAndDelete(b, cover: Data([4, 5]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.url.path))
        XCTAssertEqual(try Data(contentsOf: cache), Data("keep".utf8))
        let relaunched = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        XCTAssertEqual(relaunched.exclusions.map(\.id), [b.id]); XCTAssertEqual(relaunched.exclusions.first?.cover, Data([4, 5]))
        try relaunched.restore(b.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.url.path))
    }
    func testDeletionRejectsOtherDirectoriesLinksAndNonPDFs() throws {
        let (root, documents, stateURL) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.pdf"), other = documents.appendingPathComponent("photo.jpg")
        let directory = documents.appendingPathComponent("folder.pdf", isDirectory: true)
        try Data("outside".utf8).write(to: outside); try Data("photo".utf8).write(to: other)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nested = directory.appendingPathComponent("nested.pdf"); try Data("nested".utf8).write(to: nested)
        let link = documents.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let state = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        for url in [outside, other, directory, nested, link] {
            XCTAssertThrowsError(try state.deleteSource(file(url)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testFailedRecordWritePreventsCombinedDeletion() throws {
        let (root, documents, stateURL) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = file(documents.appendingPathComponent("keep.pdf"))
        try Data("source".utf8).write(to: source.url)
        let original = Data("unreadable record".utf8); try original.write(to: stateURL)
        let state = LocalPDFLibraryState(documents: documents, persistenceURL: stateURL)
        XCTAssertThrowsError(try state.dislikeAndDelete(source, cover: nil))
        XCTAssertTrue(state.exclusions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source.url), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }
}
