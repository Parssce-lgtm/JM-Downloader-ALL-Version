import XCTest
import UIKit
@testable import JMDownloader

final class CoverThumbnailTests: XCTestCase {
    @MainActor func testThumbnailBoundsReuseReplacementAndClear() async throws {
        let directory = DiskStore.cache(UUID()).appendingPathComponent("covers")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let cache = CoverCache(directory: directory)
        let comic = Comic(id: "987651", title: "Thumbnail fixture")
        let key = DownloadCatalog.key(comic)
        func data(_ size: CGSize) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.8))
        }
        try await cache.insert(data(CGSize(width: 1200, height: 1800)), key: key)
        let first = try await cache.thumbnail(comic: comic, preferences: Preferences())
        let pixels = try XCTUnwrap(first.cgImage)
        XCTAssertEqual(pixels.height, 320)
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 2.0 / 3, accuracy: 0.01)
        let reused = try await cache.thumbnail(comic: comic, preferences: Preferences())
        XCTAssertTrue(first === reused)
        try await cache.insert(data(CGSize(width: 1600, height: 800)), key: key)
        let replaced = try await cache.thumbnail(comic: comic, preferences: Preferences())
        XCTAssertFalse(first === replaced)
        XCTAssertEqual(replaced.cgImage?.width, 320)
        XCTAssertEqual(replaced.cgImage?.height, 160)
        try await cache.clear()
        try await cache.insert(data(CGSize(width: 1200, height: 1800)), key: key)
        let cleared = try await cache.thumbnail(comic: comic, preferences: Preferences())
        XCTAssertFalse(replaced === cleared)
        XCTAssertEqual(cleared.cgImage?.height, 320)
    }
}
