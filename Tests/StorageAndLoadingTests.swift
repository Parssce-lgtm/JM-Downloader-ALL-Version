import XCTest
import UIKit
@testable import JMDownloader

private actor ConcurrencyProbe {
    var active = 0
    var maximum = 0
    func load(_ value: Int) async throws -> Int {
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(value % 3 == 0 ? 30 : 10))
        return value * 2
    }
    func peak() -> Int { maximum }
}

final class StorageAndLoadingTests: XCTestCase {
    func testBoundedLoadingPreservesOrderAndLimitsServicePressure() async throws {
        let probe = ConcurrencyProbe()
        let values = Array(0..<15)
        let result = try await ConcurrentLoad.map(values) { try await probe.load($0) }
        XCTAssertEqual(result, values.map { $0 * 2 })
        let peak = await probe.peak()
        XCTAssertEqual(peak, 3)
    }
    func testUpgradeRestoresRootOnceWithoutTouchingOtherPreferences() throws {
        var value = Preferences()
        value.storageRootBookmark = Data("external".utf8)
        value.directoryBookmark = Data("downloads".utf8)
        value.directoryName = "external/downloads"
        value.tagBlacklist = "AI"
        value.themeColor = "绿"
        XCTAssertTrue(value.restoreRootDirectoryDefault())
        XCTAssertNil(value.storageRootBookmark)
        XCTAssertNil(value.directoryBookmark)
        XCTAssertEqual(try DownloadDirectory.resolve(value.directoryBookmark), DiskStore.documents)
        XCTAssertEqual(value.tagBlacklist, "AI")
        XCTAssertEqual(value.themeColor, "绿")
        // Later explicit directory choices must not be reset on every launch.
        value.directoryBookmark = Data("new user choice".utf8)
        XCTAssertFalse(value.restoreRootDirectoryDefault())
        XCTAssertEqual(value.directoryBookmark, Data("new user choice".utf8))
    }
}
