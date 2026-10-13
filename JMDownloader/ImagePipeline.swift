import Foundation
import UIKit
import ImageIO
import PDFKit

actor ImagePipeline {
    static let shared = ImagePipeline()
    struct ExportResult: Sendable { let url: URL; let skipped: Set<Int> }

    static func decoded(_ data: Data, page: PageAsset) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw JMError.message("下载内容不是有效图片，请重试或更换图片域名。")
        }
        let filename = (page.filename as NSString).deletingPathExtension
        let strips = JMCrypto.strips(chapterID: Int(page.chapterID) ?? 0, filename: filename, scrambleID: page.scrambleID)
        guard strips > 0 else { return image }
        guard image.height >= strips, image.width <= 30000, image.height <= 100000,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw JMError.message("图片尺寸不受支持。") }
        for slice in JMCrypto.slices(height: image.height, count: strips) {
            guard let part = image.cropping(to: CGRect(x: 0, y: slice.source, width: image.width, height: slice.height)) else {
                throw JMError.message("图片解扰失败。")
            }
            // CGImage crops use top-left pixels; CGContext's default origin is bottom-left.
            context.draw(part, in: CGRect(x: 0, y: image.height - slice.destination - slice.height,
                                         width: image.width, height: slice.height))
        }
        guard let result = context.makeImage() else { throw JMError.message("图片合成失败。") }
        return result
    }

    func export(_ job: DownloadJob, bookmark: Data?) throws -> URL {
        try exportResult(job, bookmark: bookmark).url
    }
    func exportResult(_ job: DownloadJob, bookmark: Data?,
                      onProgress: @Sendable (Int, Set<Int>) -> Void = { _, _ in }) throws -> ExportResult {
        let fm = FileManager.default
        // Download and render privately; the Files destination is touched only after PDF validation.
        try DownloadStorage.prepare(DiskStore.cache(job.id))
        let temporary = DiskStore.cache(job.id).appendingPathComponent(UUID().uuidString + ".partial.pdf")
        defer { try? fm.removeItem(at: temporary) }
        guard let consumer = CGDataConsumer(url: temporary as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw JMError.message("无法在应用内部创建 PDF，请检查剩余存储空间。") }
        var skipped = Set<Int>()
        var written = 0
        var lastProgress = Date.distantPast
        do {
            for (index, page) in job.pages.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    // I/O failures must remain retryable. Only content/decoding failures are skipped.
                    let data = try Data(contentsOf: DiskStore.raw(job.id, index))
                    guard let image = try? Self.decoded(data, page: page) else { skipped.insert(index); return }
                    let scale = min(1, 14000 / Double(max(image.width, image.height)))
                    var bounds = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
                    let box = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
                    context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
                    context.draw(image, in: bounds)
                    context.endPDFPage()
                    written += 1
                }
                if Date().timeIntervalSince(lastProgress) >= 0.25 || index + 1 == job.pages.count {
                    onProgress(index + 1, skipped); lastProgress = Date()
                }
            }
            context.closePDF()
        } catch { context.closePDF(); throw error }
        guard written > 0 else { throw JMError.message("没有可生成 PDF 的有效图片，任务未标记完成；请稍后重试或检查图片线路。") }
        guard let pdf = CGPDFDocument(temporary as CFURL), pdf.numberOfPages == written else {
            throw JMError.message("PDF 完整性校验失败，缓存已保留。")
        }
        try Task.checkCancellation()
        var scoped = false
        var directory = DiskStore.documents
        if let bookmark {
            var stale = false
            directory = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            scoped = directory.startAccessingSecurityScopedResource()
            guard scoped || DownloadDirectory.isAppDirectory(directory) else { throw JMError.message("下载目录授权已失效，请重新选择目录。") }
        }
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let name = Validation.safeName(job.comic.title) + " [\(job.comic.source.label) \(job.comic.id)]"
        let output = directory.appendingPathComponent(name + ".pdf")
        // Coordinate with Files providers; copy the finished PDF, then publish its final name.
        var coordinationError: NSError?
        var publishError: Error?
        NSFileCoordinator().coordinate(writingItemAt: output, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try fm.createDirectory(at: coordinated.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staged = coordinated.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
                defer { try? fm.removeItem(at: staged) }
                try fm.copyItem(at: temporary, to: staged)
                try DownloadStorage.commit(staged, to: coordinated)
            } catch { publishError = error }
        }
        if let coordinationError { throw coordinationError }
        if let publishError { throw publishError }
        return ExportResult(url: output, skipped: skipped)
    }
}
