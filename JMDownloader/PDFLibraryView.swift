import SwiftUI
import CoreGraphics
import PDFKit

struct DeveloperSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Form {
            Section {
                Toggle("预览", isOn: Binding(get: { store.preferences.previewEnabled == true }, set: { enabled in
                    var preferences = store.preferences
                    preferences.previewEnabled = enabled
                    store.savePreferences(preferences)
                })).accessibilityIdentifier("enablePDFPreview")
                Text("开启后，顶部最左侧显示 PDF 预览。将 PDF 漫画放入“文件 → 我的 iPhone → JM downloader”的根目录，无需新建文件夹。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("开发者功能")
    }
}

private enum PDFSort: String, CaseIterable {
    case time = "按时间排序", pages = "按页数排序", size = "按大小排序"
}

private enum LocalPDFLoader {
    static func identities() async -> [Comic] {
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: DiskStore.documents, includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { url -> Comic? in
                guard url.pathExtension.lowercased() == "pdf", let key = DownloadCatalog.key(filename: url.lastPathComponent) else { return nil }
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let platform = ComicPlatform(rawValue: parts[0]) else { return nil }
                return Comic(id: parts[1], title: url.deletingPathExtension().lastPathComponent, platform: platform)
            }
        }.value
    }
    static func scan(comics: [Comic]) async throws -> [LocalPDF] {
        try await Task.detached(priority: .userInitiated) {
            let files = try FileManager.default.contentsOfDirectory(at: DiskStore.documents,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey], options: [.skipsHiddenFiles])
            let known = Dictionary(comics.map { (DownloadCatalog.key($0), $0) }, uniquingKeysWith: { first, second in first.tags.count >= second.tags.count ? first : second })
            return files.compactMap { url -> LocalPDF? in
                guard url.pathExtension.lowercased() == "pdf",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let document = PDFDocument(url: url) else { return nil }
                let key = DownloadCatalog.key(filename: url.lastPathComponent)
                let comic = key.flatMap { known[$0] }
                let attributes = document.documentAttributes ?? [:]
                let keywords = (attributes[PDFDocumentAttribute.keywordsAttribute] as? [String])
                    ?? (attributes[PDFDocumentAttribute.keywordsAttribute] as? String)?.components(separatedBy: CharacterSet(charactersIn: ",;、\n")) ?? []
                let tags = Array(Set((comic?.tags ?? []) + keywords)).filter { !$0.isEmpty }
                return LocalPDF(url: url, title: comic?.title ?? (attributes[PDFDocumentAttribute.titleAttribute] as? String) ?? url.deletingPathExtension().lastPathComponent,
                    comicID: comic?.id ?? key?.components(separatedBy: ":").last ?? "",
                    platform: comic?.source ?? key.flatMap { ComicPlatform(rawValue: $0.components(separatedBy: ":")[0]) },
                    tags: tags,
                    pages: document.pageCount, bytes: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? values.creationDate ?? .distantPast)
            }
        }.value
    }

    static func image(url: URL, page: Int, width: Int) async throws -> CGImage {
        try await PDFPageLayout.image(url: url, page: page, width: width)
    }
}

private enum PDFLibrarySheet: Identifiable {
    case reader(LocalPDF), details(LocalPDF)
    var id: String { switch self { case .reader(let file): "reader:" + file.id; case .details(let file): "details:" + file.id } }
}

private struct PDFDeletionRequest {
    let file: LocalPDF
    let dislike: Bool
}

