#if DEBUG
import UIKit

extension AppStore {
    func loadUIFixture() {
        account = "preview"
        clients[account] = FixtureAPI()
        preferences.tagBlacklist = "AI"
        if ProcessInfo.processInfo.arguments.contains("--dark-fixture") { preferences.appearance = "深色" }
        var comics = [Comic(id: "10001", title: "已保存的漫画", folders: ["默认收藏"]),
                      Comic(id: "10002", title: "正在下载的漫画", folders: ["默认收藏"]),
                      Comic(id: "10003", title: "等待继续的漫画", folders: ["默认收藏"])]
        if ProcessInfo.processInfo.arguments.contains("--long-library-fixture") {
            comics += (4...75).map { Comic(id: "\(10000 + $0)", title: "列表漫画 \($0)", folders: ["默认收藏"]) }
        }
        libraries[account] = Library(favorites: comics)
        if ProcessInfo.processInfo.arguments.contains("--favorite-loading-fixture") { libraries[account]?.favorites = [] }
        jobs = [DownloadJob(owner: account, comic: comics[0], state: .completed),
                DownloadJob(owner: account, comic: comics[2], state: .paused),
                DownloadJob(owner: account, comic: comics[1], state: .downloading)]
        if ProcessInfo.processInfo.arguments.contains("--mixed-download-states-fixture") {
            let page = PageAsset(url: URL(string: "https://fixture.invalid/image")!, chapterID: "0", filename: "image", scrambleID: Int.max)
            jobs.append(DownloadJob(owner: account, comic: Comic(id: "10004", title: "正在生成 PDF 的漫画"),
                state: .exporting, pages: Array(repeating: page, count: 40), finished: Set(0..<40), renderedPages: 10))
            jobs.append(DownloadJob(owner: account, comic: Comic(id: "10005", title: "正在读取章节的漫画"), state: .preparing))
            jobs.append(DownloadJob(owner: account, comic: Comic(id: "10006", title: "新开始下载的漫画"), state: .downloading))
        }
        loadRecommendations(silently: true)
        if ProcessInfo.processInfo.arguments.contains("--favorite-loading-fixture") { refreshFavorites(silently: true) }
        if ProcessInfo.processInfo.arguments.contains("--progress-stress-fixture"), let id = jobs.last?.id {
            let page = PageAsset(url: URL(string: "https://fixture.invalid/image")!, chapterID: "0", filename: "image", scrambleID: Int.max)
            change(id) { $0.state = .exporting; $0.pages = Array(repeating: page, count: 3000); $0.finished = Set(0..<3000) }
            log("正在生成 PDF，图片缓存已保留")
            Task { [weak self] in
                for count in 1...1200 {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard let self, self.jobs.first(where: { $0.id == id })?.state == .exporting else { return }
                    self.change(id) { $0.renderedPages = count }
                }
            }
        }
        Task {
            for (index, comic) in comics.enumerated() {
                let data = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 120)).pngData { context in
                    [UIColor.systemBlue, .systemOrange, .systemGreen][index % 3].setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 90, height: 120))
                }
                try? await CoverCache.shared.insert(data, key: DownloadCatalog.key(comic))
            }
        }
    }
}
private actor FixtureAPI: ComicAPI {
    func login(username: String, password: String) async throws { }
    func favorites() async throws -> [Comic] { [] }
    func favorites(progress: @escaping LibraryProgressHandler) async throws -> [Comic] {
        if ProcessInfo.processInfo.arguments.contains("--favorite-loading-fixture") {
            await progress(.step("读取收藏分页", 4, 20))
            try await Task.sleep(for: .seconds(90))
        }
        return []
    }
    func search(_ query: String, page: Int) async throws -> [Comic] {
        guard page == 1 else { return [] }
        let rows = [Comic(id: "20001", title: "主动搜索的 AI 漫画", tags: ["AI绘图", "剧情"], tagsVerified: true),
                    Comic(id: "20002", title: "仅含一个标签的漫画", tags: ["AI绘图扩展", "校园"], tagsVerified: true),
                    Comic(id: "10001", title: "已保存的漫画")]
        return rows.filter { ComicSearchQuery.matchesText($0, query) }
    }
    func recommendations(from favorites: [Comic]) async throws -> [Comic] {
        if ProcessInfo.processInfo.arguments.contains("--recommendation-loading-fixture") {
            try await Task.sleep(for: .seconds(30))
        }
        if ProcessInfo.processInfo.arguments.contains("--recommendation-failure-fixture") { throw JMError.authenticationExpired }
        if ProcessInfo.processInfo.arguments.contains("--recommendation-offline-fixture") { throw URLError(.timedOut) }
        return favorites
    }
    func recommendations(from favorites: [Comic], sort: RecommendationSort, preferredTags: [String], blacklist: [String], progress: @escaping LibraryProgressHandler, results: @escaping LibraryResultsHandler) async throws -> [Comic] {
        if ProcessInfo.processInfo.arguments.contains("--recommendation-stream-fixture") {
            await results(favorites)
            await progress(.step("核验推荐漫画", 2, 10, from: 0.55))
            try await Task.sleep(for: .seconds(90))
            return favorites
        }
        return try await recommendations(from: favorites)
    }
    func manifest(for comic: Comic) async throws -> [PageAsset] { [] }
}
#endif
