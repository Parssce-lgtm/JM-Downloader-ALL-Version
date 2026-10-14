import SwiftUI
import UIKit
import Combine

enum SelectionMode { case none, download, hide }
enum LibraryTab: String, CaseIterable { case downloads = "下载任务", favorites = "漫画收藏", recommendations = "漫画推荐" }

struct ContentView: View {
    let store: AppStore
    @ObservedObject var navigation: AppNavigationState
    @State private var settings = false
    @State private var logHistory = false
    @State private var tab: LibraryTab = .favorites
    @State private var paging = LibraryPagingPosition()
    @State private var bottomInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageStates = Dictionary(uniqueKeysWithValues: LibraryTab.allCases.map { ($0, LibraryPageState()) })
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            let layout = AppLayout(width: geometry.size.width, height: geometry.size.height)
            VStack(spacing: 10) {
                header.padding(.horizontal, layout.sideInset)
                Picker("浏览类型", selection: $tab) {
                    ForEach(LibraryTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("libraryTabs").padding(.horizontal, layout.sideInset)
                NativeLibraryPager(selection: $tab, paging: paging, animated: !reduceMotion, pages: LibraryTab.allCases.map { item in
                    AnyView(LibraryModuleView(store: store, pageState: pageStates[item]!, tab: item, isActive: item == tab, bottomInset: bottomInset, onSettings: { settings = true })
                        .id(item).tint(store.preferences.accent).environment(\.appLayout, layout))
                })
            }.frame(maxWidth: layout.contentWidth).frame(maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .bottom).background(Color(uiColor: .systemGroupedBackground))
                .overlay(alignment: .bottom) {
                    SharedLibraryNotice(store: store, favorites: pageStates[.favorites]!, recommendations: pageStates[.recommendations]!, tab: tab, paging: paging, onLogs: { logHistory = true })
                        .padding(.horizontal, layout.noticeInset(bottomSafeArea: bottomInset))
                        .frame(maxWidth: layout.contentWidth)
                        .padding(.bottom, layout.noticeInset(bottomSafeArea: bottomInset))
                }
            }
            .navigationTitle("JM downloader").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { SettingsView(store: store) }
            .navigationDestination(isPresented: $logHistory) { LogHistoryView(store: store) }
            .onChangeCompat(of: store.account) { _, _ in resetPages() }
            .onChangeCompat(of: store.platform) { _, _ in resetPages() }
            .alert("提示", isPresented: Binding(get: { store.alert != nil && !settings }, set: { if !$0 && !settings { store.alert = nil } })) {
                Button("好") { store.alert = nil }
            } message: { Text(store.alert ?? "") }
        }.scrollDismissesKeyboard(.interactively).background(KeyboardDismissInstaller())
            .background(WindowBottomInsetReader(inset: $bottomInset))
    }
    private func resetPages() {
        pageStates = Dictionary(uniqueKeysWithValues: LibraryTab.allCases.map { ($0, LibraryPageState()) })
    }
    private var header: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            Spacer(minLength: 0)
            Button("JM downloader") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                pageStates[tab]?.scrollToTopRequest += 1
            }.font(.headline).foregroundStyle(.primary).buttonStyle(.plain).accessibilityIdentifier("scrollToTop")
            Spacer(minLength: 0)
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 22))
                    .frame(width: 44, height: 44).modifier(HeaderActionStyle())
            }.buttonStyle(.plain).accessibilityLabel("设置").accessibilityIdentifier("settings")
        }.frame(minHeight: 48)
    }
}

// GeometryReader's safe area includes the keyboard. Floating notices need the
// window's home-indicator inset so they stay below the search controls.
private struct WindowBottomInsetReader: UIViewRepresentable {
    @Binding var inset: CGFloat
    final class HostView: UIView {
        var report: ((CGFloat) -> Void)?
        private var lastInset: CGFloat?
        override func didMoveToWindow() { super.didMoveToWindow(); updateInset() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); updateInset() }
        override func layoutSubviews() { super.layoutSubviews(); updateInset() }
        private func updateInset() {
            guard let window else { return }
            let value = window.safeAreaInsets.bottom
            guard lastInset != value else { return }
            lastInset = value
            DispatchQueue.main.async { [weak self] in self?.report?(value) }
        }
    }
    func makeUIView(context: Context) -> HostView {
        let view = HostView(); view.isUserInteractionEnabled = false
        view.report = { inset = $0 }
        return view
    }
    func updateUIView(_ view: HostView, context: Context) { view.report = { inset = $0 } }
}

