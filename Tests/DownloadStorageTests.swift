import XCTest
import UIKit
@testable import JMDownloader

private final class ImageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status = path == "/denied" || request.url?.host == "storage-b.picacomic.com" ? 403 : 200
        let mime = path == "/html" ? "text/html" : "image/png"
        let data: Data
        if path == "/image" || path == "/static/image" {
            data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30)).pngData { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
            }
        } else { data = Data(repeating: 42, count: 200_003) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data.prefix(90_000))
        if path == "/interrupted" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocol(self, didLoad: data.dropFirst(min(90_000, data.count)))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

private final class StagingFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotCreateFile)) }
    override func stopLoading() { }
}

final class DownloadStorageTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageProtocol.self]
        return config
    }
    func testFileStagingFailureIsNotReportedAsConnectivity() {
        let error = URLError(.cannotCreateFile)
        XCTAssertTrue(DownloadStorage.needsDirectTransfer(error))
        XCTAssertFalse(DownloadStorage.needsDirectTransfer(URLError(.cannotConnectToHost)))
        XCTAssertFalse(DownloadStorage.needsDirectTransfer(NSError(domain: "Other", code: -3000)))
        let message = NetworkFailure.describe(error)
        XCTAssertTrue(message.contains("文件存储错误")); XCTAssertTrue(message.contains("-3000"))
        XCTAssertFalse(message.contains("检测当前网络连接"))
    }
    func testStreamWritesAllChunksPrivatelyBeforeCommit() async throws {
        let directory = DiskStore.cache(UUID())
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("0.raw")
        let staged = try await DownloadStorage.receive(URLRequest(url: URL(string: "https://fixture.invalid/chunks")!),
            configuration: configuration(), directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(try Data(contentsOf: staged), Data(repeating: 42, count: 200_003))
        try DownloadStorage.commit(staged, to: final)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testFailedResponsesAndInterruptedStreamLeaveNoPartialImage() async throws {
        for path in ["denied", "interrupted"] {
            let directory = DiskStore.cache(UUID())
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await DownloadStorage.receive(URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!),
                    configuration: configuration(), directory: directory)
                XCTFail("Unexpected success: \(path)")
            } catch { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testCancellationCleansStagingFile() async throws {
        let directory = DiskStore.cache(UUID())
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = configuration()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DownloadStorage.receive(URLRequest(url: URL(string: "https://fixture.invalid/chunks")!),
                configuration: config, directory: directory)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
    @MainActor func testDownloadEngineRecoversFromMinus3000AndExportsPDF() async throws {
        let store = AppStore(inMemory: true)
        let comic = Comic(id: "123456", title: "Recovery " + UUID().uuidString)
        let page = PageAsset(url: URL(string: "https://fixture.invalid/image")!, chapterID: "1", filename: "1.png", scrambleID: Int.max)
        let job = DownloadJob(owner: "fixture", comic: comic, state: .downloading, pages: [page])
        store.jobs = [job]
        defer {
            store.engine.pause(job.id)
            try? FileManager.default.removeItem(at: DiskStore.cache(job.id))
            if let output = store.jobs.first?.output { try? FileManager.default.removeItem(at: output) }
        }
        let failing = URLSessionConfiguration.ephemeral
        failing.protocolClasses = [StagingFailureProtocol.self]
        store.engine.connect(store, configuration: failing, directConfiguration: configuration())
        for _ in 0..<1500 {
            if store.jobs[0].state == .completed || store.jobs[0].state == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.jobs[0].state, .completed, store.jobs[0].message)
        XCTAssertTrue(store.logs.contains { $0.text.contains("兼容下载") })
        let output = try XCTUnwrap(store.jobs[0].output)
        XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 1)
        XCTAssertEqual(output.deletingLastPathComponent(), DiskStore.documents)
    }
    @MainActor func testPica403SwitchesMediaRouteAndPublishesCompletePDF() async throws {
        let store = AppStore(inMemory: true)
        let comic = Comic(id: "0123456789abcdef01234567", title: "Media recovery " + UUID().uuidString, platform: .picacg)
        let page = PageAsset(url: URL(string: "https://storage-b.picacomic.com/static/tobs/image")!, chapterID: "0", filename: "1.jpg", scrambleID: Int.max)
        let job = DownloadJob(owner: "picacg:fixture", comic: comic, state: .downloading, pages: [page])
        store.jobs = [job]
        defer {
            store.engine.pause(job.id)
            try? FileManager.default.removeItem(at: DiskStore.cache(job.id))
            if let output = store.jobs.first?.output { try? FileManager.default.removeItem(at: output) }
        }
        let failing = URLSessionConfiguration.ephemeral
        failing.protocolClasses = [StagingFailureProtocol.self]
        store.engine.connect(store, configuration: failing, directConfiguration: configuration())
        for _ in 0..<500 {
            if [.completed, .failed].contains(store.jobs[0].state) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.jobs[0].state, .completed, store.jobs[0].message)
        let output = try XCTUnwrap(store.jobs[0].output)
        XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 1)
    }
    func testConversionFailureDoesNotPublishToFiles() async throws {
        let comic = Comic(id: "123456", title: "Invalid " + UUID().uuidString)
        let page = PageAsset(url: URL(string: "https://fixture.invalid/image")!, chapterID: "1", filename: "1.png", scrambleID: Int.max)
        let job = DownloadJob(owner: "fixture", comic: comic, state: .exporting, pages: [page], finished: [0])
        let output = DiskStore.documents.appendingPathComponent(Validation.safeName(comic.title) + " [\(comic.id)].pdf")
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        defer { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
        try Data("not an image".utf8).write(to: DiskStore.raw(job.id, 0))
        do { _ = try await ImagePipeline.shared.export(job, bookmark: nil); XCTFail("Expected conversion failure") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: DiskStore.cache(job.id).path).contains { $0.hasSuffix(".pdf") })
    }
}
