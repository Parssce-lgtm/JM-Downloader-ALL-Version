import Foundation
import CryptoKit

/// Complete tags survive refreshes, session renewal and process termination.
/// Small per-comic records avoid rewriting a growing catalog for every result.
actor ComicTagCache {
    private struct Record: Codable { let key: String; let tags: [String] }
    private let directory: URL?
    private var values: [String: [String]] = [:]
    init(directory: URL? = nil) { self.directory = directory }
    nonisolated static func persistent(account: String, root: URL? = nil) -> ComicTagCache {
        let storageRoot = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JMDownloader/ComicTags-v1", isDirectory: true)
        return ComicTagCache(directory: storageRoot.appendingPathComponent(digest(account), isDirectory: true))
    }
    nonisolated private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func file(_ key: String) -> URL? { directory?.appendingPathComponent(Self.digest(key) + ".json") }
    func tags(for comic: Comic) -> [String]? {
        let key = DownloadCatalog.key(comic)
        if let tags = values[key] { return tags }
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.key == key else { return nil }
        values[key] = record.tags
        return record.tags
    }
    func store(_ tags: [String], for comic: Comic) {
        let key = DownloadCatalog.key(comic)
        guard values[key] != tags else { return }
        values[key] = tags
        guard let directory, let file = file(key) else { return }
        // Cache IO stays on this actor, outside the UI actor. Disk failure must
        // not discard a valid server response; the session still keeps its tags.
        do {
            try DownloadStorage.prepare(directory)
            try JSONEncoder().encode(Record(key: key, tags: tags)).write(to: file, options: .atomic)
        } catch { }
    }
    func restoring(_ comics: [Comic]) -> [Comic] {
        comics.map { comic in
            var value = comic
            if let tags = tags(for: comic) { value.tags = tags; value.tagsVerified = true }
            return value
        }
    }
}

enum ComicSearchQuery: Equatable, Sendable {
    case text(String), tag(String), tags([String])
    init(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("+") || value.contains("＋") {
            let tokens = value.replacingOccurrences(of: "＋", with: "+").components(separatedBy: "+").map { token in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed.hasPrefix("#") || trimmed.hasPrefix("＃"))
                    ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
            }
            self = .tags(tokens)
            return
        }
        self = value.hasPrefix("#") || value.hasPrefix("＃")
            ? .tag(String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)) : .text(value)
    }
    static func hasTag(_ comic: Comic, _ tag: String) -> Bool {
        let expected = normalizedTag(tag)
        return !expected.isEmpty && comic.tags.contains { normalizedTag($0) == expected }
    }
    static func normalizedTag(_ tag: String) -> String {
        let simplified = NSString(string: tag).applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? tag
        return RecommendationRanking.normalized(simplified)
    }
    static func traditionalTag(_ tag: String) -> String {
        NSString(string: tag).applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? tag
    }
    static func matchesText(_ comic: Comic, _ query: String) -> Bool {
        let expected = RecommendationRanking.normalized(query)
        guard !expected.isEmpty else { return false }
        return RecommendationRanking.normalized(comic.title).contains(expected)
            || RecommendationRanking.normalized(comic.id) == expected
            || comic.tags.contains { RecommendationRanking.normalized($0).contains(expected) }
    }
    func results(using api: any ComicAPI, page: Int) async throws -> [Comic] {
        switch self {
        case .text(let text): return try await api.search(text, page: page)
        case .tag(let tag):
            guard !tag.isEmpty else { throw JMError.message("请输入 # 后面的标签。") }
            return try await api.searchTag(tag, page: page).filter { Self.hasTag($0, tag) }
        case .tags(let tags):
            guard tags.count >= 2, tags.allSatisfy({ !$0.isEmpty }) else { throw JMError.message("请在 + 两侧输入完整标签。") }
            return try await api.searchTags(tags, page: page).filter { comic in tags.allSatisfy { Self.hasTag(comic, $0) } }
        }
    }
}

enum ComicSearchScope: Hashable { case general, favorites, recommendations }
struct ComicSearchState {
    var query: ComicSearchQuery?
    var results: [Comic] = []
    var searching = false
    var page = 0
    var load = LibraryLoadProgress(stage: "准备搜索")
    var failure: String?
    var failureKind: LibraryFailureKind?
}
