import Foundation

enum ComicPlatform: String, Codable, CaseIterable, Sendable {
    case jmcomic, picacg
    var label: String { self == .jmcomic ? "JMComic" : "PicACG" }
    func accountKey(_ username: String) -> String { self == .jmcomic ? username : "picacg:" + username }
    static func ofAccount(_ key: String) -> Self { key.hasPrefix("picacg:") ? .picacg : .jmcomic }
    static func username(_ key: String) -> String { key.hasPrefix("picacg:") ? String(key.dropFirst(7)) : key }
}

enum FavoriteVisibility: Sendable, Equatable {
    case regular, downloaded, hidden
    func includes(downloaded: Bool, hidden: Bool) -> Bool {
        switch self {
        case .regular: !downloaded && !hidden
        case .downloaded: downloaded && !hidden
        case .hidden: hidden
        }
    }
}

enum RecommendationSort: String, Codable, CaseIterable, Sendable {
    case latest = "最新", likes = "最多爱心", clicks = "最多点击", views = "最多查看"
    // Both services expose one view counter, not a separate click ranking.
    var jmOrder: String { switch self { case .latest: "mr"; case .likes: "tf"; case .clicks, .views: "mv" } }
    var picaOrder: String { switch self { case .latest: "dd"; case .likes: "ld"; case .clicks, .views: "vd" } }
}

protocol ComicAPI: Sendable {
    func savedSession() async -> ServiceSession?
    func login(username: String, password: String) async throws
    func favorites() async throws -> [Comic]
    func favorites(progress: @escaping LibraryProgressHandler) async throws -> [Comic]
    func search(_ query: String, page: Int) async throws -> [Comic]
    func searchTag(_ tag: String, page: Int) async throws -> [Comic]
    func searchTags(_ tags: [String], page: Int) async throws -> [Comic]
    func recommendations(from favorites: [Comic]) async throws -> [Comic]
    func recommendations(from favorites: [Comic], sort: RecommendationSort) async throws -> [Comic]
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String]) async throws -> [Comic]
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String], progress: @escaping LibraryProgressHandler, results: @escaping LibraryResultsHandler) async throws -> [Comic]
    func manifest(for comic: Comic) async throws -> [PageAsset]
}
extension ComicAPI {
    func searchTags(_ tags: [String], page: Int) async throws -> [Comic] {
        guard let first = tags.first, tags.allSatisfy({ !$0.isEmpty }) else { throw JMError.message("请输入完整标签。") }
        // The first exact tag supplies candidates; complete metadata must contain every tag.
        return try await searchTag(first, page: page).filter { comic in tags.allSatisfy { ComicSearchQuery.hasTag(comic, $0) } }
    }
    func searchTag(_ tag: String, page: Int) async throws -> [Comic] {
        try await search(tag, page: page).filter { ComicSearchQuery.hasTag($0, tag) }
    }
    func favorites(progress: @escaping LibraryProgressHandler) async throws -> [Comic] {
        let comics = try await favorites()
        await progress(.init(stage: "收藏加载完成", fraction: 1, completed: comics.count, total: comics.count))
        return comics
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String], progress: @escaping LibraryProgressHandler, results: @escaping LibraryResultsHandler) async throws -> [Comic] {
        let comics = try await recommendations(from: favorites, sort: sort, preferredTags: preferredTags, blacklist: blacklist)
        await results(comics)
        await progress(.init(stage: "推荐加载完成", fraction: 1, completed: comics.count, total: comics.count))
        return comics
    }
    func savedSession() async -> ServiceSession? { nil }
    func recommendations(from favorites: [Comic], sort: RecommendationSort) async throws -> [Comic] {
        try await recommendations(from: favorites)
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String]) async throws -> [Comic] {
        try await recommendations(from: favorites, sort: sort)
    }
}

struct ServiceSession: Codable, Sendable {
    var platform: ComicPlatform
    var host: String
    var cookies: [String: String] = [:]
    var version: String = "1.8.0"
    var token: String = ""
}

struct Comic: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var folders: [String] = []
    var tags: [String] = []
    var reason: String = ""
    var platform: ComicPlatform? = nil
    var coverURL: URL? = nil
    var tagsVerified: Bool? = nil
    var source: ComicPlatform { platform ?? .jmcomic }
    var reference: String { "\(source.label) \(id)" }
}

enum JobState: String, Codable, Sendable {
    case queued, preparing, downloading, exporting, paused, completed, failed, deleted
    var isRunning: Bool { [.queued, .preparing, .downloading, .exporting].contains(self) }
    var sortPriority: Int {
        switch self {
        case .downloading: 0
        case .exporting: 1
        case .preparing: 2
        case .queued: 3
        case .paused: 4
        case .failed: 5
        case .completed: 6
        case .deleted: 7
        }
    }
    var label: String {
        switch self {
        case .queued: "等待下载"
        case .preparing: "读取章节"
        case .downloading: "下载中"
        case .exporting: "生成 PDF"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "需要重试"
        case .deleted: "已删除"
        }
    }
}

