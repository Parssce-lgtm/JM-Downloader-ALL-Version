import SwiftUI
import UniformTypeIdentifiers

enum DownloadDirectory {
    struct Selection: Sendable { let bookmark: Data; let name: String }
    static func isAppDirectory(_ url: URL) -> Bool {
        let root = DiskStore.documents.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
    static func select(_ parent: URL, newFolder: String? = nil) throws -> Selection {
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw JMError.message("请选择文件夹，不能选择 PDF 或图片文件。")
        }
        let directory: URL
        if let newFolder {
            let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw JMError.message("请填写有效的文件夹名称，不要包含斜杠。")
            }
            directory = parent.appendingPathComponent(name, isDirectory: true)
        } else { directory = parent }
        // A picker grants access to the selected folder. Do not coordinate a write on
        // its parent directory: some File Providers wait indefinitely for that lock.
        if newFolder != nil {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw JMError.message("这个文件夹已存在，请更换名称或直接选择它。") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let probe = directory.appendingPathComponent(".jm-write-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data().write(to: probe, options: .withoutOverwriting)
        return Selection(bookmark: try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), name: directory.lastPathComponent)
    }

    static func resolve(_ bookmark: Data?) throws -> URL {
        guard let bookmark else { return DiskStore.documents }
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let initialDirectory: URL
    let onBegin: () -> Void
    let onSelected: (Result<DownloadDirectory.Selection, Error>) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onBegin: onBegin, onSelected: onSelected, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.directoryURL = initialDirectory
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onBegin: () -> Void
        let onSelected: (Result<DownloadDirectory.Selection, Error>) -> Void
        let onCancel: () -> Void
        init(onBegin: @escaping () -> Void, onSelected: @escaping (Result<DownloadDirectory.Selection, Error>) -> Void, onCancel: @escaping () -> Void) { self.onBegin = onBegin; self.onSelected = onSelected; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            // Retain the picker grant before dismissing its controller.
            let scoped = url.startAccessingSecurityScopedResource()
            onBegin()
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let selection = try await Task.detached(priority: .utility) { try DownloadDirectory.select(url) }.value
                    onSelected(.success(selection))
                } catch { onSelected(.failure(error)) }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

@MainActor struct DownloadDirectoryControls: View {
    @Binding var bookmark: Data?
    @Binding var name: String
    @State private var picking = false
    @State private var folderName = ""
    @State private var busy = false
    @State private var notice = ""
    @State private var feedback = 0
    var body: some View {
        Form {
            LabeledContent("当前下载目录", value: name).font(.subheadline).accessibilityIdentifier("downloadDirectoryName")
            AppButton("选择下载目录", systemImage: "folder") { picking = true }
                .disabled(busy).accessibilityIdentifier("chooseDownloadDirectory")
            Text("在系统文件页进入目标文件夹，点右上角“打开”即可选定该目录。新建文件夹也可在下面完成。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("新文件夹名称", text: $folderName).autocorrectionDisabled()
                    .accessibilityIdentifier("newDownloadFolderName")
                Button("新建并使用") { createFolder() }
                    .disabled(busy || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("createDownloadFolder")
            }
            Text("新文件夹会创建在当前下载目录内。").font(.caption).foregroundStyle(.secondary)
            if bookmark != nil {
                Button("恢复默认文件 App 目录") {
                    name = "我的 iPhone / JM downloader"; bookmark = nil; notice = "已恢复默认目录"; feedback += 1
                }
            }
            if busy { ProgressView("正在确认目录…") }
            if !notice.isEmpty { Text(notice).font(.caption).accessibilityIdentifier("directoryNotice") }
        }.navigationTitle("下载目录").navigationBarTitleDisplayMode(.inline)
            .appFeedback(.success, trigger: feedback)
            .sheet(isPresented: $picking) {
                FolderPicker(initialDirectory: (try? DownloadDirectory.resolve(bookmark)) ?? DiskStore.documents,
                             onBegin: { busy = true; notice = ""; picking = false },
                             onSelected: { result in
                    busy = false; picking = false
                    switch result {
                    case .success(let selection): apply(selection)
                    case .failure(let error): notice = "目录未更改：" + AppStore.friendly(error)
                    }
                }, onCancel: { picking = false })
            }
    }
    private func apply(_ selection: DownloadDirectory.Selection) {
        name = selection.name; bookmark = selection.bookmark
        folderName = ""; notice = "已选择：" + selection.name; feedback += 1
    }
    private func createFolder() {
        do { select(try DownloadDirectory.resolve(bookmark), newFolder: folderName) }
        catch { notice = AppStore.friendly(error) }
    }
    private func select(_ url: URL, newFolder: String? = nil) {
        busy = true; notice = ""
        Task {
            defer { busy = false }
            do {
                let selection = try await Task.detached(priority: .utility) { try DownloadDirectory.select(url, newFolder: newFolder) }.value
                // Name first, so bookmark observers persist a consistent pair.
                apply(selection)
            } catch { notice = "目录未更改：" + AppStore.friendly(error) }
        }
    }
}
