import Foundation
import CryptoKit

actor PicaAPI: ComicAPI {
    static let apiKey = "C69BAF41DA5ABD1FFEDC6D2FEA56B"
    // Public protocol signing constant; this is not a user's credential.
    static let signingKey = #"~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn"#
    private let host: String
    private let tagCache: ComicTagCache
    private let session: URLSession
    private var token = ""

    init(preferences: Preferences, savedSession: ServiceSession? = nil, tagCache: ComicTagCache = ComicTagCache(), configuration: URLSessionConfiguration? = nil) throws {
        self.tagCache = tagCache
        host = try Validation.hosts(preferences.effectivePicaDomain)[0]
        let config = configuration ?? URLSessionConfiguration.ephemeral
        try NetworkConfiguration.apply(preferences, to: config)
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        if let savedSession, savedSession.platform == .picacg, savedSession.host == host { token = savedSession.token }
    }
    func savedSession() async -> ServiceSession? {
        token.isEmpty ? nil : ServiceSession(platform: .picacg, host: host, token: token)
    }
    nonisolated static func signature(route: String, method: String, time: String, nonce: String) -> String {
        let input = (route + time + nonce + method + apiKey).lowercased()
        return HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: Data(signingKey.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func comicID(_ value: String) throws -> String {
        guard value.range(of: "^[a-fA-F0-9]{24}$", options: .regularExpression) != nil else {
            throw JMError.message("PicACG 返回了无效漫画 ID。")
        }
        return value
    }
    nonisolated static func mediaURL(_ media: [String: Any]) throws -> URL {
        guard let server = media["fileServer"] as? String, let path = media["path"] as? String,
              !path.isEmpty, !path.split(separator: "/").contains(".."),
              let base = URLComponents(string: server), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw JMError.message("PicACG 图片地址无效。")
        }
        let root = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + (root.hasSuffix("/static") ? "/" : "/static/") + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw JMError.message("PicACG 图片路径无效。")
        }
        return MediaRequest.picaURLs(url)[0]
    }
    private func request(_ route: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let url = URL(string: "https://\(host)/\(route)") else { throw JMError.message("PicACG API 地址无效。") }
        let time = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        let headers = ["api-key": Self.apiKey, "accept": "application/vnd.picacomic.com.v1+json",
                       "app-channel": "3", "time": time, "nonce": nonce,
                       "signature": Self.signature(route: route, method: method, time: time, nonce: nonce),
                       "app-version": "2.2.1.3.3.4", "app-build-version": "45", "app-uuid": "defaultUuid",
                       "app-platform": "android", "image-quality": "original", "User-Agent": "okhttp/3.8.1",
                       "Content-Type": "application/json; charset=UTF-8"]
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw JMError.message("PicACG API \(host)：" + NetworkFailure.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw JMError.message("PicACG 响应无效。") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw JMError.authenticationExpired }
            let problem = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 429 || String(describing: problem?["error"] ?? "") == "1023"
                || (problem?["message"] as? String ?? "").localizedCaseInsensitiveContains("too many requests") {
                throw JMError.message("PicACG 暂时限制了当前线路的请求，请稍后再试；这不代表密码错误。")
            }
            throw JMError.message([400, 401, 422].contains(http.statusCode)
                ? "PicACG 登录或会话被拒绝，请核对账号密码并重新登录。"
                : "PicACG 连接失败（HTTP \(http.statusCode)），请稍后重试或检查网络。")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["code"] as? Int == 200, let result = envelope["data"] as? [String: Any] else {
            throw JMError.message("PicACG 接口数据无效。")
        }
        return result
    }
    func login(username: String, password: String) async throws {
        let data = try await request("auth/sign-in", method: "POST", body: ["email": username, "password": password])
        guard let value = data["token"] as? String, !value.isEmpty else { throw JMError.message("PicACG 登录失败。") }
        token = value
    }
    private func paginated(_ route: String, key: String) async throws -> [[String: Any]] {
        var page = 1, total = 1, rows: [[String: Any]] = [], seen = Set<String>()
        repeat {
            let data = try await request(route.replacingOccurrences(of: "{page}", with: "\(page)"))
            guard let collection = data[key] as? [String: Any], let docs = collection["docs"] as? [[String: Any]],
                  let pages = collection["pages"] as? Int, (0...10000).contains(pages) else { throw JMError.message("PicACG 分页数据不完整。") }
            total = max(1, pages)
            let signature = docs.map { String(describing: $0["_id"] ?? $0["id"] ?? $0["order"] ?? "") }.joined(separator: ",")
            guard (docs.isEmpty && total == 1 && page == 1) || (!docs.isEmpty && seen.insert(signature).inserted) else {
                throw JMError.message("PicACG 分页重复或缺失，请重试。")
            }
            rows += docs; page += 1
        } while page <= total
        return rows
    }
    private func comic(_ row: [String: Any]) throws -> Comic {
        let cover = try (row["thumb"] as? [String: Any]).map { try Self.mediaURL($0) }
        return Comic(id: try Self.comicID(row["_id"] as? String ?? row["id"] as? String ?? ""),
                     title: row["title"] as? String ?? "未命名漫画", folders: ["PicACG 收藏"],
                     tags: row["tags"] as? [String] ?? [], platform: .picacg, coverURL: cover, tagsVerified: row["tags"] is [String])
    }
    private func favoritePage(_ page: Int) async throws -> (comics: [Comic], pages: Int) {
        let data = try await request("users/favourite?s=dd&page=\(page)")
        guard let collection = data["comics"] as? [String: Any], let docs = collection["docs"] as? [[String: Any]],
              let pages = collection["pages"] as? Int, (0...10000).contains(pages) else { throw JMError.message("PicACG 分页数据不完整。") }
        return (try docs.map { try comic($0) }, max(1, pages))
    }
    func favorites() async throws -> [Comic] { try await favorites(progress: { _ in }) }
    func favorites(progress: @escaping LibraryProgressHandler) async throws -> [Comic] {
        let first = try await favoritePage(1)
        await progress(.step("读取收藏分页", 1, first.pages))
        let remaining = first.pages > 1 ? Array(2...first.pages) : []
        let rest = try await ConcurrentLoad.map(remaining, onValue: { _, _, count in
            await progress(.step("读取收藏分页", count + 1, first.pages))
        }) { try await self.favoritePage($0).comics }
        var seen = Set<String>()
        for page in [first.comics] + rest {
            let signature = page.map(\.id).joined(separator: ",")
            guard (page.isEmpty && first.pages == 1) || (!page.isEmpty && seen.insert(signature).inserted) else { throw JMError.message("PicACG 分页重复或缺失，请重试。") }
        }
        return [first.comics] .flatMap { $0 } + rest.flatMap { $0 }
    }
    func search(_ query: String, page: Int = 1) async throws -> [Comic] {
        let pages = try await ConcurrentLoad.map(ComicSearchQuery.variants(query), limit: 2) {
            try await self.sortedSearch($0, page: page, sort: .latest)
        }
        let rows = uniqueComics(pages.flatMap { $0 })
        let verified = try await ConcurrentLoad.map(rows, limit: 3) { comic -> Comic? in
            do {
                let full = try await self.searchDetail(comic)
                return ComicSearchQuery.matchesText(full, query) ? full : nil
            } catch is RecommendationDetailUnavailable { return nil }
        }
        return verified.compactMap { $0 }
    }
    func searchTag(_ tag: String, page: Int = 1) async throws -> [Comic] {
        guard !tag.isEmpty else { throw JMError.message("请输入 # 后面的标签。") }
        let pages = try await ConcurrentLoad.map(ComicSearchQuery.variants(tag), limit: 2) {
            try await self.sortedSearch($0, page: page, sort: .latest)
        }
        let full = try await verifiedSearchComics(uniqueComics(pages.flatMap { $0 }))
        return full.filter { ComicSearchQuery.hasTag($0, tag) }
    }
    func searchTags(_ tags: [String], page: Int) async throws -> [Comic] {
        guard tags.count >= 2, tags.allSatisfy({ !$0.isEmpty }) else { throw JMError.message("请输入完整标签。") }
        let samples = try await ConcurrentLoad.map(tags, limit: 2) { tag in
            let variants = try await ConcurrentLoad.map(ComicSearchQuery.variants(tag), limit: 2) {
                try await self.sortedSearchPage($0, page: 1, sort: .latest)
            }
            return variants.max(by: { $0.total < $1.total })!
        }
        guard let chosen = samples.min(by: { $0.total < $1.total }), chosen.total > 0 else { return [] }
        let start = (max(1, page) - 1) * 3 + 1
        guard start <= chosen.pages else { return [] }
        let pages = try await ConcurrentLoad.map(Array(start...min(chosen.pages, start + 2)), limit: 2) { index in
            if index == 1 { return chosen.comics }
            return try await self.sortedSearchPage(chosen.query, page: index, sort: .latest).comics
        }
        return try await verifiedSearchComics(uniqueComics(pages.flatMap { $0 })).filter { comic in
            tags.allSatisfy { ComicSearchQuery.hasTag(comic, $0) }
        }
    }
    private func uniqueComics(_ comics: [Comic]) -> [Comic] {
        var seen = Set<String>()
        return comics.filter { seen.insert($0.id).inserted }
    }
    private func verifiedSearchComics(_ comics: [Comic]) async throws -> [Comic] {
        try await ConcurrentLoad.map(comics, limit: 3) { comic -> Comic? in
            do { return try await self.searchDetail(comic) }
            catch is RecommendationDetailUnavailable { return nil }
        }.compactMap { $0 }
    }
    private func searchDetail(_ candidate: Comic) async throws -> Comic {
        let data = try await request("comics/\(try Self.comicID(candidate.id))")
        guard let row = data["comic"] as? [String: Any], row["tags"] is [String] else { throw RecommendationDetailUnavailable() }
        var full = try comic(row)
        guard full.id == candidate.id else { throw RecommendationDetailUnavailable() }
        full.folders = candidate.folders
        full.coverURL = full.coverURL ?? candidate.coverURL
        await tagCache.store(full.tags, for: full)
        return full
    }
    private struct SearchPage: Sendable {
        let query: String
        let comics: [Comic]
        let pages: Int
        let total: Int
    }
    private func sortedSearch(_ query: String, page: Int = 1, sort: RecommendationSort) async throws -> [Comic] {
        try await sortedSearchPage(query, page: page, sort: sort).comics
    }
    private func sortedSearchPage(_ query: String, page: Int, sort: RecommendationSort) async throws -> SearchPage {
        let data = try await request("comics/advanced-search?page=\(page)", method: "POST",
                                     body: ["categories": [], "keyword": query, "sort": sort.picaOrder])
        guard let collection = data["comics"] as? [String: Any], let docs = collection["docs"] as? [[String: Any]] else {
            throw JMError.message("PicACG 搜索数据无效。")
        }
        return SearchPage(query: query, comics: try docs.map { try comic($0) },
            pages: max(1, collection["pages"] as? Int ?? 1), total: collection["total"] as? Int ?? docs.count)
    }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] {
        try await recommendations(from: favorites, sort: .latest, preferredTags: [], blacklist: [])
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort) async throws -> [Comic] {
        try await recommendations(from: favorites, sort: sort, preferredTags: [], blacklist: [])
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String]) async throws -> [Comic] {
        try await recommendations(from: favorites, sort: sort, preferredTags: preferredTags, blacklist: blacklist, progress: { _ in }, results: { _ in })
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String], progress: @escaping LibraryProgressHandler, results: @escaping LibraryResultsHandler) async throws -> [Comic] {
        let seed = await tagCache.restoring(favorites)
        return try await RecommendationRanking.recommendations(from: seed, blacklist: blacklist,
            detail: { try await self.recommendationDetail($0) },
            search: { try await self.sortedSearch($0, sort: sort) }, progress: progress, results: results)
    }
    private func recommendationDetail(_ comic: Comic) async throws -> Comic {
        var full = comic
        if comic.tagsVerified == true { await tagCache.store(comic.tags, for: comic); return comic }
        if let cached = await tagCache.tags(for: comic) { full.tags = cached; full.tagsVerified = true; return full }
        let data = try await request("comics/\(try Self.comicID(comic.id))")
        guard let tags = (data["comic"] as? [String: Any])?["tags"] as? [String] else {
            throw RecommendationDetailUnavailable()
        }
        full.tags = tags; full.tagsVerified = true
        await tagCache.store(tags, for: comic)
        return full
    }
    func manifest(for comic: Comic) async throws -> [PageAsset] {
        let id = try Self.comicID(comic.id)
        let chapters = try await paginated("comics/\(id)/eps?page={page}", key: "eps")
            .sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
        var result: [PageAsset] = []
        for chapter in chapters {
            guard let order = chapter["order"] as? Int, order >= 0 else { throw JMError.message("PicACG 章节数据无效。") }
            let pages = try await paginated("comics/\(id)/order/\(order)/pages?page={page}", key: "pages")
            guard !pages.isEmpty else { throw JMError.message("PicACG 章节没有图片。") }
            for (index, page) in pages.enumerated() {
                guard let media = page["media"] as? [String: Any] else { throw JMError.message("PicACG 图片数据缺失。") }
                result.append(PageAsset(url: try Self.mediaURL(media), chapterID: "0", filename: "\(order)-\(index).jpg", scrambleID: Int.max))
            }
        }
        guard !result.isEmpty else { throw JMError.message("PicACG 漫画没有可下载章节。") }
        return result
    }
}