@MainActor
private final class LibraryPageState: ObservableObject {
    @Published var folder: String = "全部收藏夹"
    @Published var query: String = ""
    @Published var submittedQuery: String = ""
    @Published var showSearch: Bool = false
    @Published var globalSearch: Bool = false
    @Published var favoriteVisibility: FavoriteVisibility = .regular
    @Published var showDownloadedRecommendations: Bool = false
    @Published var mode: SelectionMode = .none
    @Published var selected: Set<String> = []
    @Published var deleteAnchor: String? = nil
    @Published var deleteIDs: Set<String> = []
    @Published var scrollToTopRequest = 0
}

private struct LibraryModuleView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var pageState: LibraryPageState
    let tab: LibraryTab
    let isActive: Bool
    let bottomInset: CGFloat
    let onSettings: () -> Void
    private var folder: String {
        get { pageState.folder }
        nonmutating set { pageState.folder = newValue }
    }
    private var query: String {
        get { pageState.query }
        nonmutating set { pageState.query = newValue }
    }
    private var submittedQuery: String {
        get { pageState.submittedQuery }
        nonmutating set { pageState.submittedQuery = newValue }
    }
    private var showSearch: Bool {
        get { pageState.showSearch }
        nonmutating set { pageState.showSearch = newValue }
    }
    private var globalSearch: Bool {
        get { pageState.globalSearch }
        nonmutating set { pageState.globalSearch = newValue }
    }
    private var showDownloadedFavorites: Bool {
        get { pageState.favoriteVisibility == .downloaded }
        nonmutating set { pageState.favoriteVisibility = newValue ? .downloaded : .regular }
    }
    private var showHiddenFavorites: Bool {
        get { pageState.favoriteVisibility == .hidden }
        nonmutating set { pageState.favoriteVisibility = newValue ? .hidden : .regular }
    }
    private var showDownloadedRecommendations: Bool {
        get { pageState.showDownloadedRecommendations }
        nonmutating set { pageState.showDownloadedRecommendations = newValue }
    }
    private var mode: SelectionMode {
        get { pageState.mode }
        nonmutating set { pageState.mode = newValue }
    }
    private var selected: Set<String> {
        get { pageState.selected }
        nonmutating set { pageState.selected = newValue }
    }
    private var deleteAnchor: String? {
        get { pageState.deleteAnchor }
        nonmutating set { pageState.deleteAnchor = newValue }
    }
    private var deleteIDs: Set<String> {
        get { pageState.deleteIDs }
        nonmutating set { pageState.deleteIDs = newValue }
    }
    @State private var previewComic: Comic?
    @State private var downloadAnchor: String?
    @State private var pendingDownloads: [Comic] = []
    @State private var pendingResume: UUID?
    @Environment(\.appLayout) private var layout
    @FocusState private var searchFocused: Bool

    private var searchScope: ComicSearchScope { tab == .favorites ? .favorites : .recommendations }
    private var searchState: ComicSearchState { store.searchState(searchScope) }
    private var source: [Comic] { globalSearch ? searchState.results : (tab == .favorites ? store.favorites : store.recommendations) }
    private var comics: [Comic] {
        let downloaded = store.downloadedComicKeys
        let excluded = Set(store.excluded.map(DownloadCatalog.key))
        return source.filter { comic in
            (globalSearch || tab != .recommendations || (!store.isBlocked(comic) && (!excluded.contains(DownloadCatalog.key(comic)) || store.isPendingDislike(comic))))
                && (tab == .favorites && !globalSearch
                    ? pageState.favoriteVisibility.includes(downloaded: downloaded.contains(DownloadCatalog.key(comic)), hidden: store.isHiddenFavorite(comic))
                    : ((tab == .favorites ? showDownloadedFavorites : showDownloadedRecommendations) || !downloaded.contains(DownloadCatalog.key(comic))))
                && (folder == "全部收藏夹" || comic.folders.contains(folder) || tab == .recommendations || globalSearch)
        }
    }
    private var selectionItems: [Comic] { tab == .downloads ? tasks.map(\.comic) : comics }
    private var catalog: [Comic] {
        var seen = Set<String>()
        return (source + store.visibleJobs.map(\.comic)).filter { seen.insert($0.id).inserted }
    }
    private var tasks: [DownloadJob] {
        store.visibleJobs.filter { query.isEmpty || globalSearch || $0.comic.title.localizedCaseInsensitiveContains(query) || $0.comic.id.contains(query) }
    }
    private var busy: Bool { store.signingIn || (globalSearch ? searchState.searching : (tab == .favorites ? store.refreshing : (store.recommending || store.refreshing))) }
    private var failed: Bool {
        !store.connected || (globalSearch ? searchState.failure != nil : (tab == .favorites ? store.favoriteFailure != nil : (store.recommendationFailure != nil || store.favoriteFailure != nil)))
    }
    private var failureKind: LibraryFailureKind {
        if !store.connected { return .load }
        return (globalSearch ? searchState.failureKind : (tab == .favorites ? store.favoriteFailureKind : (store.recommendationFailureKind ?? store.favoriteFailureKind))) ?? .load
    }

    var body: some View {
        VStack(spacing: 10) {
            if tab == .downloads { queueControls.padding(.horizontal, layout.sideInset) }
            else { toolsPane.padding(.horizontal, layout.sideInset) }
            if tab == .downloads { queuePane }
            else { libraryPane }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityHidden(!isActive)
            .sheet(item: $previewComic) { CoverPreview(comic: $0, preferences: store.preferences) }
            .onDisappear { dismissTransientControls() }
            .onChangeCompat(of: isActive) { _, active in if !active { dismissTransientControls() } }
            // Keep the submit button until keyboard dismissal completes. The
            // window's non-canceling tap gesture can remove focus before the
            // button receives its action; hiding on focus loss drops that tap.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                if isActive { showSearch = false; searchFocused = false }
            }
            .onChangeCompat(of: store.platform) { _, _ in resetPage() }
            .onChangeCompat(of: store.account) { _, _ in resetPage() }
    }
    private func resetPage() { showDownloadedFavorites = false; showDownloadedRecommendations = false; showHiddenFavorites = false; endSelection(); folder = "全部收藏夹"; exitSearch() }
    private func dismissTransientControls() { showSearch = false; searchFocused = false; endSelection() }
    private func refreshCurrentList() {
        if globalSearch { store.search(submittedQuery, scope: searchScope) }
        else if tab == .favorites { store.refreshFavorites() }
        else { store.loadRecommendations() }
    }
    private func exitSearch() {
        if globalSearch { store.cancelSearch(scope: searchScope) }
        globalSearch = false; showSearch = false; searchFocused = false; query = ""; submittedQuery = ""
    }
    private var toolsPane: some View {
        VStack(spacing: 8) {
            controls
            if showSearch {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("漫画名、#标签或标签A+标签B", text: $pageState.query).submitLabel(.search)
                        .focused($searchFocused).accessibilityIdentifier("comicSearchField")
                        .task { searchFocused = true }
                        .onSubmit { submitSearch() }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("清除搜索")
                    }
                    Button("搜索") { submitSearch() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("submitComicSearch")
                }.font(.subheadline).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
            if globalSearch {
                HStack {
                    Text("搜索：" + submittedQuery).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button(tab == .recommendations ? "返回推荐" : "返回收藏") { exitSearch() }
                        .buttonStyle(.plain).foregroundStyle(store.preferences.accent)
                        .fixedSize().contentShape(Rectangle())
                        .accessibilityIdentifier("exitComicSearch")
                }.font(.caption)
            }
            if mode != .none { selectionBar }
        }
    }
    private var libraryPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 9) {
                    Color.clear.frame(height: 0).id("libraryTop")
                    if comics.isEmpty {
                        emptyLibrary
                    }
                    ForEach(comics) { comic in comicRow(comic) }
                    if globalSearch && searchState.page > 0 {
                            Button("加载更多") { store.search(submittedQuery, page: searchState.page + 1, scope: searchScope) }.disabled(searchState.searching)
                    }
                }.padding(.bottom, 100 + bottomInset)
            }
            .accessibilityIdentifier("libraryScroll-" + tab.rawValue)
            .scrollIndicators(.hidden)
            .appHideBottomEdgeEffect()
            .onChangeCompat(of: pageState.scrollToTopRequest) { _, _ in
                withAnimation(.appTransition) { reader.scrollTo("libraryTop", anchor: .top) }
            }
            .refreshable {
                refreshCurrentList()
            }
            }
        }.padding(.horizontal, layout.sideInset).padding(.top, 8)
    }
    private var controls: some View {
        HStack(spacing: 18) {
            if tab == .recommendations {
                searchButton
            } else {
                searchButton
                Menu {
                    Button("全部收藏夹") { exitSearch(); folder = "全部收藏夹" }
                    ForEach(Array(Set(store.favorites.flatMap(\.folders))).sorted(), id: \.self) { item in
                        Button(item) { exitSearch(); folder = item }
                    }
                } label: { Label(folder == "全部收藏夹" ? "收藏夹" : folder, systemImage: "folder").lineLimit(1) }
            }
            Spacer(minLength: 0)
            Menu {
                AppButton("选择漫画", systemImage: "checkmark.circle") { beginSelection(.download) }
                if tab == .favorites {
                    AppButton(mode == .hide ? "关闭隐藏漫画" : "选择隐藏漫画", systemImage: mode == .hide ? "xmark.circle" : "eye.slash") {
                        if mode == .hide { endSelection() } else { beginSelection(.hide) }
                    }
                    Divider()
                    AppButton("刷新当前列表", systemImage: "arrow.clockwise") { refreshCurrentList() }
                    AppButton(showDownloadedFavorites ? "隐藏已下载" : "查看已下载", systemImage: "checkmark.circle") {
                        showDownloadedFavorites.toggle(); endSelection()
                    }
                    AppButton(showHiddenFavorites ? "收起隐藏漫画" : "查看隐藏漫画", systemImage: "eye") {
                        showHiddenFavorites.toggle(); endSelection()
                    }
                } else {
                    AppButton("刷新列表", systemImage: "arrow.clockwise") { refreshCurrentList() }
                    Divider()
                    AppButton(showDownloadedRecommendations ? "隐藏已下载" : "查看已下载", systemImage: "checkmark.circle") {
                        showDownloadedRecommendations.toggle(); endSelection()
                    }
                }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("libraryMore-" + tab.rawValue)
                .popover(isPresented: deletionBinding("more"), attachmentAnchor: .rect(.bounds)) { deletionContent }

        }.font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            .frame(minHeight: 36)
    }
    private var selectionBar: some View {
        HStack {
            Button(selected.count == selectionItems.count && !selectionItems.isEmpty ? "取消全选" : "全选") {
                if selected == Set(selectionItems.map(\.id)) { selected = [] } else { selected = Set(selectionItems.map(\.id)) }
            }
            Text("已选 \(selected.count)").foregroundStyle(.secondary)
            Spacer()
            Button(mode == .hide ? "隐藏漫画" : "下载") {
                let items = catalog.filter { selected.contains($0.id) }
                if mode == .hide { store.hideFavorites(items); endSelection() }
                else { requestDownload(items, anchor: "selection"); if downloadAnchor == nil { endSelection() } }
            }.disabled(selected.isEmpty)
            Button("取消") { endSelection() }
        }.font(.caption.weight(.medium))
            .popover(isPresented: deletionBinding("selection"), attachmentAnchor: .rect(.bounds)) { cardActionContent }
    }
    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            LibraryStatusIcon(state: busy ? (tab == .favorites && !globalSearch ? .loading : .searching) : (failed ? (failureKind == .network ? .disconnected : .failed) : .empty), accent: store.preferences.accent)
            Text(busy ? (tab == .favorites && !globalSearch ? "正在加载" : "正在搜索…") : (failed ? (failureKind == .network ? "网络已断开" : "加载失败") : "这里还没有漫画")).font(.headline)
                .accessibilityIdentifier(busy ? "librarySearching" : (failed ? (failureKind == .network ? "libraryDisconnected" : "libraryFailed") : "libraryEmpty"))
            if !busy && failed && !store.connected {
                Button("前往账号设置") { onSettings() }.buttonStyle(.bordered)
            } else if !busy && !failed {
                Text(globalSearch ? "试试其他漫画名、编号或标签" : (tab == .recommendations && store.favorites.isEmpty ? "收藏漫画后，会根据收藏标签推荐" : "已下载漫画默认收起，可在更多中查看"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }
    private func comicRow(_ comic: Comic) -> some View {
        HStack(spacing: 10) {
            if mode != .none { checkmark(comic.id) }
            Button { if mode != .none { toggle(comic.id) } else { previewComic = comic } } label: {
                CoverView(comic: comic, preferences: store.preferences).frame(width: 48, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("预览封面 " + comic.title)
                .accessibilityIdentifier("cover-" + comic.id)
            VStack(alignment: .leading, spacing: 5) {
                Text(comic.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(comic.reason.isEmpty ? comic.reference : comic.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if mode == .none {
                if store.isDownloaded(comic) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                        .accessibilityLabel("已下载 \(comic.title)").accessibilityIdentifier("downloaded-" + comic.id)
                } else if store.jobs.contains(where: { $0.owner == store.account && $0.comic.source == comic.source && $0.comic.id == comic.id && $0.state.isRunning }) {
                    ProgressView().controlSize(.regular).frame(width: 28, height: 28)
                        .accessibilityLabel("正在下载 " + comic.title).accessibilityIdentifier("downloading-" + comic.id)
                } else {
                    Button { requestDownload([comic], anchor: "library:" + DownloadCatalog.key(comic)) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                        .accessibilityLabel("下载 \(comic.title)").disabled(store.scanningDownloads)
                }
            }
        }.padding(12).frame(minHeight: 92).modifier(ComicCardStyle())
            .opacity(tab == .recommendations && store.isPendingDislike(comic) ? 0.45 : 1)
            .accessibilityElement(children: .contain).accessibilityIdentifier("comicCard-" + comic.id)
            .accessibilityValue(tab == .recommendations && store.isPendingDislike(comic) ? "已标记不喜欢，刷新后隐藏" : "")
            .contentShape(Rectangle()).appTapAtLocation { location in
                if mode != .none { toggle(comic.id) }
                else if location.x <= layout.cardWidth * 0.8 { previewComic = comic }
            }
            .contextMenu { comicMenu(comic, anchor: "library:" + DownloadCatalog.key(comic)) }
            .popover(isPresented: deletionBinding("library:" + DownloadCatalog.key(comic)), attachmentAnchor: .rect(.bounds)) { cardActionContent }
    }
    private var queueControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("漫画下载状态", systemImage: "arrow.down.to.line.compact").font(.headline)
                Spacer()
                Text("\(tasks.count) 个任务").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                AppButton("全部开始", systemImage: "play.fill") { store.startAll() }.accessibilityIdentifier("startAll")
                Spacer()
                AppButton("全部暂停", systemImage: "pause.fill") { store.pauseAll() }.accessibilityIdentifier("pauseAll")
                Menu {
                    Button("选择任务") { beginSelection(.download) }
                    Button("删除任务及下载缓存", role: .destructive) {
                        if mode == .none { beginSelection(.download) }
                        else if !selected.isEmpty { deleteIDs = selected; deleteAnchor = "queue" }
                    }.disabled(mode != .none && selected.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("任务操作")
                .popover(isPresented: deletionBinding("queue"), attachmentAnchor: .rect(.bounds)) { cardActionContent }
            }.font(.subheadline.weight(.medium))
            if mode != .none { selectionBar }
        }.padding(.vertical, 6)
    }
    private var queuePane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Color.clear.frame(height: 0).id("queueTop")
                    if tasks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.tertiary)
                            Text("下载队列空空的").font(.subheadline.weight(.medium))
                            Text("选一本漫画开始，进度会显示在这里").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(tasks) { job in jobRow(job) }
                }.padding(.horizontal, layout.sideInset).padding(.bottom, 100 + bottomInset)
            }.scrollIndicators(.hidden).appHideBottomEdgeEffect()
                .onChangeCompat(of: pageState.scrollToTopRequest) { _, _ in
                    withAnimation(.appTransition) { reader.scrollTo("queueTop", anchor: .top) }
                }
            }
        }
    }
    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(spacing: 10) {
            if mode != .none { checkmark(job.comic.id) }
            Button { if mode != .none { toggle(job.comic.id) } else { previewComic = job.comic } } label: {
                CoverView(comic: job.comic, preferences: store.preferences).frame(width: 48, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("预览封面 " + job.comic.title)
                .accessibilityIdentifier("cover-" + job.comic.id)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(job.comic.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if mode == .none { taskButton(job) }
                }
                JobProgressBar(value: job.displayProgress, reversed: job.state == .exporting, tint: job.state == .completed ? .green : store.preferences.accent)
                    .accessibilityIdentifier("jobProgress-" + job.comic.id)
                HStack {
                    Text(job.state.label).foregroundStyle(job.state == .failed ? .red : .secondary).accessibilityIdentifier("jobState-" + job.comic.id)
                    Spacer()
                    Text(job.progressLabel).accessibilityIdentifier("jobProgressLabel-" + job.comic.id)
                }.font(.caption2).monospacedDigit()
                if !job.message.isEmpty { Text(job.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.padding(12).frame(minHeight: 92).modifier(ComicCardStyle())
            .accessibilityElement(children: .contain).accessibilityIdentifier("jobCard-" + job.comic.id)
            .contentShape(Rectangle()).appTapAtLocation { location in
                if mode != .none { toggle(job.comic.id) }
                else if location.x <= layout.cardWidth * 0.8 { previewComic = job.comic }
            }
            .contextMenu {
                if job.state.isRunning { AppButton("暂停下载", systemImage: "pause") { store.engine.pause(job.id) } }
                comicMenu(job.comic, anchor: "job:" + job.id.uuidString)
                if let output = job.output { ShareLink(item: output) { Label("分享 PDF", systemImage: "square.and.arrow.up") } }
            }
            .popover(isPresented: deletionBinding("job:" + job.id.uuidString), attachmentAnchor: .rect(.bounds)) { cardActionContent }
    }
    @ViewBuilder private func taskButton(_ job: DownloadJob) -> some View {
        if job.state == .completed {
            if let output = job.output { ShareLink(item: output) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享 PDF") }
        } else if [.paused, .failed, .deleted].contains(job.state) {
            Button { requestDownload([job.comic], anchor: "job:" + job.id.uuidString, resume: job.id) } label: { Image(systemName: "play.circle.fill").font(.title3) }.accessibilityLabel("继续下载").accessibilityIdentifier("resume-" + job.comic.id)
        } else {
            Button { store.engine.pause(job.id) } label: { Image(systemName: "pause.circle").font(.title3) }.accessibilityLabel("暂停下载")
        }
    }
    @ViewBuilder private func comicMenu(_ comic: Comic, anchor: String) -> some View {
        if tab == .favorites {
            if store.isHiddenFavorite(comic) {
                AppButton("取消隐藏漫画", systemImage: "eye") { store.showFavorite(comic) }
            } else {
                AppButton("隐藏漫画", systemImage: "eye.slash") { store.hideFavorites([comic]) }
            }
        } else if tab == .recommendations {
            AppButton("不喜欢该漫画", systemImage: "hand.thumbsdown") { store.exclude([comic], disliked: true) }
        } else {
            if store.isAutomaticExcluded(comic) {
                AppButton("取消排除该漫画", systemImage: "arrow.triangle.2.circlepath") { store.restoreAutomatic(comic) }
            } else {
                AppButton("排除该漫画", systemImage: "hand.raised") { store.exclude([comic]) }
            }
            AppButton("删除任务及下载缓存", systemImage: "trash", role: .destructive) {
                deleteIDs = [comic.id]; deleteAnchor = anchor
            }
        }
    }
    private func deletionBinding(_ anchor: String) -> Binding<Bool> {
        Binding(get: { deleteAnchor == anchor || downloadAnchor == anchor }, set: {
            if !$0 {
                if deleteAnchor == anchor { deleteAnchor = nil }
                if downloadAnchor == anchor { downloadAnchor = nil; pendingDownloads = []; pendingResume = nil }
            }
        })
    }
    private func requestDownload(_ comics: [Comic], anchor: String, resume: UUID? = nil) {
        if comics.contains(where: { store.isAutomaticExcluded($0) }) {
            pendingDownloads = comics; pendingResume = resume; downloadAnchor = anchor
        } else if let resume { store.resumeJob(resume) }
        else { store.enqueue(comics) }
    }
    @ViewBuilder private var cardActionContent: some View {
        if downloadAnchor != nil {
            ComicConfirmationPopover(
                title: pendingDownloads.count == 1 ? "该漫画已被排除，是否下载？" : "包含已排除漫画，是否下载？",
                message: "", tint: store.preferences.accent,
                identifier: "confirmExcludedDownload", singleLine: true) {
                    if let id = pendingResume { store.resumeJob(id, confirmedExcluded: true) }
                    else { store.enqueue(pendingDownloads, confirmedExcluded: true) }
                    downloadAnchor = nil; pendingDownloads = []; pendingResume = nil; endSelection()
            }
        } else { deletionContent }
    }
    private var deletionContent: some View {
        ComicConfirmationPopover(
            title: deleteIDs.count == 1 ? "删除任务及缓存？PDF 会保留。" : "删除 \(deleteIDs.count) 个任务及缓存？PDF 会保留。",
            message: "", tint: .red, identifier: "confirmDelete",
            destructive: true, singleLine: true) {
                store.deleteJobs(comicIDs: deleteIDs); deleteAnchor = nil; endSelection()
        }
    }
    private func checkmark(_ id: String) -> some View {
        Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
            .font(.title2).foregroundStyle(selected.contains(id) ? store.preferences.accent : Color.secondary)
            .frame(width: 28).transition(.move(edge: .leading).combined(with: .opacity))
            .accessibilityLabel(selected.contains(id) ? "已选择" : "未选择")
    }
    private func toggle(_ id: String) { if !selected.insert(id).inserted { selected.remove(id) } }
    private var searchButton: some View {
        AppButton("搜索", systemImage: "magnifyingglass") {
            showSearch = true; searchFocused = true; endSelection()
        }.accessibilityIdentifier("openComicSearch")
    }
    private func submitSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        query = value; submittedQuery = value; globalSearch = true; searchFocused = false; showSearch = false
        store.search(value, scope: searchScope)
    }
    private func beginSelection(_ value: SelectionMode) { withAnimation(.appTransition) { mode = value; selected = [] } }
    private func endSelection() { withAnimation(.appTransition) { mode = .none; selected = [] } }
}

private struct ComicConfirmationPopover: View {
    let title: String
    let message: String
    let tint: Color
    let identifier: String
    var destructive = false
    var singleLine = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .lineLimit(singleLine ? 1 : nil)
                    .minimumScaleFactor(singleLine ? 0.75 : 1)
                if !message.isEmpty { Text(message) }
            }.font(.body).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: destructive ? .destructive : nil, action: action) {
                Text("确认").font(.body.weight(.medium)).foregroundStyle(tint)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.primary.opacity(0.10), in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
        }.padding(20).frame(width: singleLine ? 300 : 260).appCompactConfirmation()
    }
}

private struct LibraryStatusIcon: View {
    enum Status { case loading, searching, disconnected, failed, empty }
    let state: Status
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(accent.opacity(0.09))
            switch state {
            case .loading:
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .medium))
                    .appPulse(active: !reduceMotion)
            case .searching:
                Circle().stroke(accent.opacity(0.15), lineWidth: 2).padding(4)
                Circle().trim(from: 0.05, to: 0.32).stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).padding(4)
                    .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
                Image(systemName: "book.closed").font(.system(size: 23, weight: .medium)).offset(x: -3, y: -2)
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)).offset(x: 12, y: 12)
            case .disconnected:
                Image(systemName: "wifi.slash").font(.system(size: 27, weight: .medium)).offset(y: -5)
                Capsule().fill(accent.opacity(0.3)).frame(width: 24, height: 3).offset(y: 20)
            case .empty:
                RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 23, height: 29).rotationEffect(.degrees(-14)).offset(x: -9, y: -1)
                Image(systemName: "book.closed").font(.system(size: 28, weight: .medium)).offset(x: 5, y: 2)
            case .failed:
                Image(systemName: "doc.text").font(.system(size: 27, weight: .medium)).offset(x: -4, y: -3)
                Image(systemName: "xmark.circle.fill").font(.system(size: 17, weight: .semibold)).offset(x: 12, y: 13)
            }
        }.foregroundStyle(accent).frame(width: state == .searching ? 78 : 62, height: state == .searching ? 78 : 62).accessibilityHidden(true)
            .task(id: state == .searching && !reduceMotion) {
                rotating = false
                if state == .searching && !reduceMotion {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { rotating = true }
                }
            }
    }
}

