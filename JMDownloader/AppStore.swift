import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    static let shared: AppStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture-v120") { return AppStore(inMemory: true) }
        #endif
        return AppStore()
    }()
    @Published var preferences = Preferences()
    @Published var jobs: [DownloadJob] = []
    @Published var libraries: [String: Library] = [:]
    @Published var account = "" { didSet { if oldValue != account { pendingDislikedComics = [] } } }
    @Published var accounts: [String] = []
    @Published var recommendations: [Comic] = []
    // Keep feedback in the current feed until the next recommendation refresh.
    @Published var pendingDislikedComics: [Comic] = []
    private var recommendationID = UUID()
    var recommendationSort: RecommendationSort { preferences.recommendationOrder ?? .likes }
    private static func blacklistTokens(_ value: String?) -> [String] {
        (value ?? "").replacingOccurrences(of: "，", with: ",").split { $0 == "," || $0.isNewline }
            .map { RecommendationRanking.normalized(String($0)) }.filter { !$0.isEmpty }
    }
    var tagBlacklist: [String] {
        Self.blacklistTokens(preferences.tagBlacklist)
    }
    var titleBlacklist: [String] { Self.blacklistTokens(preferences.titleBlacklist) }
    func isBlocked(_ comic: Comic) -> Bool {
        RecommendationRanking.blocked(comic, blacklist: tagBlacklist)
            || titleBlacklist.contains { RecommendationRanking.normalized(comic.title).contains($0) }
    }
    var searchResults: [Comic] {
        get { searchState().results }
        set { searches[.general, default: ComicSearchState()].results = newValue }
    }
    @Published var logs: [LogEntry] = []
    @Published var signingIn = false
    @Published var refreshing = false
    @Published var recommending = false
    var searching: Bool {
        get { searchState().searching }
        set { searches[.general, default: ComicSearchState()].searching = newValue }
    }
    @Published var favoriteLoad = LibraryLoadProgress(stage: "准备加载")
    @Published var recommendationLoad = LibraryLoadProgress(stage: "准备加载")
    var searchLoad: LibraryLoadProgress {
        get { searchState().load }
        set { searches[.general, default: ComicSearchState()].load = newValue }
    }
    @Published var favoriteFailure: String?
    @Published var recommendationFailure: String?
    var searchFailure: String? {
        get { searchState().failure }
        set { searches[.general, default: ComicSearchState()].failure = newValue }
    }
    @Published var favoriteFailureKind: LibraryFailureKind?
    @Published var recommendationFailureKind: LibraryFailureKind?
    var searchFailureKind: LibraryFailureKind? {
        get { searchState().failureKind }
        set { searches[.general, default: ComicSearchState()].failureKind = newValue }
    }
    @Published var alert: String?
    @Published var clients: [String: any ComicAPI] = [:]
    var platform: ComicPlatform { preferences.selectedPlatform ?? .jmcomic }
    var displayAccount: String { ComicPlatform.username(account) }
    let engine = DownloadEngine()
    let background = BackgroundWork()
    @Published var downloadedFiles = Set<String>()
    @Published var scanningDownloads = false
    @Published var scanNotice = ""
    @Published var coverCacheRevision = 0
    @Published var coverCacheBytes: Int64 = 0
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var renewals: [String: Task<any ComicAPI, Error>] = [:]
    private var generation = UUID()
    private var activeAccounts: [ComicPlatform: String] = [:]
    private var recommendationTask: Task<Void, Never>?
    @Published private var searches: [ComicSearchScope: ComicSearchState] = [:]
    private var searchIDs: [ComicSearchScope: UUID] = [:]
    private var searchTasks: [ComicSearchScope: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var didStart = false
    private var savedAccount = ""
    private var persistenceHealthy = true
    private let persistence: SnapshotPersistence
    private var progressSaveTask: Task<Void, Never>?
    private var progressRevision = UUID()
    private var lastPersistenceError: String?
    private let inMemoryCaching: Bool
    private var tagCaches: [String: ComicTagCache] = [:]
    private var lastRecommendationProgress = Date.distantPast
    private func tagCache(for owner: String) -> ComicTagCache {
        if let cache = tagCaches[owner] { return cache }
        let cache = inMemoryCaching ? ComicTagCache() : ComicTagCache.persistent(account: owner)
        tagCaches[owner] = cache
        return cache
    }
    var favorites: [Comic] { libraries[account]?.favorites ?? [] }
    var excluded: [Comic] { libraries[account]?.excluded ?? [] }
    var hiddenComics: [Comic] {
        let keys = libraries[account]?.hiddenComicKeys ?? []
        var seen = Set<String>()
        var comics = (favorites + (libraries[account]?.hiddenComics ?? []) + excluded + jobs.filter { $0.owner == account }.map(\.comic))
            .filter { keys.contains(DownloadCatalog.key($0)) && seen.insert(DownloadCatalog.key($0)).inserted }
        // Older snapshots may retain a hidden key after the server removed its favorite.
        for key in keys.sorted() where !seen.contains(key) {
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let platform = ComicPlatform(rawValue: String(parts[0])) {
                comics.append(Comic(id: String(parts[1]), title: "已隐藏的漫画", platform: platform))
            }
        }
        return comics
    }
    var restrictedComics: [Comic] {
        var seen = Set<String>()
        return (excluded + hiddenComics).filter { seen.insert(DownloadCatalog.key($0)).inserted }
    }
    func isDisliked(_ comic: Comic) -> Bool {
        libraries[account]?.dislikedComicKeys?.contains(DownloadCatalog.key(comic)) == true
    }
    func isPendingDislike(_ comic: Comic) -> Bool {
        pendingDislikedComics.contains { DownloadCatalog.key($0) == DownloadCatalog.key(comic) }
    }
    private func visibleRecommendations(_ comics: [Comic]) -> [Comic] {
        var seen = Set<String>()
        return (comics + pendingDislikedComics).filter {
            !isBlocked($0) && (!isAutomaticExcluded($0) || isPendingDislike($0)) && seen.insert(DownloadCatalog.key($0)).inserted
        }
    }
    func isHiddenFavorite(_ comic: Comic) -> Bool {
        libraries[account]?.hiddenComicKeys?.contains(DownloadCatalog.key(comic)) == true
    }
    func hideFavorites(_ comics: [Comic]) {
        guard !account.isEmpty else { return }
        var keys = libraries[account]?.hiddenComicKeys ?? []
        keys.formUnion(comics.map(DownloadCatalog.key))
        libraries[account, default: Library()].hiddenComicKeys = keys
        var saved = libraries[account]?.hiddenComics ?? []
        for comic in comics { saved.removeAll { DownloadCatalog.key($0) == DownloadCatalog.key(comic) }; saved.append(comic) }
        libraries[account]?.hiddenComics = saved
        persist(); log("已隐藏漫画，可在收藏的更多菜单中查看并恢复")
    }
    func showFavorite(_ comic: Comic) {
        libraries[account]?.hiddenComicKeys?.remove(DownloadCatalog.key(comic))
        libraries[account]?.hiddenComics?.removeAll { DownloadCatalog.key($0) == DownloadCatalog.key(comic) }
        persist()
    }
    func isAutomaticExcluded(_ comic: Comic, owner: String? = nil) -> Bool {
        libraries[owner ?? account]?.excluded.contains { $0.id == comic.id && $0.source == comic.source } == true
    }
    var connected: Bool { clients[account] != nil }
    var visibleJobs: [DownloadJob] {
        jobs.filter { $0.comic.source == platform && (account.isEmpty || $0.owner == account) && (!preferences.hideCompleted || $0.state != .completed)
            && (!preferences.hideDeleted || $0.state != .deleted) }.sorted {
                $0.state.sortPriority == $1.state.sortPriority ? $0.created > $1.created : $0.state.sortPriority < $1.state.sortPriority
            }
    }
    init(inMemory: Bool = false, snapshotWriter: ((AppSnapshot) throws -> Void)? = nil) {
        inMemoryCaching = inMemory
        persistence = SnapshotPersistence(writer: snapshotWriter ?? (inMemory ? { _ in } : DiskStore.save))
        background.store = self
        if inMemory { engine.store = self; return }
        do {
            var data = try DiskStore.load()
            if data.preferences.restoreRootDirectoryDefault() { try DiskStore.save(data) }
            preferences = data.preferences; jobs = data.jobs; libraries = data.libraries; savedAccount = data.lastAccount
            preferences.recommendationOrder = .likes
        } catch { persistenceHealthy = false; alert = "本地记录无法读取，原始文件已保留。请先备份再处理。" }
        accounts = SecureStore.accounts()
        if preferences.remember {
            // Show the saved bookshelf immediately. Restore validated session hosts without a login round trip.
            if savedAccount.isEmpty { savedAccount = accounts.first(where: { ComicPlatform.ofAccount($0) == platform }) ?? "" }
            account = savedAccount
            if libraries[account]?.cachedRecommendationOrder == recommendationSort { recommendations = libraries[account]?.cachedRecommendations ?? [] }
            for key in accounts {
                if let saved = SessionVault.load(key), saved.platform == ComicPlatform.ofAccount(key), let api = try? Self.client(preferences, session: saved, tagCache: tagCache(for: key)) {
                    clients[key] = api; activeAccounts[ComicPlatform.ofAccount(key)] = key
                }
            }
        }
    }
    static func client(_ preferences: Preferences, session: ServiceSession, tagCache: ComicTagCache = ComicTagCache()) throws -> any ComicAPI {
        let hosts = try Validation.hosts(session.platform == .jmcomic ? preferences.effectiveJMDomains : preferences.effectivePicaDomain)
        guard hosts.contains(session.host), session.platform == .jmcomic ? !(session.cookies["AVS"] ?? "").isEmpty : !session.token.isEmpty else {
            throw JMError.authenticationExpired
        }
        return try session.platform == .jmcomic ? JMAPI(preferences: preferences, savedSession: session, tagCache: tagCache) : PicaAPI(preferences: preferences, savedSession: session, tagCache: tagCache)
    }
    func start() {
        guard !didStart else { return }; didStart = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture-v120") { loadUIFixture(); return }
        #endif
        scanDownloadDirectory()
        engine.connect(self)
        if connected { refreshFavorites(silently: true); loadRecommendations(silently: true); return }
        if preferences.remember, !savedAccount.isEmpty, let password = SecureStore.password(for: savedAccount) {
            preferences.selectedPlatform = ComicPlatform.ofAccount(savedAccount)
            let username = ComicPlatform.username(savedAccount)
            Task { await login(username: username, password: password, platform: ComicPlatform.ofAccount(savedAccount), silently: true) }
        }
    }
    func becameActive() {
        if !scanningDownloads { scanDownloadDirectory() }
        engine.resumeAutomatic(); engine.pump()
    }
    func isDownloaded(_ comic: Comic) -> Bool {
        downloadedFiles.contains(DownloadCatalog.key(comic)) || jobs.contains {
            $0.comic.source == comic.source && $0.comic.id == comic.id && ($0.state == .completed || $0.output != nil)
        }
    }
    var downloadedComicKeys: Set<String> {
        downloadedFiles.union(jobs.filter { $0.state == .completed || $0.output != nil }.map { DownloadCatalog.key($0.comic) })
    }
    func scanDownloadDirectory() {
        let stamp = UUID(); scanID = stamp
        scanningDownloads = true
        scanNotice = "正在扫描默认目录和所选目录…"
        let bookmark = preferences.directoryBookmark
        scanTask = Task {
            defer { if stamp == scanID { scanningDownloads = false } }
            do {
                let found = try await DownloadCatalog.scanAll(bookmark: bookmark)
                guard stamp == scanID else { return }
                downloadedFiles = found.keys
                scanNotice = "已识别 \(found.keys.count) 部已下载漫画" + (found.warning.map { "；" + $0 } ?? "")
            } catch { if stamp == scanID { scanNotice = "下载目录扫描未完成：" + Self.friendly(error); log(scanNotice) } }
        }
    }
    func resumeJob(_ id: UUID, confirmedExcluded: Bool = false) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if isAutomaticExcluded(job.comic, owner: job.owner) {
            guard confirmedExcluded else { return }
            change(id) { $0.exclusionApproved = true }
        }
        engine.resume(id, pumpAfter: false)
        background.beginUserWork(); engine.pump()
    }
    func startAll() {
        for job in jobs where job.comic.source == platform && (account.isEmpty || job.owner == account)
            && [.paused, .failed, .queued].contains(job.state)
            && !isAutomaticExcluded(job.comic, owner: job.owner) { engine.resume(job.id, pumpAfter: false) }
        background.beginUserWork(); engine.pump()
    }
    func pauseAll() {
        engine.pauseAll(ids: Set(jobs.filter { $0.comic.source == platform && (account.isEmpty || $0.owner == account) && ($0.state.isRunning || $0.resumeAutomatically == true) }.map(\.id)))
    }
    func updateCacheSize() async { coverCacheBytes = await CoverCache.shared.size() }
    func clearCoverCache() async {
        do {
            try await CoverCache.shared.clear()
            coverCacheRevision += 1; coverCacheBytes = 0
            log("封面缓存已清理，下载中的图片及已生成 PDF 保留。")
        } catch { report(error) }
    }
    func renewSession(_ owner: String) async throws -> any ComicAPI {
        if let renewal = renewals[owner] { return try await renewal.value }
        guard preferences.remember, let password = SecureStore.password(for: owner) else { throw JMError.authenticationExpired }
        let preferences = preferences, cache = tagCache(for: owner)
        let renewal = Task<any ComicAPI, Error> {
            let api: any ComicAPI = try ComicPlatform.ofAccount(owner) == .jmcomic ? JMAPI(preferences: preferences, tagCache: cache) : PicaAPI(preferences: preferences, tagCache: cache)
            try await api.login(username: ComicPlatform.username(owner), password: password)
            try Task.checkCancellation()
            if let saved = await api.savedSession() { try SessionVault.save(saved, account: owner) }
            return api
        }
        renewals[owner] = renewal
        defer { renewals[owner] = nil }
        let api = try await renewal.value
        guard clients[owner] != nil else { throw CancellationError() }
        clients[owner] = api
        return api
    }
    nonisolated static func friendly(_ error: Error) -> String {
        if let error = error as? JMTransportError { return error.localizedDescription }
        if let error = error as? LibraryLoadFailure { return error.localizedDescription }
        if let error = error as? RecommendationDetailUnavailable { return error.localizedDescription }
        if let error = error as? JMError { return error.localizedDescription }
        if let error = error as? ImageHTTPError { return error.localizedDescription }
        if let error = error as? URLError { return NetworkFailure.describe(error) }
        let underlying = error as NSError
        if underlying.domain == NSCocoaErrorDomain {
            if underlying.code == CocoaError.fileWriteOutOfSpace.rawValue { return "设备剩余空间不足，请释放空间后继续；已下载图片已保留。" }
            if underlying.code == CocoaError.fileWriteNoPermission.rawValue { return "无法写入文件，请检查目录授权后重试。" }
        }
        return "操作未完成，请检查网络、目录授权和剩余存储空间。"
    }
    @discardableResult func persist() -> Bool {
        progressSaveTask?.cancel(); progressSaveTask = nil; progressRevision = UUID()
        guard persistenceHealthy else { alert = "本地记录无法读取，暂未覆盖原始文件，请先备份后处理。"; return false }
        do {
            try persistence.save(AppSnapshot(preferences: preferences, libraries: libraries, jobs: jobs,
                                           lastAccount: preferences.remember ? account : ""))
            lastPersistenceError = nil
            return true
        } catch { alert = "无法保存记录，请检查剩余存储空间。"; return false }
    }
    func log(_ text: String) { logs.insert(LogEntry(text: text), at: 0); if logs.count > 150 { logs.removeLast() } }
    func report(_ error: Error) { let text = Self.friendly(error); log(text); alert = text }
    func change(_ id: UUID, _ update: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        update(&jobs[index]); scheduleProgressSave(); background.refresh()
    }
    private func scheduleProgressSave() {
        // A fixed window (not a resetting debounce) still checkpoints continuous downloads.
        guard progressSaveTask == nil else { return }
        let revision = UUID(); progressRevision = revision
        progressSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled, self.progressRevision == revision else { return }
            self.progressSaveTask = nil
            _ = await self.saveProgress(revision: revision)
        }
    }
    @discardableResult func flushProgress() async -> Bool {
        progressSaveTask?.cancel(); progressSaveTask = nil
        let revision = UUID(); progressRevision = revision
        return await saveProgress(revision: revision)
    }
    private func saveProgress(revision: UUID) async -> Bool {
        guard persistenceHealthy else { return false }
        let snapshot = AppSnapshot(preferences: preferences, libraries: libraries, jobs: jobs,
                                   lastAccount: preferences.remember ? account : "")
        do {
            try await persistence.saveInBackground(snapshot)
            if progressRevision == revision { lastPersistenceError = nil }
            return true
        } catch {
            guard progressRevision == revision else { return false }
            let message = "下载进度暂未保存，请检查剩余存储空间；已下载图片缓存会保留。"
            // Download callbacks must never repeatedly present a blocking modal.
            if lastPersistenceError != message { lastPersistenceError = message; log(message) }
            return false
        }
    }
    func login(username: String, password: String, platform requestedPlatform: ComicPlatform? = nil, silently: Bool = false) async {
        let target = requestedPlatform ?? platform
        guard target == platform else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { alert = "请输入账号和密码。"; return }
        guard !signingIn else { return }; signingIn = true
        defer { signingIn = false }
        do {
            let key = target.accountKey(username)
            let api: any ComicAPI
            if target == .jmcomic { api = try JMAPI(preferences: preferences, tagCache: tagCache(for: key)) }
            else { api = try PicaAPI(preferences: preferences, tagCache: tagCache(for: key)) }
            try await api.login(username: username, password: password)
            generation = UUID()
            refreshTask?.cancel(); recommendationTask?.cancel(); cancelAllSearches()
            refreshing = false; recommending = false; searching = false
            favoriteFailure = nil; recommendationFailure = nil; searchFailure = nil
        favoriteFailureKind = nil; recommendationFailureKind = nil; searchFailureKind = nil
        favoriteLoad = .init(stage: "准备加载"); recommendationLoad = .init(stage: "准备加载"); searchLoad = .init(stage: "准备搜索")
            clients[key] = api; activeAccounts[target] = key; account = key
            recommendations = []; searchResults = []
            if libraries[key] == nil { libraries[key] = Library() }
            if preferences.remember {
                try SecureStore.save(username: key, password: password)
                if let saved = await api.savedSession() { try SessionVault.save(saved, account: key) }
                for old in SecureStore.accounts() where old != key && ComicPlatform.ofAccount(old) == target { SecureStore.remove(old) }
            }
            else { SecureStore.remove(key); SessionVault.remove(key) }
            accounts = SecureStore.accounts()
            persist(); log("已登录 \(target.label)：\(username)")
            engine.pump(); refreshFavorites(silently: silently)
            loadRecommendations(silently: true)
        } catch { if silently { log(Self.friendly(error)) } else { report(error) } }
    }
    func switchPlatform(_ value: ComicPlatform) {
        guard !signingIn, value != platform else { return }
        generation = UUID()
        refreshTask?.cancel(); recommendationTask?.cancel(); cancelAllSearches()
        refreshing = false; recommending = false; searching = false
        favoriteFailure = nil; recommendationFailure = nil; searchFailure = nil
        favoriteFailureKind = nil; recommendationFailureKind = nil; searchFailureKind = nil
        favoriteLoad = .init(stage: "准备加载"); recommendationLoad = .init(stage: "准备加载"); searchLoad = .init(stage: "准备搜索")
        recommendations = []; searchResults = []
        preferences.selectedPlatform = value
        account = activeAccounts[value] ?? ""
        persist()
        if connected { refreshFavorites(silently: true); loadRecommendations(silently: true); return }
        if preferences.remember, let key = accounts.first(where: { ComicPlatform.ofAccount($0) == value }),
           let password = SecureStore.password(for: key) {
            Task { await login(username: ComicPlatform.username(key), password: password, platform: value) }
        }
    }
    func logout() {
        generation = UUID()
        refreshTask?.cancel(); recommendationTask?.cancel(); cancelAllSearches()
        for job in jobs where job.owner == account && [.queued, .preparing, .downloading, .exporting].contains(job.state) { engine.pause(job.id) }
        renewals[account]?.cancel(); renewals[account] = nil; SessionVault.remove(account)
        clients[account] = nil; activeAccounts[platform] = nil; account = ""; recommendations = []; searchResults = []
        refreshing = false; recommending = false; searching = false
        favoriteFailure = nil; recommendationFailure = nil; searchFailure = nil
        favoriteFailureKind = nil; recommendationFailureKind = nil; searchFailureKind = nil
        favoriteLoad = .init(stage: "准备加载"); recommendationLoad = .init(stage: "准备加载"); searchLoad = .init(stage: "准备搜索")
        persist()
    }
    func refreshFavorites(silently: Bool = false) {
        guard !refreshing, let api = clients[account] else { if !connected { alert = "请先在账号设置中登录。" }; return }
        // Invalidate a ranking already using old favorites. Its replacement waits
        // for this refresh, and reads the possibly renewed client afterwards.
        recommendationTask?.cancel(); recommendationID = UUID(); recommending = false
        refreshing = true; favoriteFailure = nil; favoriteFailureKind = nil; favoriteLoad = .init(stage: "读取收藏分页")
        let owner = account, stamp = generation
        refreshTask = Task {
            defer { if stamp == generation { refreshing = false } }
            do {
                let comics: [Comic]
                let progress: LibraryProgressHandler = { [weak self] update in
                    await self?.updateFavoriteProgress(update, stamp: stamp)
                }
                do { comics = try await LibraryLoadDeadline.run(seconds: 180) { try await api.favorites(progress: progress) } }
                catch JMError.authenticationExpired {
                    let renewed = try await renewSession(owner)
                    comics = try await LibraryLoadDeadline.run(seconds: 180) { try await renewed.favorites(progress: progress) }
                }
                try Task.checkCancellation()
                guard stamp == generation else { return }
                libraries[owner, default: Library()].favorites = comics
                favoriteLoad = .init(stage: "收藏加载完成，共 \(comics.count) 部", fraction: 1)
                persist()
                if !recommending { loadRecommendations(silently: true) }
                if preferences.autoDownload {
                    await scanTask?.value
                    guard stamp == generation else { return }
                    enqueue(comics, automatic: true, userInitiated: !silently)
                }
            } catch is CancellationError { } catch { if stamp == generation {
                favoriteFailure = Self.friendly(error)
                favoriteFailureKind = .classify(error)
                if !silently { alert = favoriteFailure }
            } }
        }
    }
    func setRecommendationSort(_ sort: RecommendationSort) {
        guard sort != recommendationSort else { return }
        preferences.recommendationOrder = sort; persist()
        recommendations = []; loadRecommendations()
    }
    func loadRecommendations(silently: Bool = false) {
        guard connected else { recommendationFailure = "请先登录。"; recommendationFailureKind = .load; return }
        pendingDislikedComics = []
        recommendations.removeAll { isAutomaticExcluded($0) }
        if !refreshing, favoriteFailure != nil { refreshFavorites(silently: silently); return }
        if recommendations.isEmpty, libraries[account]?.cachedRecommendationOrder == recommendationSort {
            recommendations = libraries[account]?.cachedRecommendations ?? []
        }
        recommendationTask?.cancel()
        let requestID = UUID(); recommendationID = requestID
        let order = recommendationSort
        let preferredTags: [String] = []
        let blacklist = tagBlacklist
        recommending = true; recommendationFailure = nil; recommendationFailureKind = nil
        recommendationLoad = .init(stage: refreshing ? "等待收藏刷新" : "准备推荐")
        lastRecommendationProgress = .distantPast
        let stamp = generation, owner = account
        let pendingRefresh = refreshTask
        recommendationTask = Task {
            defer { if stamp == generation && requestID == recommendationID { recommending = false } }
            do {
                await pendingRefresh?.value
                try Task.checkCancellation()
                guard stamp == generation && requestID == recommendationID else { return }
                if let favoriteFailure { throw LibraryLoadFailure(kind: favoriteFailureKind ?? .load, message: favoriteFailure) }
                guard let api = clients[owner] else { throw JMError.authenticationExpired }
                let seed = favorites.filter { !isAutomaticExcluded($0) }
                let comics: [Comic]
                let progress: LibraryProgressHandler = { [weak self] update in
                    await self?.updateRecommendationProgress(update, stamp: stamp, requestID: requestID)
                }
                let results: LibraryResultsHandler = { [weak self] items in
                    await self?.showRecommendationResults(items, stamp: stamp, requestID: requestID)
                }
                do { comics = try await LibraryLoadDeadline.run(seconds: 180) {
                    try await api.recommendations(from: seed, sort: order, preferredTags: preferredTags, blacklist: blacklist, progress: progress, results: results)
                } }
                catch JMError.authenticationExpired {
                    let renewed = try await renewSession(owner)
                    comics = try await LibraryLoadDeadline.run(seconds: 180) {
                        try await renewed.recommendations(from: seed, sort: order, preferredTags: preferredTags, blacklist: blacklist, progress: progress, results: results)
                    }
                }
                try Task.checkCancellation()
                if comics.isEmpty && !seed.isEmpty { throw LibraryLoadFailure(kind: .load, message: "暂未加载出符合收藏标签的推荐漫画。") }
                if stamp == generation && requestID == recommendationID {
                    let visible = visibleRecommendations(comics)
                    recommendationLoad = .init(stage: "推荐加载完成，共 \(visible.count) 部", fraction: 1)
                    recommendations = visible; libraries[owner]?.cachedRecommendations = comics; libraries[owner]?.cachedRecommendationOrder = order; persist()
                }
            } catch is CancellationError { } catch { if stamp == generation && requestID == recommendationID {
                recommendationFailure = recommendationLoad.stage + "：" + Self.friendly(error)
                recommendationFailureKind = .classify(error)
            } }
        }
    }
    func searchState(_ scope: ComicSearchScope = .general) -> ComicSearchState { searches[scope] ?? ComicSearchState() }
    func search(_ value: String, page: Int = 1, scope: ComicSearchScope = .general) {
        let query = ComicSearchQuery(value)
        let previous = searchState(scope)
        // A failed page is retried rather than silently skipped; another query cannot append here.
        guard page == 1 || (previous.query == query && page == previous.page + 1) else { return }
        searchTasks[scope]?.cancel()
        let requestID = UUID(); searchIDs[scope] = requestID
        var state = previous.query == query ? previous : ComicSearchState()
        state.query = query; state.searching = true; state.failure = nil; state.failureKind = nil
        state.load = .init(stage: "正在搜索")
        searches[scope] = state
        guard let api = clients[account] else {
            searches[scope]?.searching = false; searches[scope]?.failure = "请先登录。"; searches[scope]?.failureKind = .load
            return
        }
        let stamp = generation, owner = account
        searchTasks[scope] = Task {
            defer { if stamp == generation && requestID == searchIDs[scope] {
                searches[scope]?.searching = false; searchTasks[scope] = nil
            } }
            do {
                let comics: [Comic]
                do { comics = try await LibraryLoadDeadline.run(seconds: 60) { try await query.results(using: api, page: page) } }
                catch JMError.authenticationExpired {
                    let renewed = try await renewSession(owner)
                    comics = try await LibraryLoadDeadline.run(seconds: 60) { try await query.results(using: renewed, page: page) }
                }
                try Task.checkCancellation()
                guard stamp == generation && requestID == searchIDs[scope] else { return }
                var current = searchState(scope)
                var seen = Set((page == 1 ? [] : current.results).map(DownloadCatalog.key))
                let unique = comics.filter { seen.insert(DownloadCatalog.key($0)).inserted }
                current.results = page == 1 ? unique : current.results + unique
                current.page = page
                current.load = .init(stage: "搜索完成，共 \(current.results.count) 部", fraction: 1)
                searches[scope] = current
            } catch is CancellationError { } catch { if stamp == generation && requestID == searchIDs[scope] {
                searches[scope]?.failure = Self.friendly(error); searches[scope]?.failureKind = .classify(error)
            } }
        }
    }
    func cancelSearch(scope: ComicSearchScope = .general) {
        searchIDs[scope] = UUID(); searchTasks[scope]?.cancel(); searchTasks[scope] = nil
        searches[scope] = nil
    }
    private func cancelAllSearches() {
        for task in searchTasks.values { task.cancel() }
        searchTasks = [:]; searchIDs = [:]; searches = [:]
    }
    private func updateFavoriteProgress(_ update: LibraryLoadProgress, stamp: UUID) {
        guard stamp == generation && refreshing else { return }
        favoriteLoad = update
    }
    private func updateRecommendationProgress(_ update: LibraryLoadProgress, stamp: UUID, requestID: UUID) {
        guard stamp == generation && requestID == recommendationID && recommending else { return }
        if update.stage != recommendationLoad.stage || update.completed == update.total || Date().timeIntervalSince(lastRecommendationProgress) >= 0.15 {
            recommendationLoad = update; lastRecommendationProgress = Date()
        }
    }
    private func showRecommendationResults(_ comics: [Comic], stamp: UUID, requestID: UUID) {
        guard stamp == generation && requestID == recommendationID && recommending else { return }
        recommendations = visibleRecommendations(comics)
    }
    func enqueue(_ comics: [Comic], automatic: Bool = false, userInitiated: Bool = true, confirmedExcluded: Bool = false) {
        guard connected else { alert = "请先登录。"; return }
        guard !scanningDownloads else { if !automatic { log("正在扫描下载目录，请稍后再开始下载。") }; return }
        var added = 0
        for comic in comics {
            if isDownloaded(comic) { continue }
            let excluded = isAutomaticExcluded(comic)
            if excluded && (automatic || !confirmedExcluded) { continue }
            if let existing = jobs.first(where: { $0.owner == account && $0.comic.id == comic.id }) {
                if !automatic && [.failed, .paused, .deleted].contains(existing.state) {
                    if excluded { change(existing.id) { $0.exclusionApproved = true } }
                    engine.resume(existing.id, pumpAfter: false)
                }
                continue
            }
            jobs.append(DownloadJob(owner: account, comic: comic, exclusionApproved: excluded ? true : nil)); added += 1
        }
        persist(); if added > 0 { log("已加入 \(added) 个下载任务") }
        if userInitiated { background.beginUserWork() }
        engine.pump()
    }
    func exclude(_ comics: [Comic], disliked: Bool = false) {
        guard !account.isEmpty else { return }
        var list = excluded
        for comic in comics {
            if !list.contains(where: { $0.id == comic.id }) { list.append(comic) }
        }
        libraries[account, default: Library()].excluded = list
        let keys = Set(comics.map(DownloadCatalog.key))
        if disliked {
            let dislikedKeys = (libraries[account]?.dislikedComicKeys ?? []).union(keys)
            libraries[account]?.dislikedComicKeys = dislikedKeys
            for comic in comics where !isPendingDislike(comic) { pendingDislikedComics.append(comic) }
        }
        for job in jobs where job.owner == account && keys.contains(DownloadCatalog.key(job.comic)) {
            change(job.id) { $0.exclusionApproved = nil }
            if job.state.isRunning { engine.pause(job.id, pumpAfter: false) }
        }
        if !disliked { recommendations.removeAll { keys.contains(DownloadCatalog.key($0)) } }
        persist(); engine.pump(); log("已加入已排除的漫画")
    }
    func restoreAutomatic(_ comic: Comic) {
        libraries[account]?.excluded.removeAll { DownloadCatalog.key($0) == DownloadCatalog.key(comic) }
        libraries[account]?.dislikedComicKeys?.remove(DownloadCatalog.key(comic))
        pendingDislikedComics.removeAll { DownloadCatalog.key($0) == DownloadCatalog.key(comic) }
        persist()
    }
    func removeRestrictions(_ comic: Comic) {
        showFavorite(comic); restoreAutomatic(comic)
    }
    func deleteJobs(comicIDs: Set<String>) {
        var failures = 0
        for job in jobs where job.owner == account && job.comic.source == platform && comicIDs.contains(job.comic.id) {
            engine.pause(job.id, state: .deleted, pumpAfter: false)
            do {
                let cache = DiskStore.cache(job.id)
                if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
                change(job.id) { $0.pages = []; $0.finished = []; $0.renderedPages = nil; $0.skippedPages = nil; $0.message = "" }
            } catch { failures += 1; report(error) }
        }
        engine.pump()
        log(failures == 0 ? "已删除任务及下载缓存，已保存的 PDF 保留" : "任务已删除，部分下载缓存清理失败，请重试")
    }
    @discardableResult func savePreferences(_ candidate: Preferences) -> Bool {
        do {
            var value = candidate
            value.domains = try Validation.hosts(candidate.effectiveJMDomains).joined(separator: ",")
            value.imageDomain = try Validation.hosts(candidate.effectiveImageDomain)[0]
            value.picaDomain = try Validation.hosts(candidate.effectivePicaDomain)[0]
            value.proxyHost = value.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            try NetworkConfiguration.apply(value, to: URLSessionConfiguration.ephemeral)
            let networkChanged = preferences.effectiveJMDomains != value.effectiveJMDomains
                || preferences.effectiveImageDomain != value.effectiveImageDomain || preferences.effectivePicaDomain != value.effectivePicaDomain
                || preferences.proxyHost != value.proxyHost || preferences.proxyPort != value.proxyPort
            guard persistenceHealthy else { throw JMError.message("本地记录无法读取，设置尚未保存。请先备份原始记录。") }
            // Commit to disk before reporting success or modifying the live settings.
            do {
                progressSaveTask?.cancel(); progressSaveTask = nil; progressRevision = UUID()
                try persistence.save(AppSnapshot(preferences: value, libraries: libraries, jobs: jobs,
                                               lastAccount: value.remember ? account : ""))
            } catch { throw JMError.message("设置未保存：无法写入设备存储，请检查剩余空间后重试。") }
            let directoryChanged = preferences.directoryBookmark != value.directoryBookmark
            preferences = value
            if directoryChanged { scanDownloadDirectory() }
            if !value.remember {
                renewals.values.forEach { $0.cancel() }; renewals.removeAll()
                for name in SecureStore.accounts() { SecureStore.remove(name); SessionVault.remove(name) }; accounts = []
            }
            alert = nil
            if networkChanged { log("线路设置已保存；请重新登录。后台图片代理将在下次启动时更新。") }
            return true
        } catch { report(error); return false }
    }
}

