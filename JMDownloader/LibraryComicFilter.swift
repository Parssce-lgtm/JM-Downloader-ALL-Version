import Foundation

struct LibraryComicFilter: Equatable {
    var comics: [Comic]
    var recommendations: Bool
    var isSearch = false
    var downloaded: Set<String> = []
    var excluded: Set<String> = []
    var pendingDislikes: Set<String> = []
    var hidden: Set<String> = []
    var tagBlacklist: [String] = []
    var titleBlacklist: [String] = []
    var visibility: FavoriteVisibility = .regular
    var showDownloaded = false
    var folder = "全部收藏夹"

    func apply() -> [Comic] {
        if isSearch { return comics }
        return comics.filter { comic in
            let key = DownloadCatalog.key(comic)
            if recommendations {
                guard !RecommendationRanking.blocked(comic, blacklist: tagBlacklist),
                      !titleBlacklist.contains(where: { RecommendationRanking.normalized(comic.title).contains($0) }),
                      !excluded.contains(key) || pendingDislikes.contains(key) else { return false }
                return showDownloaded || !downloaded.contains(key)
            }
            return visibility.includes(downloaded: downloaded.contains(key), hidden: hidden.contains(key))
                && (folder == "全部收藏夹" || comic.folders.contains(folder))
        }
    }
}

// Store progress can publish dozens of times a second. A list's membership only
// depends on these inputs, not on an individual downloaded page or PDF percent.
@MainActor final class LibraryComicFilterCache {
    private var previous: LibraryComicFilter?
    private var comics: [Comic] = []
    func value(for input: LibraryComicFilter) -> [Comic] {
        if previous != input {
            comics = input.apply()
            previous = input
        }
        return comics
    }
}
