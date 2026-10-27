import XCTest
import UIKit
import PDFKit
@testable import JMDownloader

final class PDFPageLayoutTests: XCTestCase {
    @MainActor func testMixedPageHeightsAreKnownBeforeImagesLoad() async throws {
        let root = DiskStore.cache(UUID())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sizes.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 240, height: 360)).writePDF(to: url) { context in
            for size in [CGSize(width: 240, height: 360), CGSize(width: 240, height: 480), CGSize(width: 360, height: 240)] {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
            }
        }
        let ratios = try await PDFPageLayout.aspectRatios(url: url)
        XCTAssertEqual(ratios.count, 3)
        XCTAssertEqual(ratios[0], 1.5, accuracy: 0.001)
        XCTAssertEqual(ratios[1], 2, accuracy: 0.001)
        XCTAssertEqual(ratios[2], 2.0 / 3, accuracy: 0.001)
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 0)?.rotation = 90
        XCTAssertTrue(document.write(to: url))
        let rotated = try await PDFPageLayout.aspectRatios(url: url)
        XCTAssertEqual(rotated[0], 2.0 / 3, accuracy: 0.001)
    }
    func testNativeRendererFillsThePageAndKeepsPixelBounds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var media = CGRect(x: 0, y: 0, width: 240, height: 360)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        writer.fill(media); writer.endPDFPage(); writer.closePDF()
        let image = try await PDFPageLayout.image(url: url, page: 0, width: 400)
        XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 600)
        for (x, y) in [(20, 30), (380, 30), (20, 570), (380, 570)] {
            let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let buffer = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            buffer.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(buffer.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertGreaterThan(bytes[0], 200)
            XCTAssertLessThan(bytes[1], 40); XCTAssertLessThan(bytes[2], 40)
        }
    }
    func testUnreadableDocumentReturnsAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PDFPageLayout.aspectRatios(url: url)
            XCTFail("Invalid PDF should not create unstable placeholder pages")
        } catch { }
    }
}
