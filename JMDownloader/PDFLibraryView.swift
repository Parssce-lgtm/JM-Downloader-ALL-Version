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

private struct LocalPDF: Identifiable, Sendable {
    let url: URL
    let title: String
    let comicID: String
    let tags: [String]
    let pages: Int
    let bytes: Int64
    let date: Date
    var id: String { url.path }
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
                    comicID: comic?.id ?? key?.components(separatedBy: ":").last ?? "", tags: tags,
                    pages: document.pageCount, bytes: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? values.creationDate ?? .distantPast)
            }
        }.value
    }

    static func image(url: URL, page: Int, width: Int) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let document = CGPDFDocument(url as CFURL), document.isUnlocked,
                  let page = document.page(at: page + 1) else { throw JMError.message("PDF 无法读取，可能已损坏或需要密码。") }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { throw JMError.message("PDF 页面尺寸无效。") }
            let rotated = abs(page.rotationAngle) % 180 != 0
            let ratio = rotated ? box.width / box.height : box.height / box.width
            let height = max(1, min(6000, Int(CGFloat(width) * ratio)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw JMError.message("无法创建 PDF 页面预览。") }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw JMError.message("PDF 页面绘制失败。") }
            return image
        }.value
    }
}

struct PDFLibraryView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [LocalPDF] = []
    @State private var query = ""
    @State private var searchVisible = false
    @State private var sort: PDFSort = .time
    @State private var loading = false
    @State private var failure: String?
    @State private var opened: LocalPDF?
    @FocusState private var searchFocused: Bool
    private var visible: [LocalPDF] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = files.filter { file in
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
        VStack(spacing: 10) {
            HStack {
                Button { searchVisible.toggle(); searchFocused = searchVisible } label: { Label("搜索", systemImage: "magnifyingglass") }
                Spacer()
                Menu {
                    Picker("排序", selection: $sort) { ForEach(PDFSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }.padding(.horizontal, layout.sideInset)
            if searchVisible {
                TextField("漫画名、JM 号或 #标签", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .padding(.horizontal, layout.sideInset).accessibilityIdentifier("localPDFSearch")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if loading && files.isEmpty { ProgressView("正在读取 PDF…").padding(32) }
                    else if visible.isEmpty {
                        AppEmptyView(failure ?? (query.isEmpty ? "这里还没有 PDF" : "没有匹配的 PDF"), systemImage: "doc.richtext",
                            description: Text(query.isEmpty ? "将 PDF 放入软件文件根目录，无需新建文件夹。" : "标签搜索必须以 # 开头；无标签元数据的 PDF 可按漫画名或 JM 号搜索。"))
                    }
                    ForEach(visible) { file in
                        Button { opened = file } label: {
                            HStack(spacing: 12) {
                                PDFPageImage(url: file.url, index: 0, width: 160).frame(width: 48, height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(file.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("\(file.pages) 页 · \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                    Text(file.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                        }.buttonStyle(.plain)
                    }
                    Text("\(visible.count) 个 PDF · 根目录").font(.caption).foregroundStyle(.secondary).padding(.vertical)
                }.padding(.horizontal, layout.sideInset).padding(.bottom, 48)
            }.scrollIndicators(.hidden).refreshable { await reload() }
        }.padding(.top, 8).scrollDismissesKeyboard(.interactively)
            .task { await reload() }
            .onChangeCompat(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
            .sheet(item: $opened) { file in
                NavigationStack {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(0..<file.pages, id: \.self) { index in
                                VStack {
                                    PDFPageImage(url: file.url, index: index, width: 1200)
                                    Text("\(index + 1) / \(file.pages)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding()
                    }.navigationTitle(file.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { opened = nil } } }
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
        }.task(id: url.path + ":\(index)") {
            do {
                let rendered = try await LocalPDFLoader.image(url: url, page: index, width: width)
                try Task.checkCancellation()
                image = rendered
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }.onDisappear { image = nil }
    }
}
