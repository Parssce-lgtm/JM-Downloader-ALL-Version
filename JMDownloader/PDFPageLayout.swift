import Foundation
import CoreGraphics
import PDFKit

enum PDFPageLayout {
    static func aspectRatio(of page: CGPDFPage) throws -> CGFloat {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw JMError.message("PDF 页面尺寸无效。")
        }
        let ratio = page.rotationAngle % 180 == 0 ? box.height / box.width : box.width / box.height
        guard ratio.isFinite, ratio > 0 else { throw JMError.message("PDF 页面尺寸无效。") }
        return ratio
    }
    static func aspectRatios(url: URL) async throws -> [CGFloat] {
        try await Task.detached(priority: .userInitiated) {
            guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
                throw JMError.message("PDF 无法读取，可能已损坏或需要密码。")
            }
            return try (1...document.numberOfPages).map { index in
                guard let page = document.page(at: index) else { throw JMError.message("PDF 页面无法读取。") }
                return try aspectRatio(of: page)
            }
        }.value
    }
    static func image(url: URL, page index: Int, width: Int) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url), !document.isLocked,
                  let page = document.page(at: index), let reference = page.pageRef else {
                throw JMError.message("PDF 无法读取，可能已损坏或需要密码。")
            }
            let ratio = try aspectRatio(of: reference)
            let pixelWidth = max(1, Int(min(CGFloat(width), 6000 / ratio)))
            let pixelHeight = max(1, Int(min(6000, CGFloat(pixelWidth) * ratio)))
            let size = CGSize(width: pixelWidth, height: pixelHeight)
            guard let image = page.thumbnail(of: size, for: .cropBox).cgImage else {
                throw JMError.message("PDF 页面绘制失败。")
            }
            if image.width == pixelWidth && image.height == pixelHeight { return image }
            // Keep the display bitmap bounded even when the framework returns
            // a thumbnail at the device's backing scale.
            guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw JMError.message("无法创建 PDF 页面预览。")
            }
            context.draw(image, in: CGRect(origin: .zero, size: size))
            guard let resized = context.makeImage() else { throw JMError.message("PDF 页面绘制失败。") }
            return resized
        }.value
    }

}
