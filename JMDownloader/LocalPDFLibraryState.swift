import Foundation
import Combine

struct LocalPDF: Identifiable, Sendable {
    let url: URL
    let title: String
    let comicID: String
    let platform: ComicPlatform?
    let tags: [String]
    let pages: Int
    let bytes: Int64
    let date: Date
    var id: String { url.lastPathComponent }
    var reference: String { platform.map { "\($0.label) \(comicID)" } ?? "本地 PDF" }
}

struct LocalPDFExclusion: Codable, Identifiable, Equatable, Sendable {
    let filename: String
    let title: String
    let reference: String
    let tags: [String]
    // A small first-page thumbnail survives deletion of the source PDF.
    let cover: Data?
    var id: String { filename }
}

@MainActor
final class LocalPDFLibraryState: ObservableObject {
    @Published private(set) var exclusions: [LocalPDFExclusion] = []
    let documents: URL
    private let persistenceURL: URL?
    private var hiddenAtLaunch = Set<String>()
    private var loadFailed = false

    init(documents: URL = DiskStore.documents, persistenceURL: URL? = nil) {
        self.documents = documents.standardizedFileURL
        self.persistenceURL = persistenceURL
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let records = try JSONDecoder().decode([LocalPDFExclusion].self, from: Data(contentsOf: persistenceURL))
            guard records.allSatisfy({ Self.validFilename($0.filename) }), Set(records.map(\.id)).count == records.count else {
                throw JMError.message("PDF 不喜欢记录无效。")
            }
            exclusions = records
            hiddenAtLaunch = Set(records.map(\.id))
        } catch { loadFailed = true }
    }

    func isDisliked(_ filename: String) -> Bool { exclusions.contains { $0.id == filename } }
    func isVisible(_ filename: String) -> Bool { !hiddenAtLaunch.contains(filename) || !isDisliked(filename) }

    func dislike(_ file: LocalPDF, cover: Data?) throws {
        _ = try sourceURL(file.url)
        guard !isDisliked(file.id) else { return }
        let record = LocalPDFExclusion(filename: file.id, title: file.title, reference: file.reference, tags: file.tags, cover: cover)
        try save(exclusions + [record])
    }

    func restore(_ filename: String) throws {
        try save(exclusions.filter { $0.id != filename })
        // A restored file can be disliked again without disappearing mid-session.
        hiddenAtLaunch.remove(filename)
    }

    func deleteSource(_ file: LocalPDF) throws {
        let url = try sourceURL(file.url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw JMError.message("只能删除软件根目录中的源 PDF 文件。")
        }
        // Never enumerate, delete a folder, or touch a task/cache/output sibling.
        try FileManager.default.removeItem(at: url)
    }

    func dislikeAndDelete(_ file: LocalPDF, cover: Data?) throws {
        // Saving must succeed before the source is removed. A failed deletion
        // leaves the dislike intact and can be retried without losing its cover.
        try dislike(file, cover: cover)
        try deleteSource(file)
    }

    private func save(_ records: [LocalPDFExclusion]) throws {
        guard !loadFailed else { throw JMError.message("PDF 不喜欢记录无法读取，原始记录已保留，暂未覆盖。") }
        if let persistenceURL {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: persistenceURL, options: .atomic)
        }
        exclusions = records
    }

    private func sourceURL(_ url: URL) throws -> URL {
        let normalized = url.standardizedFileURL
        guard url.isFileURL, Self.validFilename(url.lastPathComponent),
              normalized.deletingLastPathComponent() == documents,
              normalized.resolvingSymlinksInPath().deletingLastPathComponent() == documents.resolvingSymlinksInPath() else {
            throw JMError.message("只能操作软件根目录中的源 PDF 文件。")
        }
        return normalized
    }

    private static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\")
            && (name as NSString).pathExtension.lowercased() == "pdf"
    }
}
