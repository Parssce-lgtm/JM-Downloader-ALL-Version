import Foundation
import CoreGraphics

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
}
