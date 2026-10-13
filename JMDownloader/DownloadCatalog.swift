import Foundation
import CoreGraphics

enum DownloadCatalog {
    static func key(_ comic: Comic) -> String { comic.source.rawValue + ":" + comic.id }
    static func key(filename: String) -> String? {
        let name = (filename as NSString).deletingPathExtension
        // Files may append " 2" or " (1)" when moving a duplicate PDF.
        let normalized = name.replacingOccurrences(of: "［", with: "[").replacingOccurrences(of: "］", with: "]")
        guard let close = normalized.lastIndex(of: "]"), let open = normalized[..<close].lastIndex(of: "[") else { return nil }
        let suffix = String(normalized[normalized.index(after: close)...])
        guard suffix.isEmpty || suffix.range(of: #"^\s+(?:\d+|\(\d+\))$"#, options: .regularExpression) != nil else { return nil }
        let value = String(normalized[normalized.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("jmcomic "), let id = try? Validation.numericID(String(value.dropFirst(8))) { return "jmcomic:" + id }
        if value.lowercased().hasPrefix("picacg "), let id = try? PicaAPI.comicID(String(value.dropFirst(7)).lowercased()) { return "picacg:" + id }
        if value.count == 24, let id = try? PicaAPI.comicID(value), value.contains(where: { $0.isLetter }) { return "picacg:" + id }
        if let id = try? Validation.numericID(value) { return "jmcomic:" + id }
        return nil
    }
    static func scan(bookmark: Data?) async throws -> Set<String> {
        let result = try await scanAll(bookmark: bookmark)
        if let warning = result.warning { throw JMError.message(warning) }
        return result.keys
    }
    struct ScanResult: Sendable { let keys: Set<String>; let warning: String? }
    static func scanAll(bookmark: Data?, defaultDirectory: URL = DiskStore.documents) async throws -> ScanResult {
        try await Task.detached(priority: .utility) {
            var found = try scanDirectory(defaultDirectory)
            var scoped = false
            var directory: URL?
            defer { if scoped { directory?.stopAccessingSecurityScopedResource() } }
            if let bookmark {
                do {
                    let selected = try DownloadDirectory.resolve(bookmark)
                    directory = selected
                    if selected.resolvingSymlinksInPath() != defaultDirectory.resolvingSymlinksInPath() {
                        scoped = selected.startAccessingSecurityScopedResource()
                        guard scoped || DownloadDirectory.isAppDirectory(selected) else { throw JMError.message("所选目录需要重新授权；默认目录已完成扫描。") }
                        found.formUnion(try scanDirectory(selected))
                    }
                } catch { return ScanResult(keys: found, warning: "所选目录未能扫描，请重新授权；默认目录的扫描结果已保留。") }
            }
            return ScanResult(keys: found, warning: nil)
        }.value
    }
    static func scanDirectory(_ directory: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        var failure: Error?
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else {
            throw JMError.message("无法读取下载目录。")
        }
        var result = Set<String>()
        for case let file as URL in files {
            try Task.checkCancellation()
            guard file.pathExtension.lowercased() == "pdf", let key = key(filename: file.lastPathComponent) else { continue }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let pdf = CGPDFDocument(file as CFURL), pdf.numberOfPages > 0 else { continue }
            result.insert(key)
        }
        if let failure { throw failure }
        return result
    }
}
