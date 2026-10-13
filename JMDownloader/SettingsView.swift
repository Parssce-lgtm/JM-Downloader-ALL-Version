import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.connected ? "当前为\(store.platform.label)登录" : "当前未登录").font(.headline)
                            Text(store.connected ? "\(store.platform.label) · \(store.displayAccount)" : "尚未登录").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "arrow.down.app.fill").font(.largeTitle).foregroundStyle(store.preferences.accent) }
                        .padding(.vertical, 8)
                }
                Section {
                    NavigationLink { AccountSettingsView(store: store, onSaved: { dismiss() }) } label: { Label("账号设置", systemImage: "person.crop.circle") }
                        .accessibilityIdentifier("accountSettings")
                    NavigationLink { ComicSettingsView(store: store) } label: { Label("已排除/隐藏", systemImage: "books.vertical") }.accessibilityIdentifier("comicSettings")
                    NavigationLink { TagBlacklistView(store: store) } label: { Label("黑名单", systemImage: "nosign") }.accessibilityIdentifier("tagBlacklist")
                }
                Section {
                    NavigationLink { ThemeSettingsView(store: store) } label: { Label("主题设置", systemImage: "paintpalette") }.accessibilityIdentifier("themeSettings")
                    NavigationLink { CacheSettingsView(store: store) } label: { Label("缓存与下载目录", systemImage: "internaldrive") }.accessibilityIdentifier("cacheSettings")
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.0")
                    LabeledContent("系统", value: AppAppearance.systemDescription)
                    NavigationLink("第三方许可") {
                        ScrollView {
                            Text(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "jmcomic 2.7.7 · MIT License · Copyright (c) 2023 hect0x7")
                                .font(.footnote).textSelection(.enabled).padding()
                        }.navigationTitle("第三方许可")
                    }
                    Text("图片使用系统后台下载，不再创建灵动岛进度。PDF 与兼容下载会在系统允许的后台时间内继续；时间不足时保留进度，返回应用自动接续。强制退出会停止后台工作。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("设置").toolbarColorScheme(store.preferences.colorScheme, for: .navigationBar).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(store.preferences.accent).preferredColorScheme(store.preferences.colorScheme)
            .alert("提示", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
                Button("好") { store.alert = nil }
            } message: { Text(store.alert ?? "") }
            .background(KeyboardDismissInstaller())
    }
}