private struct JobProgressBar: View {
    let value: Double
    let reversed: Bool
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: reversed ? .trailing : .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }.frame(height: 4).animation(.linear(duration: 0.2), value: value)
            .accessibilityLabel(reversed ? "PDF 合成进度，从右向左" : "图片下载进度")
            .accessibilityValue("\(Int(value * 100))%")
    }
}

private struct LogHistoryView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        List(store.logs) { entry in
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }.overlay { if store.logs.isEmpty { AppEmptyView("暂无提示", systemImage: "text.bubble") } }
            .navigationTitle("提示记录").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct HeaderActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !AppAppearance.forceTraditional {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else { traditional(content) }
        #else
        traditional(content)
        #endif
    }
    private func traditional(_ content: Content) -> some View {
        content.background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7).allowsHitTesting(false) }
    }
}

private struct ComicCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.7)
                .allowsHitTesting(false) }
    }
}

// The shell belongs to the root, not to any cached paging host. Only its
// message viewport follows the finger; each page keeps its own source of text.
@MainActor private struct SharedLibraryNotice: View {
    @ObservedObject var store: AppStore
    @ObservedObject var favorites: LibraryPageState
    @ObservedObject var recommendations: LibraryPageState
    let tab: LibraryTab
    let paging: LibraryPagingPosition
    let onLogs: () -> Void
    @State private var position: CGFloat = 1
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(LibraryTab.allCases, id: \.self) { page in
                        Text(message(for: page)).font(.caption).monospacedDigit()
                            .multilineTextAlignment(.center).lineLimit(2)
                            .padding(.horizontal, 52)
                            .frame(width: geometry.size.width, height: 66)
                    }
                }.offset(x: -position * geometry.size.width)
            }.clipped()
            HStack {
                Image(systemName: "text.bubble").font(.title3)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
                    .opacity(tab == .downloads ? 1 : 0)
            }.padding(.horizontal, 22)
        }.foregroundStyle(.primary).frame(maxWidth: .infinity).frame(height: 66)
            .contentShape(Capsule())
            .onTapGesture { if tab == .downloads { onLogs() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message(for: tab))
            .modifier(NoticeAccessibility(interactive: tab == .downloads, onLogs: onLogs))
            .modifier(NoticeCapsuleStyle(interactive: tab == .downloads, transparent: tab != .downloads))
            .accessibilityIdentifier("sharedNoticeCapsule")
            .onReceive(paging.positions) { position = $0 }
    }
    private func message(for page: LibraryTab) -> String {
        if page == .downloads { return store.logs.first?.text ?? "准备就绪 · 下载文件保存在文件 App" }
        let state = page == .favorites ? favorites : recommendations
        let search = store.searchState(page == .favorites ? .favorites : .recommendations)
        let progress = state.globalSearch ? search.load : (page == .favorites ? store.favoriteLoad : store.recommendationLoad)
        let failure = state.globalSearch ? search.failure : (page == .favorites ? store.favoriteFailure : (store.recommendationFailure ?? store.favoriteFailure))
        let kind = !store.connected ? LibraryFailureKind.load : (state.globalSearch ? search.failureKind : (page == .favorites ? store.favoriteFailureKind : (store.recommendationFailureKind ?? store.favoriteFailureKind))) ?? .load
        let busy = store.signingIn || (state.globalSearch ? search.searching : (page == .favorites ? store.refreshing : (store.recommending || store.refreshing)))
        return failure.map { (kind == .network ? "网络已断开 · " : "加载失败 · ") + $0 }
            ?? (busy ? progress.text : (progress.fraction == 1 ? progress.stage : "准备就绪"))
    }
}