struct PageAsset: Codable, Sendable {
    var url: URL
    var chapterID: String
    var filename: String
    var scrambleID: Int
}

struct DownloadJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var owner: String
    var comic: Comic
    var state: JobState = .queued
    var pages: [PageAsset] = []
    var finished: Set<Int> = []
    var message = ""
    var output: URL?
    var created = Date()
    var resumeAutomatically: Bool? = nil
    var renderedPages: Int? = nil
    var skippedPages: Set<Int>? = nil
    var exclusionApproved: Bool? = nil
    var progress: Double { pages.isEmpty ? 0 : Double(finished.count) / Double(pages.count) }
    var exportProgress: Double { pages.isEmpty ? 0 : min(1, Double(renderedPages ?? 0) / Double(pages.count)) }
    var displayProgress: Double { state == .exporting ? exportProgress : progress }
    var progressLabel: String {
        if state == .exporting { return "\(min(99, Int(exportProgress * 100)))%" }
        return pages.isEmpty ? comic.reference : "\(finished.count) / \(pages.count) 张"
    }
    var workUnits: Int64 {
        if state == .completed { return 1000 }
        let download = min(700, Int(progress * 700))
        let render = pages.isEmpty ? 0 : min(299, (renderedPages ?? 0) * 299 / pages.count)
        return Int64(download + render)
    }
}

struct Preferences: Codable, Equatable, Sendable {
    static let defaultJMDomains = "www.cdnhjk.net,www.cdngwc.cc,www.cdngwc.net,www.cdngwc.club"
    static let defaultImageDomain = "cdn-msp.jmapiproxy1.cc"
    static let defaultPicaDomain = "picaapi.picacomic.com"
    var domains = "www.cdnhjk.net,www.cdngwc.cc,www.cdngwc.net,www.cdngwc.club"
    var imageDomain = "cdn-msp.jmapiproxy1.cc"
    var proxyHost = ""
    var proxyPort = 7890
    var concurrency = 6
    var remember = true
    var autoDownload = false
    var hideCompleted = false
    var hideDeleted = true
    // Decode 1.6.0 only to retire its external storage grant on upgrade.
    var storageRootBookmark: Data? = nil
    var rootDirectoryDefaultRestored: Bool? = nil
    var directoryBookmark: Data?
    var directoryName = "我的 iPhone / JM downloader"
    // Optional additions preserve decoding of version 1.0 snapshots.
    var recommendationOrder: RecommendationSort? = nil
    var recommendationTags: [String]? = nil
    var tagBlacklist: String? = nil
    var titleBlacklist: String? = nil
    var picaDomain: String? = nil
    var selectedPlatform: ComicPlatform? = nil
    var appearance: String? = nil
    var themeColor: String? = nil
    @discardableResult mutating func restoreRootDirectoryDefault() -> Bool {
        guard rootDirectoryDefaultRestored != true else { return false }
        storageRootBookmark = nil; directoryBookmark = nil
        directoryName = "我的 iPhone / JM downloader"
        rootDirectoryDefaultRestored = true
        return true
    }
    var effectiveJMDomains: String { domains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultJMDomains : domains }
    var effectiveImageDomain: String { imageDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultImageDomain : imageDomain }
    var effectivePicaDomain: String { (picaDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPicaDomain : picaDomain! }
}

struct Library: Codable, Sendable {
    var favorites: [Comic] = []
    var excluded: [Comic] = []
    // Optional for snapshots saved before favorite hiding was introduced.
    var hiddenComicKeys: Set<String>? = nil
    var hiddenComics: [Comic]? = nil
    var dislikedComicKeys: Set<String>? = nil
    var cachedRecommendations: [Comic]? = nil
    var cachedRecommendationOrder: RecommendationSort? = nil
}

struct AppSnapshot: Codable, Sendable {
    var preferences = Preferences()
    var libraries: [String: Library] = [:]
    var jobs: [DownloadJob] = []
    var lastAccount: String = ""
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    var text: String
}

enum JMError: LocalizedError {
    case message(String)
    case authenticationExpired
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .authenticationExpired: "登录会话已失效，请在账号设置中重新登录。"
        }
    }
}

enum Validation {
    static func numericID(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw JMError.message("接口返回了无效漫画 ID。")
        }
        return value
    }
    static func hosts(_ value: String) throws -> [String] {
        let values = value.replacingOccurrences(of: "，", with: ",").split { $0 == "," || $0.isWhitespace }
        let result = try values.map { value -> String in
            let raw = String(value)
            guard let url = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
                  url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/", url.port == nil else {
                throw JMError.message("API / 图片域名须为 HTTPS 主机，不含路径、端口或账号。")
            }
            return host
        }
        guard !result.isEmpty else { throw JMError.message("请至少填写一个 API 域名。") }
        return result
    }
    static func safeName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r").union(.controlCharacters)
        let name = String(title.components(separatedBy: invalid).joined(separator: "_").prefix(65))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "漫画" : name
    }
}