struct PDFLibraryView: View {
    // Files and reader state change through explicit reloads, not download ticks.
    let store: AppStore
    @ObservedObject private var library: LocalPDFLibraryState
    @Environment(\.appLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [LocalPDF] = []
    @State private var query = ""
    @State private var searchVisible = false
    @State private var sort: PDFSort = .time
    @State private var loading = false
    @State private var failure: String?
    @State private var sheet: PDFLibrarySheet?
    @State private var deletion: PDFDeletionRequest?
    @State private var busy = Set<String>()
    @State private var actionFailure: String?
    @FocusState private var searchFocused: Bool
    init(store: AppStore) { self.store = store; library = store.pdfLibrary }
    private var visible: [LocalPDF] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = files.filter { file in
            guard library.isVisible(file.id) else { return false }
            guard !text.isEmpty else { return true }
            if text.hasPrefix("#") || text.hasPrefix("＃") {
                let tag = ComicSearchQuery.normalizedTag(String(text.dropFirst()))
                return !tag.isEmpty && file.tags.contains { ComicSearchQuery.normalizedTag($0) == tag }
            }
            let normalized = ComicSearchQuery.normalizedTag(text)
            let number = normalized.hasPrefix("jm") ? String(normalized.dropFirst(2)).trimmingCharacters(in: .whitespaces) : normalized
            return ComicSearchQuery.normalizedTag(file.title).contains(normalized) || (!file.comicID.isEmpty && file.comicID == number)
        }
        return filtered.sorted { left, right in
            switch sort {
            case .time: if left.date != right.date { return left.date > right.date }
            case .pages: if left.pages != right.pages { return left.pages > right.pages }
            case .size: if left.bytes != right.bytes { return left.bytes > right.bytes }
            }
            return left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent) == .orderedAscending
        }
    }
    var body: some View {
        let displayed = visible
        return VStack(spacing: 10) {
            HStack {
                Button { searchVisible.toggle(); searchFocused = searchVisible } label: { Label("搜索", systemImage: "magnifyingglass") }
                Spacer()
                StableControl(key: sort) {
                    Menu {
                        Picker("排序", selection: $sort) { ForEach(PDFSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }
                }.equatable()
            }.padding(.horizontal, layout.sideInset)
            if searchVisible {
                TextField("漫画名、JM 号或 #标签", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .padding(.horizontal, layout.sideInset).accessibilityIdentifier("localPDFSearch")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if loading && files.isEmpty { ProgressView("正在读取 PDF…").padding(32) }
                    else if displayed.isEmpty {
                        AppEmptyView(failure ?? (query.isEmpty ? "这里还没有 PDF" : "没有匹配的 PDF"), systemImage: "doc.richtext",
                            description: Text(query.isEmpty ? "将 PDF 放入软件文件根目录，无需新建文件夹。" : "标签搜索必须以 # 开头；无标签元数据的 PDF 可按漫画名或 JM 号搜索。"))
                    }
                    ForEach(displayed) { file in
                        pdfRow(file)
                    }
                    Text("\(displayed.count) 个 PDF · 根目录").font(.caption).foregroundStyle(.secondary).padding(.vertical)
                }.padding(.horizontal, layout.sideInset).padding(.bottom, 48)
            }.scrollIndicators(.hidden).refreshable { await reload() }
        }.padding(.top, 8).scrollDismissesKeyboard(.interactively)
            .task { await reload() }
            .onChangeCompat(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
            .alert("操作未完成", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
                Button("好", role: .cancel) { actionFailure = nil }
            } message: { Text(actionFailure ?? "") }
            .sheet(item: $sheet) { content in
                switch content {
                case .reader(let file):
                NavigationStack {
                    ContinuousPDFReader(url: file.url).navigationTitle(file.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
                }.interactiveDismissDisabled()
                case .details(let file): PDFCoverDetails(file: file)
                }
            }
    }
    private func pdfRow(_ file: LocalPDF) -> some View {
        Button { sheet = .reader(file) } label: {
            HStack(spacing: 12) {
                PDFPageImage(url: file.url, index: 0, width: 160).frame(width: 48, height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    Text(file.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
            .opacity(library.isDisliked(file.id) ? 0.42 : 1)
            .accessibilityIdentifier("localPDF-" + file.url.lastPathComponent)
            .accessibilityValue(library.isDisliked(file.id) ? "不喜欢" : "")
            .disabled(busy.contains(file.id))
            .contextMenu {
                Button { sheet = .details(file) } label: { Label("详细信息", systemImage: "info.circle") }
                Button { toggleDislike(file) } label: {
                    Label(library.isDisliked(file.id) ? "取消不喜欢" : "不喜欢该漫画",
                          systemImage: library.isDisliked(file.id) ? "arrow.uturn.backward" : "hand.thumbsdown")
                }
                Button(role: .destructive) { deletion = PDFDeletionRequest(file: file, dislike: false) } label: {
                    Label("删除源文件", systemImage: "trash")
                }
                Button(role: .destructive) { deletion = PDFDeletionRequest(file: file, dislike: true) } label: {
                    Label("不喜欢并删除源文件", systemImage: "hand.thumbsdown")
                }
            }
            .popover(isPresented: Binding(get: { deletion?.file.id == file.id }, set: { if !$0 { deletion = nil } }), attachmentAnchor: .rect(.bounds)) {
                ComicConfirmationPopover(title: deletion?.dislike == true ? "不喜欢并删除源 PDF？" : "删除源 PDF？", message: "", tint: .red,
                    identifier: "confirmDeletePDF", destructive: true, singleLine: true) {
                        guard let request = deletion else { return }
                        deletion = nil; delete(request)
                    }
            }
    }
    private func toggleDislike(_ file: LocalPDF) {
        if library.isDisliked(file.id) {
            do { try library.restore(file.id) } catch { actionFailure = error.localizedDescription }
        } else {
            busy.insert(file.id)
            Task { @MainActor in
                defer { busy.remove(file.id) }
                do { try await dislike(file) } catch { actionFailure = error.localizedDescription }
            }
        }
    }
    private func dislike(_ file: LocalPDF) async throws {
        try library.dislike(file, cover: await cover(file))
    }
    private func cover(_ file: LocalPDF) async -> Data? {
        let image = try? await LocalPDFLoader.image(url: file.url, page: 0, width: 180)
        return image.flatMap { UIImage(cgImage: $0).pngData() }
    }
    private func delete(_ request: PDFDeletionRequest) {
        busy.insert(request.file.id)
        Task { @MainActor in
            defer { busy.remove(request.file.id) }
            do {
                // Persist the dislike before deleting anything. If saving fails,
                // the source remains; a deletion failure keeps the saved dislike.
                if request.dislike {
                    let thumbnail = library.isDisliked(request.file.id) ? nil : await cover(request.file)
                    try library.dislikeAndDelete(request.file, cover: thumbnail)
                } else { try library.deleteSource(request.file) }
                files.removeAll { $0.id == request.file.id }
                store.scanDownloadDirectory()
            } catch {
                actionFailure = request.dislike && library.isDisliked(request.file.id)
                    ? "已标记不喜欢，但源 PDF 未删除：" + error.localizedDescription : error.localizedDescription
            }
        }
    }
    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        let identities = await LocalPDFLoader.identities()
        var comics = store.jobs.map(\.comic)
        for (account, library) in store.libraries {
            let known = library.favorites + library.excluded + (library.hiddenComics ?? [])
            comics += await ComicTagCache.persistent(account: account).restoring(known + identities)
        }
        do { files = try await LocalPDFLoader.scan(comics: comics) }
        catch { failure = error.localizedDescription }
    }
}

private struct PDFCoverDetails: View {
    let file: LocalPDF
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PDFPageImage(url: file.url, index: 0, width: 900)
                            .frame(maxWidth: .infinity)
                            .frame(height: AppLayout(width: geometry.size.width, height: geometry.size.height).previewHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        Text(file.title).font(.title2.bold())
                        Text(file.reference).foregroundStyle(.secondary)
                        if !file.tags.isEmpty { Text(file.tags.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                        Text(file.url.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                            Spacer()
                            Text(file.date, style: .date)
                        }.font(.footnote).foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
            }.navigationTitle("封面详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct PDFExclusionsSection: View {
    @ObservedObject var library: LocalPDFLibraryState
    let accent: Color
    @State private var failure: String?
    var body: some View {
        Section {
            ForEach(library.exclusions) { record in
                HStack(spacing: 12) {
                    Group {
                        if let data = record.cover, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
                        else { Image(systemName: "doc.richtext").foregroundStyle(.secondary) }
                    }.frame(width: 48, height: 68).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.title).font(.subheadline.weight(.medium))
                        HStack {
                            Text(record.reference).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "hand.thumbsdown").foregroundStyle(accent).accessibilityLabel("不喜欢")
                            Button("取消排除") {
                                do { try library.restore(record.id) } catch { failure = error.localizedDescription }
                            }.font(.caption).buttonStyle(.borderless).accessibilityIdentifier("restorePDF-" + record.id)
                        }
                    }
                }.padding(.vertical, 4).accessibilityIdentifier("excludedPDF-" + record.id)
            }
        } header: { Text("PDF 预览 · 不喜欢 · \(library.exclusions.count)") } footer: {
            Text("PDF 名单保存在本机。取消排除后，仍存在的源 PDF 会重新显示；已删除的源文件不会恢复。")
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

private struct ContinuousPDFReader: View {
    let url: URL
    @State private var ratios: [CGFloat] = []
    @State private var failure: String?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let failure {
                    AppEmptyView(failure, systemImage: "doc.richtext")
                } else if ratios.isEmpty {
                    ProgressView("正在读取 PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(ratios.indices, id: \.self) { index in
                                PDFPageImage(url: url, index: index, width: 1200)
                                    // The placeholder and rendered page share exactly the same
                                    // height, including when an offscreen bitmap is released.
                                    .frame(width: geometry.size.width, height: geometry.size.width * ratios[index])
                                    .background(Color.white)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("漫画页面")
                                    .accessibilityIdentifier("pdfReaderPage-\(index)")
                            }
                        }
                    }.scrollIndicators(.hidden).accessibilityIdentifier("pdfContinuousReader")
                }
            }
        }.background(Color.white)
            .task(id: url) {
                do {
                    let pages = try await PDFPageLayout.aspectRatios(url: url)
                    try Task.checkCancellation()
                    ratios = pages
                }
                catch is CancellationError { }
                catch { failure = error.localizedDescription }
            }
    }
}

private struct PDFPageImage: View {
    let url: URL
    let index: Int
    let width: Int
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding() }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 64) }
        }.task(id: url.path + ":\(index):\(width)") {
            do {
                let rendered = try await LocalPDFLoader.image(url: url, page: index, width: width)
                try Task.checkCancellation()
                image = rendered
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }.onDisappear { image = nil }
    }
}
