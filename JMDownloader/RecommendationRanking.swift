import Foundation

struct RecommendationDetailUnavailable: LocalizedError {
    var errorDescription: String? { "漫画标签数据不完整，暂不参与推荐。" }
}

/// Search only retrieves candidates. Full album tags determine relevance.
enum RecommendationRanking {
    private static let generic: Set<String> = ["汉化", "漢化", "中文", "中国翻译", "中國翻譯", "全彩", "完結", "完结", "连载", "連載", "同人", "日文", "英文"]
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func tags(_ comic: Comic) -> Set<String> {
        Set(comic.tags.map(normalized).filter { !$0.isEmpty && !generic.contains($0) })
    }
    static func blocked(_ comic: Comic, blacklist: [String]) -> Bool {
        let tokens = blacklist.map(normalized).filter { !$0.isEmpty }
        return comic.tags.contains { tag in tokens.contains { normalized(tag).contains($0) } }
    }
    static func recommendations(
        from favorites: [Comic], blacklist: [String],
        detail: @escaping @Sendable (Comic) async throws -> Comic,
        search: @escaping @Sendable (String) async throws -> [Comic],
        progress: @escaping LibraryProgressHandler = { _ in },
        results: @escaping LibraryResultsHandler = { _ in },
        detailConcurrency: Int = 3
    ) async throws -> [Comic] {
        guard !favorites.isEmpty else { return [] }
        var weights: [String: Int] = [:]
        var favoriteKeys = Set<String>()
        let unique = favorites.filter { favoriteKeys.insert(DownloadCatalog.key($0)).inserted }
        // Inspect every favorite. A removed/malformed detail must not discard other
        // valid tastes; transport and session failures still fail the refresh.
        let cached = unique.filter { $0.tagsVerified == true }
        let missing = unique.filter { $0.tagsVerified != true }
        await progress(.step(missing.isEmpty ? "复用收藏标签" : "读取收藏标签", cached.count, unique.count, to: 0.4))
        let loaded = try await ConcurrentLoad.map(missing, limit: detailConcurrency, onValue: { _, _, count in
            await progress(.step("读取收藏标签", cached.count + count, unique.count, to: 0.4))
        }) { comic -> Comic? in
            do { return try await detail(comic) }
            catch is RecommendationDetailUnavailable { return nil }
        }
        let fullFavorites = cached + loaded.compactMap({ $0 })
        if fullFavorites.isEmpty { throw RecommendationDetailUnavailable() }
        for full in fullFavorites {
            try Task.checkCancellation()
            // Count each tag once per favorite, so duplicate tags cannot skew taste.
            for tag in tags(full) { weights[tag, default: 0] += 1 }
        }
        let tokens = blacklist.map(normalized).filter { !$0.isEmpty }
        let seeds = weights.keys.filter { tag in !tokens.contains { tag.contains($0) } }.sorted {
            weights[$0] == weights[$1] ? $0 < $1 : weights[$0, default: 0] > weights[$1, default: 0]
        }.prefix(8)
        guard !seeds.isEmpty else { return [] }
        var seen = favoriteKeys
        var candidates: [(comic: Comic, score: Double, order: Int)] = []
        var lastError: Error?
        var retrieved = 0, verified = 0
        // Independent seed searches can fail independently. Never swallow an
        // expired session or cancellation, and report failure if every seed fails.
        let searches = try await ConcurrentLoad.map(Array(seeds), onValue: { _, _, count in
            await progress(.step("检索收藏标签", count, seeds.count, from: 0.4, to: 0.55))
        }) { tag -> Result<[Comic], Error> in
            do { return .success(try await search(tag)) }
            catch is CancellationError { throw CancellationError() }
            catch JMError.authenticationExpired { throw JMError.authenticationExpired }
            catch { return .failure(error) }
        }
        var pages: [[Comic]] = []
        for result in searches {
            switch result {
            case .success(let comics): pages.append(comics)
            case .failure(let error): lastError = error
            }
        }
        if pages.isEmpty, let lastError { throw lastError }
        let uniqueCandidates = pages.flatMap { $0 }.filter { seen.insert(DownloadCatalog.key($0)).inserted }
        retrieved = uniqueCandidates.count
        var lastPublishedCount = 0
        var lastPublished = Date.distantPast
        let checked = try await ConcurrentLoad.map(uniqueCandidates, limit: detailConcurrency, onValue: { index, check, count in
            await progress(.step("核验推荐漫画", count, uniqueCandidates.count, from: 0.55))
            guard case .success(let full) = check, !blocked(full, blacklist: blacklist) else { return }
            let allTags = tags(full)
            let matched = allTags.filter { weights[$0] != nil }.sorted {
                weights[$0] == weights[$1] ? $0 < $1 : weights[$0, default: 0] > weights[$1, default: 0]
            }
            guard !matched.isEmpty else { return }
            let total = matched.reduce(0) { $0 + weights[$1, default: 0] }
            var item = full
            item.reason = "收藏标签匹配：" + matched.prefix(3).joined(separator: "、")
            candidates.append((item, Double(total) / sqrt(Double(max(1, allTags.count))), index))
            // Show the first valid item promptly, then batch updates so large JM
            // libraries do not reorder and rebuild all cards for every album.
            if lastPublishedCount == 0 || candidates.count - lastPublishedCount >= 8 || Date().timeIntervalSince(lastPublished) >= 0.3 {
                await results(candidates.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.map(\.comic))
                lastPublishedCount = candidates.count; lastPublished = Date()
            }
        }) { candidate -> Result<Comic, Error> in
            do { return .success(try await detail(candidate)) }
            catch is CancellationError { throw CancellationError() }
            catch JMError.authenticationExpired { throw JMError.authenticationExpired }
            catch { return .failure(error) }
        }
        for check in checked {
            switch check {
            case .success: verified += 1
            case .failure(let error): lastError = error; continue
            }
            try Task.checkCancellation()
        }
        if retrieved > 0, verified == 0, let lastError { throw lastError }
        // Relevance first; equal scores keep the requested server sort order.
        let ranked = candidates.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.map(\.comic)
        if lastPublishedCount != ranked.count { await results(ranked) }
        return ranked
    }
}