private struct NoticeAccessibility: ViewModifier {
    let interactive: Bool
    let onLogs: () -> Void
    func body(content: Content) -> some View {
        if interactive {
            content.accessibilityAddTraits(.isButton).accessibilityAction { onLogs() }
        } else {
            content.accessibilityRemoveTraits(.isButton)
        }
    }
}

private struct NoticeCapsuleStyle: ViewModifier {
    var interactive = false
    var transparent = false
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !AppAppearance.forceTraditional {
            content.glassEffect(transparent ? .clear : .regular.interactive(interactive),
                in: Capsule())
                .contentShape(.accessibility, Rectangle())
        } else {
            traditional(content)
        }
        #else
        traditional(content)
        #endif
    }
    private func traditional(_ content: Content) -> some View {
        content.background(Color(uiColor: .secondarySystemGroupedBackground).opacity(transparent ? 0.85 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1).allowsHitTesting(false) }
    }
}

struct CoverPreview: View {
    let comic: Comic
    let preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(preferences.accent.opacity(0.12))
                        if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18)) }
                        else { ProgressView().controlSize(.large) }
                    }.frame(maxWidth: .infinity).frame(height: AppLayout(width: geometry.size.width, height: geometry.size.height).previewHeight)
                    Text(comic.title).font(.title2.bold())
                    Text(comic.reference).font(.subheadline).foregroundStyle(.secondary)
                    if !comic.tags.isEmpty { Text(comic.tags.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                    HStack { Label(comic.folders.joined(separator: "、"), systemImage: "folder"); Spacer(); Text(comic.reason).foregroundStyle(.secondary) }.font(.footnote)
                }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            }.navigationTitle("封面详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.task {
            do { image = UIImage(data: try await CoverCache.shared.load(comic: comic, preferences: preferences)) } catch { }
        }.tint(preferences.accent).preferredColorScheme(preferences.colorScheme)
    }
}

struct CoverView: View {
    let comic: Comic
    let preferences: Preferences
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [preferences.accent.opacity(0.2), preferences.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "book.closed.fill").foregroundStyle(preferences.accent.opacity(0.6)) }
        }.clipped().accessibilityHidden(true)
            .task(id: DownloadCatalog.key(comic)) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-fixture-v120") {
                    image = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 120)).image { context in
                        let color: UIColor = comic.id == "10001" ? .systemBlue : (comic.id == "10002" ? .systemOrange : .systemGreen)
                        color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 90, height: 120))
                    }
                    return
                }
                #endif
                do {
                    let data = try await CoverCache.shared.load(comic: comic, preferences: preferences)
                    try Task.checkCancellation()
                    image = UIImage(data: data)
                } catch { /* Cover failure does not block the queue. */ }
            }
    }
}
