import Foundation
import Network

enum NetworkConfiguration {
    static func apply(_ preferences: Preferences, to config: URLSessionConfiguration) throws {
        let host = preferences.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            guard !host.contains("://"), !host.contains("/"), !host.contains("@"),
                  let port = NWEndpoint.Port(rawValue: UInt16(clamping: preferences.proxyPort)),
                  (1...65535).contains(preferences.proxyPort) else {
                throw JMError.message("代理请分别填写主机和 1–65535 端口；不支持带认证信息的地址。")
            }
            if #available(iOS 17.0, *) {
                config.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: port))]
            } else {
                config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": preferences.proxyPort,
                    "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": preferences.proxyPort]
            }
        }
        config.httpMaximumConnectionsPerHost = max(1, min(12, preferences.concurrency))
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 60 * 60 * 24
    }
}

actor JMAPI: ComicAPI {
    private let tagCache: ComicTagCache
    private let session: URLSession
    private var hosts: [String]
    private var pinned: String?
    private var routeFailures: [String: Date] = [:]
    private var cookies: [String: String] = [:]
    private var version = "2.1.7"
    private let imageHost: String

    init(preferences: Preferences, savedSession: ServiceSession? = nil, configuration: URLSessionConfiguration? = nil, tagCache: ComicTagCache = ComicTagCache()) throws {
        self.tagCache = tagCache
        hosts = try Validation.hosts(preferences.effectiveJMDomains)
        imageHost = try Validation.hosts(preferences.effectiveImageDomain)[0]
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        try NetworkConfiguration.apply(preferences, to: config)
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        if let savedSession, savedSession.platform == .jmcomic, hosts.contains(savedSession.host) {
            pinned = savedSession.host; cookies = savedSession.cookies; version = savedSession.version
        }
    }
    func savedSession() async -> ServiceSession? {
        guard let pinned, !(cookies["AVS"] ?? "").isEmpty else { return nil }
        return ServiceSession(platform: .jmcomic, host: pinned, cookies: cookies, version: version)
    }

    private func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private func raw(_ path: String, query: [String: String] = [:], form: [String: String]? = nil) async throws -> (Data, String) {
        var lastError: Error = JMError.message("无法连接 API。")
        let requestCookies = cookies
        let preferred = pinned
        let routes = preferred.map { [$0] + hosts.filter { $0 != preferred } } ?? hosts
        let healthy = routes.filter { (routeFailures[$0] ?? .distantPast) < Date().addingTimeInterval(-60) }
        for host in (healthy.isEmpty ? routes : healthy) {
            try Task.checkCancellation()
            do {
                var components = URLComponents()
                components.scheme = "https"; components.host = host; components.path = path
                components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = components.url else { throw JMError.message("API 地址无效。") }
                let ts = String(Int(Date().timeIntervalSince1970))
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.setValue(JMCrypto.md5(ts + (path == "/chapter_view_template" ? "18comicAPPContent" : JMCrypto.secret)), forHTTPHeaderField: "token")
                request.setValue("\(ts),\(version)", forHTTPHeaderField: "tokenparam")
                request.setValue("Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 Chrome/91.0.4472.114 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
                if host == preferred { request.setValue(requestCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
                if let form {
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var encoded = URLComponents()
                    encoded.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
                    request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw JMError.message("API 响应无效。") }
                if http.statusCode == 401 { throw JMError.authenticationExpired }
                guard http.statusCode == 200 else { throw JMError.message("连接失败（HTTP \(http.statusCode)），请检查线路或稍后重试。") }
                if host != preferred && !requestCookies.isEmpty {
                    // A fallback backend must establish its own session, not inherit another host's cookie.
                    pinned = host; cookies = [:]
                    throw JMError.authenticationExpired
                }
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { cookies[cookie.name] = cookie.value }
                // Prefer the healthy backend; transport failures still try the configured alternatives.
                pinned = host; routeFailures[host] = nil
                return (data, ts)
            } catch is CancellationError { throw CancellationError() }
            catch JMError.authenticationExpired { throw JMError.authenticationExpired }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                routeFailures[host] = Date()
                lastError = JMTransportError(host: host, underlying: error)
            }
            catch { lastError = error }
        }
        throw lastError
    }
    private func request(_ path: String, query: [String: String] = [:], form: [String: String]? = nil) async throws -> [String: Any] {
        let (data, ts) = try await raw(path, query: query, form: form)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JMError.message("API 未返回有效 JSON。")
        }
        guard text(envelope["code"]) == "200" else {
            let code = text(envelope["code"])
            if code == "401" { throw JMError.authenticationExpired }
            throw JMError.message("站点拒绝请求，请检查账号或线路（\(code)）。")
        }
        if let object = envelope["data"] as? [String: Any] { return object }
        // Removed albums are reported by the service as code=200, data=[].
        // They are individual unavailable search candidates, not a changed API.
        if path == "/album", envelope["data"] is [Any] || envelope["data"] is NSNull {
            throw RecommendationDetailUnavailable()
        }
        guard let encoded = envelope["data"] as? String else {
            throw JMError.message("API 数据结构已变化。")
        }
        let decoded = try JSONSerialization.jsonObject(with: JMCrypto.decrypt(encoded, timestamp: ts))
        if let object = decoded as? [String: Any] { return object }
        if path == "/album", decoded is [Any] || decoded is NSNull { throw RecommendationDetailUnavailable() }
        throw JMError.message("API 数据结构已变化。")
    }
    func login(username: String, password: String) async throws {
        let setting = try await request("/setting")
        let remoteVersion = text(setting["jm3_version"])
        if remoteVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { version = remoteVersion }
        let data = try await request("/login", form: ["username": username, "password": password])
        guard !text(data["uid"]).isEmpty, !text(data["s"]).isEmpty else { throw JMError.message("登录失败，请检查用户名和密码。") }
        cookies["AVS"] = text(data["s"])
    }
    private func comics(_ rows: [[String: Any]], folder: String? = nil) throws -> [Comic] {
        try rows.map { row in
            Comic(id: try Validation.numericID(text(row["id"])), title: text(row["name"]),
                  folders: folder.map { [$0] } ?? [], tags: row["tags"] as? [String] ?? [])
        }
    }
    private struct FavoritePage: Sendable {
        let comics: [Comic]
        let pages: Int
        let folders: [(String, String)]
    }
    private func favoritePage(_ folder: String, name: String, page: Int) async throws -> FavoritePage {
        let data = try await request("/favorite", query: ["folder_id": folder, "page": "\(page)", "o": "mr"])
        guard let rows = data["list"] as? [[String: Any]], let total = Int(text(data["total"])), total >= 0 else { throw JMError.message("收藏列表数据不完整，请重试。") }
        let count = max(1, (total + 19) / 20)
        guard count <= 10000 else { throw JMError.message("收藏分页异常。") }
        let folders = try (data["folder_list"] as? [[String: Any]] ?? []).map { (try Validation.numericID(text($0["FID"])), text($0["name"])) }
        return FavoritePage(comics: try comics(rows, folder: name), pages: count, folders: folders)
    }
    func favorites() async throws -> [Comic] { try await favorites(progress: { _ in }) }
    func favorites(progress: @escaping LibraryProgressHandler) async throws -> [Comic] {
        var completedPages = 0, knownPages = 0
        var folders = [("0", "默认收藏")], visited = Set<String>(), result: [String: Comic] = [:]
        while !folders.isEmpty {
            let (id, name) = folders.removeFirst()
            guard visited.insert(id).inserted else { continue }
            let first = try await favoritePage(id, name: name, page: 1)
            knownPages += first.pages
            completedPages += 1
            await progress(.step("读取收藏分页", completedPages, knownPages))
            let countBefore = completedPages, total = knownPages
            let remaining = first.pages > 1 ? Array(2...first.pages) : []
            let rest = try await ConcurrentLoad.map(remaining, onValue: { _, _, count in
                await progress(.step("读取收藏分页", countBefore + count, total))
            }) { try await self.favoritePage(id, name: name, page: $0) }
            completedPages += rest.count
            var signatures = Set<String>()
            for page in [first] + rest {
                let entries = page.comics
                let signature = entries.map(\.id).joined(separator: ",")
                guard (entries.isEmpty && first.pages == 1) || (!entries.isEmpty && signatures.insert(signature).inserted) else { throw JMError.message("收藏分页重复或缺失，请重新刷新。") }
                for comic in entries {
                    if var existing = result[comic.id] {
                        if !existing.folders.contains(name) { existing.folders.append(name) }
                        result[comic.id] = existing
                    } else { result[comic.id] = comic }
                }
                for (fid, title) in page.folders where !visited.contains(fid) && !folders.contains(where: { $0.0 == fid }) { folders.append((fid, title)) }
            }
        }
        return result.values.sorted { (Int($0.id) ?? 0) > (Int($1.id) ?? 0) }
    }
    func search(_ query: String, page: Int = 1) async throws -> [Comic] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = value.lowercased().hasPrefix("jm") ? String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces) : value
        if let id = try? Validation.numericID(number) {
            guard page == 1 else { return [] }
            return try comics([try await request("/album", query: ["id": id])])
        }
        let rows = try await sortedSearch(value, page: page, sort: .latest)
        let verified = try await ConcurrentLoad.map(rows, limit: 6) { comic -> Comic? in
            if ComicSearchQuery.matchesText(comic, value) { return comic }
            do {
                let full = try await self.recommendationDetail(comic)
                return ComicSearchQuery.matchesText(full, value) ? full : nil
            } catch is RecommendationDetailUnavailable { return nil }
        }
        return verified.compactMap { $0 }
    }
    func searchTag(_ tag: String, page: Int = 1) async throws -> [Comic] {
        guard !tag.isEmpty else { throw JMError.message("请输入 # 后面的标签。") }
        let rows = try await sortedSearch(tag, page: page, sort: .latest, mainTag: "3")
        let full = try await ConcurrentLoad.map(rows, limit: 6) { comic -> Comic? in
            do { return try await self.recommendationDetail(comic) }
            catch is RecommendationDetailUnavailable { return nil }
        }
        let matching = full.compactMap { $0 }.filter { ComicSearchQuery.hasTag($0, tag) }
        if !matching.isEmpty || ComicSearchQuery.traditionalTag(tag) == tag { return matching }
        let alternate = try await sortedSearch(ComicSearchQuery.traditionalTag(tag), page: page, sort: .latest, mainTag: "3")
        let alternateFull = try await ConcurrentLoad.map(alternate, limit: 6) { comic -> Comic? in
            do { return try await self.recommendationDetail(comic) }
            catch is RecommendationDetailUnavailable { return nil }
        }
        return alternateFull.compactMap { $0 }.filter { ComicSearchQuery.hasTag($0, tag) }
    }
    func searchTags(_ tags: [String], page: Int) async throws -> [Comic] {
        guard tags.count >= 2, tags.allSatisfy({ !$0.isEmpty }) else { throw JMError.message("请输入完整标签。") }
        // The mobile API treats '+' as a literal search character. Use the
        // smallest tag result set as candidates, then verify every album tag.
        let samples = try await ConcurrentLoad.map(tags, limit: 3) { tag in
            let primary = try await self.sortedSearchPage(tag, page: 1, sort: .latest, mainTag: "3")
            if primary.total > 0 || ComicSearchQuery.traditionalTag(tag) == tag { return primary }
            return try await self.sortedSearchPage(ComicSearchQuery.traditionalTag(tag), page: 1, sort: .latest, mainTag: "3")
        }
        guard let chosen = samples.min(by: { $0.total < $1.total }), chosen.total > 0 else { return [] }
        let rows: [Comic]
        if page == 1 { rows = chosen.comics }
        else { rows = try await sortedSearchPage(chosen.query, page: page, sort: .latest, mainTag: "3").comics }
        let full = try await ConcurrentLoad.map(rows, limit: 6) { comic -> Comic? in
            do { return try await self.recommendationDetail(comic) }
            catch is RecommendationDetailUnavailable { return nil }
        }
        return full.compactMap { $0 }.filter { comic in tags.allSatisfy { ComicSearchQuery.hasTag(comic, $0) } }
    }
    private struct SearchPage: Sendable {
        let query: String
        let comics: [Comic]
        let total: Int
    }
    private func sortedSearch(_ query: String, page: Int = 1, sort: RecommendationSort, mainTag: String = "0") async throws -> [Comic] {
        try await sortedSearchPage(query, page: page, sort: sort, mainTag: mainTag).comics
    }
    private func sortedSearchPage(_ query: String, page: Int, sort: RecommendationSort, mainTag: String) async throws -> SearchPage {
        let data = try await request("/search", query: ["search_query": query, "page": "\(page)", "main_tag": mainTag, "o": sort.jmOrder, "t": "a"])
        if !text(data["redirect_aid"]).isEmpty {
            let album = try await request("/album", query: ["id": try Validation.numericID(text(data["redirect_aid"]))])
            return SearchPage(query: query, comics: try comics([album]), total: 1)
        }
        guard let rows = data["content"] as? [[String: Any]] else { throw JMError.message("搜索列表数据不完整。") }
        return SearchPage(query: query, comics: try comics(rows), total: Int(text(data["total"])) ?? rows.count)
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
            search: { try await self.sortedSearch($0, sort: sort, mainTag: "3") }, progress: progress, results: results, detailConcurrency: 6)
    }
    private func recommendationDetail(_ comic: Comic) async throws -> Comic {
        var full = comic
        if let cached = await tagCache.tags(for: comic) { full.tags = cached; full.tagsVerified = true; return full }
        let data = try await request("/album", query: ["id": try Validation.numericID(comic.id)])
        guard let tags = data["tags"] as? [String] else { throw RecommendationDetailUnavailable() }
        full.tags = tags; full.tagsVerified = true
        await tagCache.store(tags, for: comic)
        return full
    }
    func manifest(for comic: Comic) async throws -> [PageAsset] {
        let aid = try Validation.numericID(comic.id)
        let album = try await request("/album", query: ["id": aid])
        let series = (album["series"] as? [[String: Any]] ?? []).sorted { (Int(text($0["sort"])) ?? 0) < (Int(text($1["sort"])) ?? 0) }
        let ids = try series.isEmpty ? [aid] : series.map { try Validation.numericID(text($0["id"])) }
        var pages: [PageAsset] = []
        for id in ids {
            try Task.checkCancellation()
            let chapter = try await request("/chapter", query: ["id": id])
            let (html, _) = try await raw("/chapter_view_template", query: ["id": id, "mode": "vertical", "page": "0", "app_img_shunt": "1", "express": "off", "v": "\(Int(Date().timeIntervalSince1970))"])
            let content = String(data: html, encoding: .utf8) ?? ""
            // The service has emitted several equivalent JS forms over time:
            // var scramble_id = 123, scramble_id: "123", and scrambleId = '123'.
            let pattern = #"(?i)(?:scramble[_-]?id)\s*[\"']?\s*[:=]\s*[\"']?(\d+)"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(content.startIndex..., in: content)
            let scramble = regex.firstMatch(in: content, range: range).flatMap { match -> Int? in
                guard let valueRange = Range(match.range(at: 1), in: content) else { return nil }
                return Int(content[valueRange])
            } ?? Int.max
            if scramble == Int.max { /* Some CDN responses omit the parameter; Int.max means no strip. */ }
            guard let images = chapter["images"] as? [String], !images.isEmpty else { throw JMError.message("章节没有图片。") }
            for filename in images {
                guard filename == (filename as NSString).lastPathComponent, !filename.contains(".."),
                      let url = URL(string: "https://\(imageHost)/media/photos/\(id)/\(filename)") else { throw JMError.message("图片路径无效。") }
                pages.append(PageAsset(url: url, chapterID: id, filename: filename, scrambleID: scramble))
            }
        }
        guard !pages.isEmpty else { throw JMError.message("漫画没有可下载的图片。") }
        return pages
    }
}
