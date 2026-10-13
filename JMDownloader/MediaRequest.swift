import Foundation

struct ImageHTTPError: Error, LocalizedError {
    let status: Int
    var errorDescription: String? { "图片服务器返回 HTTP \(status)，可用图片线路已尝试，进度已保留。" }
}

// PicACG now returns legacy storage routes and transformed-image routes.
// Route compatibility follows the public PicACG client protocol (see THIRD_PARTY_NOTICES).
// Never forward account tokens/cookies to media hosts, or replace arbitrary custom hosts.
enum MediaRequest {
    static let storageHosts = ["storage-b.picacomic.com", "s3.picacomic.com", "storage1.diwodiwo.xyz", "storage.tipatipa.xyz"]
    static let imageHosts = ["img.picacomic.com", "img.diwodiwo.xyz", "img.tipatipa.xyz"]
    static func imageHost(for host: String) -> String? {
        for domain in ["picacomic.com", "diwodiwo.xyz", "tipatipa.xyz"] {
            if ["storage-b", "s3", "storage1", "storage"].contains(where: { host == $0 + "." + domain }) {
                return "img." + domain
            }
        }
        return nil
    }
    static func picaURLs(_ original: URL) -> [URL] {
        guard var parts = URLComponents(url: original, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil else { return [original] }
        var path = parts.percentEncodedPath
        while path.hasPrefix("/static/static/") { path = String(path.dropFirst(7)) }
        var alternatives: [String] = []
        if let imageHost = imageHost(for: host) {
            if path.hasPrefix("/static/tobeimg/") {
                parts.host = imageHost; path = String(path.dropFirst("/static/tobeimg".count))
                alternatives = imageHosts
            } else {
                if path.hasPrefix("/static/tobs/") { path = "/static/" + path.dropFirst("/static/tobs/".count) }
                alternatives = storageHosts
            }
        } else if imageHosts.contains(host) { alternatives = imageHosts }
        parts.percentEncodedPath = path
        var result = [parts.url ?? original]
        for candidate in alternatives where candidate != parts.host {
            parts.host = candidate
            if let url = parts.url, !result.contains(url) { result.append(url) }
        }
        return result
    }
    static func make(url: URL, platform: ComicPlatform, preferences: Preferences) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if platform == .picacg {
            request.setValue("okhttp/3.8.1", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("com.JMComic3.app", forHTTPHeaderField: "X-Requested-With")
            request.setValue("https://\((try? Validation.hosts(preferences.effectiveJMDomains).first) ?? "www.cdnhjk.net")", forHTTPHeaderField: "Referer")
        }
        return request
    }
    static func canRetry(_ error: Error) -> Bool {
        if let network = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost].contains(network.code)
        }
        guard let http = error as? ImageHTTPError else { return false }
        return [403, 404, 408, 429, 500, 502, 503, 504].contains(http.status)
    }
}