struct CacheSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var clearing = false
    @State private var notice = ""
    var body: some View {
        Form {
            Section("封面缓存") {
                LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: store.coverCacheBytes, countStyle: .file))
                Button(clearing ? "正在清理…" : "清理封面缓存") {
                    clearing = true
                    Task {
                        await store.clearCoverCache()
                        await store.updateCacheSize()
                        notice = store.coverCacheBytes == 0 ? "封面缓存已清理" : "部分封面正在使用，请稍后再试"
                        clearing = false
                    }
                }.disabled(clearing).accessibilityIdentifier("clearCoverCache")
                Text("封面会保存在应用缓存中，返回书架时直接读取。清理仅删除封面缓存，不影响下载进度、账号会话或 PDF。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !notice.isEmpty { Text(notice).font(.caption).accessibilityIdentifier("cacheNotice") }
            }
            Section("下载目录扫描") {
                Text(store.preferences.directoryName)
                if !store.scanNotice.isEmpty { Text(store.scanNotice).font(.caption).accessibilityIdentifier("scanNotice") }
                Button(store.scanningDownloads ? "正在扫描…" : "重新扫描已有 PDF") { store.scanDownloadDirectory() }
                    .disabled(store.scanningDownloads)
                Text("返回应用时自动扫描默认目录及所选目录（含子文件夹）。识别本应用漫画编号及文件 App 的重名副本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("缓存与下载目录").task { await store.updateCacheSize() }
    }
}

struct AccountSettingsView: View {
    @ObservedObject var store: AppStore
    var onSaved: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var draft = Preferences()
    @State private var initialized = false
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var lineNotice: String?
    @State private var checkingConnection = false
    @State private var connectionTask: Task<Void, Never>?
    @discardableResult private func saveDraft() -> Bool {
        draft.selectedPlatform = store.platform
        draft.appearance = store.preferences.appearance; draft.themeColor = store.preferences.themeColor
        guard store.savePreferences(draft) else { errorFeedback += 1; return false }
        draft = store.preferences
        successFeedback += 1
        return true
    }
    var body: some View {
        Form {
            Section("切换平台") {
                Picker("漫画平台", selection: Binding(get: { store.platform }, set: { value in
                    password = ""; username = ""; store.switchPlatform(value)
                })) {
                    ForEach(ComicPlatform.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).disabled(store.signingIn).accessibilityIdentifier("platformPicker")
                Text("分别登录 JMComic 和 PicACG，切换平台即可切换收藏与账号。已开始的下载继续在后台进行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("\(store.platform.label) 账号") {
                if store.connected { Label("当前账号：\(store.displayAccount)", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                TextField("账号", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password).textContentType(.password)
                Toggle("记住账号", isOn: $draft.remember)
                Button {
                    guard saveDraft() else { return }
                    let target = store.platform, name = username, secret = password
                    Task { await store.login(username: name, password: secret, platform: target); password = "" }
                } label: { HStack { Text(store.signingIn ? "正在登录…" : "登录 \(store.platform.label)"); Spacer(); if store.signingIn { ProgressView() } } }
                    .disabled(store.signingIn || username.isEmpty || password.isEmpty)
                if store.connected { Button("退出当前账号", role: .destructive) { store.logout() }.disabled(store.signingIn) }
            }
            Section {
                if store.platform == .jmcomic {
                TextField("JM API（留空使用默认线路）", text: $draft.domains, axis: .vertical).lineLimit(2...4)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("图片域名", text: $draft.imageDomain).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } else {
                    TextField("PicACG API（留空使用默认线路）", text: Binding(get: { draft.picaDomain ?? Preferences.defaultPicaDomain }, set: { draft.picaDomain = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                TextField("HTTP 代理主机（留空使用系统网络）", text: $draft.proxyHost).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                HStack { Text("代理端口"); Spacer(); TextField("端口", value: $draft.proxyPort, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                Button("保存线路设置") {
                    guard saveDraft() else { return }
                    lineNotice = "线路设置已保存"
                    store.log("线路设置已保存 · " + (draft.proxyHost.isEmpty ? "使用系统网络" : "使用自定义代理"))
                }.accessibilityIdentifier("saveNetwork")
                if let lineNotice { Label(lineNotice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(store.preferences.accent).accessibilityIdentifier("networkNotice") }
                Button("恢复默认线路") {
                    if store.platform == .jmcomic { draft.domains = Preferences.defaultJMDomains; draft.imageDomain = Preferences.defaultImageDomain }
                    else { draft.picaDomain = Preferences.defaultPicaDomain }
                    draft.proxyHost = ""; draft.proxyPort = 7890
                    guard saveDraft() else { return }
                    lineNotice = "已恢复默认 API，代理使用系统网络"
                }.accessibilityIdentifier("restoreNetwork")
                Button {
                    guard saveDraft() else { return }
                    checkingConnection = true
                    let settings = store.preferences, platform = store.platform
                    connectionTask = Task {
                        defer { checkingConnection = false }
                        do {
                            let message = try await NetworkDiagnostics.check(settings, platform: platform)
                            try Task.checkCancellation()
                            store.log(message); lineNotice = message; successFeedback += 1
                        } catch is CancellationError { } catch { errorFeedback += 1; store.report(error) }
                    }
                } label: {
                    HStack { Text(checkingConnection ? "正在检测…" : "检测 API 连接"); Spacer(); if checkingConnection { ProgressView() } }
                }.disabled(checkingConnection).accessibilityIdentifier("checkNetwork")
                Text("当前 API：" + (store.platform == .jmcomic ? draft.effectiveJMDomains : draft.effectivePicaDomain))
                    .font(.caption).foregroundStyle(Color.secondary).textSelection(.enabled)
            } header: { Text("API 与代理") } footer: {
                Text("API 留空自动使用内置默认地址。代理可选，留空使用系统网络／VPN。支持无需认证的 HTTP CONNECT；修改线路后重新登录，后台代理下次启动生效。")
            }
            Section("下载与收藏") {
                Stepper("图片并发：\(draft.concurrency)", value: $draft.concurrency, in: 1...12)
                Button { store.refreshFavorites() } label: {
                    HStack { Label("刷新收藏", systemImage: "arrow.clockwise"); Spacer(); if store.refreshing { ProgressView() } }
                }.disabled(store.refreshing || !store.connected)
                Toggle("刷新收藏后自动下载", isOn: $draft.autoDownload)
                NavigationLink {
                    DownloadDirectoryControls(bookmark: $draft.directoryBookmark, name: $draft.directoryName)
                } label: { LabeledContent("下载目录", value: draft.directoryName) }
                    .accessibilityIdentifier("downloadDirectorySettings")
                Toggle("隐藏已完成任务", isOn: $draft.hideCompleted)
                Toggle("隐藏已删除任务", isOn: $draft.hideDeleted)
            }
            Section {
                Text("密码仅存于此设备的系统钥匙串。关闭“记住账号”会移除此应用保存的所有账号密码。删除下载任务会保留已导出的 PDF。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("账号设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { if !initialized { draft = store.preferences; username = store.displayAccount; initialized = true } }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if saveDraft() { store.log("账号设置已保存"); onSaved() } }
                    .disabled(store.signingIn).accessibilityIdentifier("saveAccount")
            } }
            .tint(store.preferences.accent)
            .appFeedback(.success, trigger: successFeedback)
            .appFeedback(.error, trigger: errorFeedback)
            .onDisappear { connectionTask?.cancel() }
            .onChangeCompat(of: store.platform) { _, _ in connectionTask?.cancel(); checkingConnection = false; lineNotice = nil; draft = store.preferences; username = store.displayAccount; password = "" }
            .onChangeCompat(of: store.account) { _, _ in username = store.displayAccount }
            .scrollDismissesKeyboard(.interactively)
            .onChangeCompat(of: draft) { old, value in
                guard initialized else { return }
                // Persist toggles immediately; text fields are validated only when Save is tapped.
                if old.concurrency != value.concurrency || old.remember != value.remember
                    || old.autoDownload != value.autoDownload || old.hideCompleted != value.hideCompleted
                    || old.hideDeleted != value.hideDeleted || old.directoryBookmark != value.directoryBookmark {
                    var updated = store.preferences
                    updated.concurrency = value.concurrency; updated.remember = value.remember
                    updated.autoDownload = value.autoDownload; updated.hideCompleted = value.hideCompleted
                    updated.hideDeleted = value.hideDeleted; updated.directoryBookmark = value.directoryBookmark
                    updated.directoryName = value.directoryName
                    store.savePreferences(updated)
                }
            }

    }
}

struct ComicSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        List {
            Section {
                ForEach(store.restrictedComics) { comic in
                    HStack(spacing: 12) {
                    CoverView(comic: comic, preferences: store.preferences).frame(width: 48, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .ignore).accessibilityHidden(false)
                        .accessibilityLabel("封面缩略图 " + comic.title).accessibilityIdentifier("restrictedCover-" + comic.id)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(comic.title).font(.subheadline.weight(.medium))
                        HStack {
                            Text(comic.reference).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if store.isHiddenFavorite(comic) {
                                Image(systemName: "eye.slash").foregroundStyle(store.preferences.accent)
                                    .accessibilityLabel("已隐藏").accessibilityIdentifier("hiddenReason-" + comic.id)
                            }
                            if store.isDisliked(comic) {
                                Image(systemName: "hand.thumbsdown").foregroundStyle(store.preferences.accent)
                                    .accessibilityLabel("不喜欢").accessibilityIdentifier("dislikedReason-" + comic.id)
                            }
                            Button("取消排除") { store.removeRestrictions(comic) }.font(.caption)
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("restoreRestricted-" + comic.id)
                        }
                    }
                    }.padding(.vertical, 4)
                }
            } header: { Text("已排除/隐藏 · \(store.restrictedComics.count)") } footer: {
                Text("名单按账号保存。小眼睛表示收藏中已隐藏，倒赞表示不喜欢；已排除的漫画不会自动下载。取消排除会同时解除该漫画的排除和隐藏。封面仅作缩略预览。")
            }
        }.overlay { if store.restrictedComics.isEmpty { AppEmptyView("暂无排除或隐藏漫画", systemImage: "eye.slash", description: Text("可隐藏收藏漫画，或在推荐中选择不喜欢")) } }
            .navigationTitle("已排除/隐藏").navigationBarTitleDisplayMode(.inline).tint(store.preferences.accent)
    }
}


struct TagBlacklistView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var titleDraft = ""
    var body: some View {
        Form {
            Section("标签黑名单") {
                TextField("例如：AI绘图, 血腥", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                Text("多个标签用逗号分隔，支持模糊匹配；包含这些标签的推荐作品会自动隐藏。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("漫画名黑名单") {
                TextField("例如：侦探", text: $titleDraft, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("titleBlacklistField")
                Text("多个关键词用逗号或换行分隔，支持模糊匹配。例如填写“侦探”，即可屏蔽标题含“名侦探”的推荐。主动搜索仍可找到这些作品。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("黑名单").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") {
            var value = store.preferences; value.tagBlacklist = draft; value.titleBlacklist = titleDraft
            if store.savePreferences(value) { dismiss() }
        } } }.onAppear { draft = store.preferences.tagBlacklist ?? ""; titleDraft = store.preferences.titleBlacklist ?? "" }.tint(store.preferences.accent)
    }
}
