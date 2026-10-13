import Foundation
import UIKit

@MainActor
final class DownloadEngine: NSObject, URLSessionDownloadDelegate {
    static let identifier = "app.jmdownloader.background.images"
    weak var store: AppStore?
    private var mediaAttempts: [String: Int] = [:]
    private var session: URLSession!
    private var active: [String: URLSessionDownloadTask] = [:]
    private var direct: [String: Task<Void, Never>] = [:]
    private var directIDs: [String: UUID] = [:]
    private var useDirectTransfer = false
    private var directConfiguration: URLSessionConfiguration?
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var exports: [UUID: Task<Void, Never>] = [:]
    private var preparationIDs: [UUID: UUID] = [:]
    private var exportIDs: [UUID: UUID] = [:]
    private var restored = false
    private var cacheRecoveryScheduled = false
    var isReady: Bool { restored }
    var backgroundCompletion: (() -> Void)?

    func connect(_ store: AppStore, configuration: URLSessionConfiguration? = nil,
                 directConfiguration: URLSessionConfiguration? = nil) {
        self.store = store
        self.directConfiguration = directConfiguration
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        try? NetworkConfiguration.apply(store.preferences, to: config)
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        Task {
            for task in await session.allTasks {
                guard let transfer = task as? URLSessionDownloadTask, let key = task.taskDescription,
                      let (id, index) = Self.parse(key), let job = store.jobs.first(where: { $0.id == id }),
                      job.state == .downloading else { task.cancel(); continue }
                active[key] = transfer
            }
            restored = true
            for job in store.jobs where job.state == .paused && job.resumeAutomatically == nil
                && job.message.hasPrefix("兼容下载已暂停，请回到应用后继续") {
                store.change(job.id) { $0.resumeAutomatically = true }
            }
            resumeAutomatic()
            for job in store.jobs where job.state == .preparing || job.state == .exporting {
                store.change(job.id) { $0.state = $0.pages.isEmpty ? .queued : .downloading }
            }
            pump()
        }
    }
    func pump() {
        guard restored, let store else { return }
        defer { store.background.refresh() }
        for job in store.jobs where job.state.isRunning && store.isAutomaticExcluded(job.comic, owner: job.owner) && job.exclusionApproved != true {
            pause(job.id, pumpAfter: false)
        }
        for job in store.jobs where job.state == .queued && preparations.isEmpty {
            guard let api = store.clients[job.owner] else { continue }
            store.change(job.id) { $0.state = .preparing; $0.message = "读取图片清单…" }
            let generation = UUID()
            preparationIDs[job.id] = generation
            preparations[job.id] = Task { [weak self] in
                defer {
                    if self?.preparationIDs[job.id] == generation {
                        self?.preparationIDs[job.id] = nil
                        self?.preparations[job.id] = nil
                        self?.pump()
                    }
                }
                do {
                    let pages: [PageAsset]
                    do { pages = try await api.manifest(for: job.comic) }
                    catch JMError.authenticationExpired {
                        let renewed = try await store.renewSession(job.owner)
                        pages = try await renewed.manifest(for: job.comic)
                    }
                    try Task.checkCancellation()
                    guard !pages.isEmpty else { throw JMError.message("没有可下载的图片，任务已停止，请稍后重试。") }
                    try DownloadStorage.prepare(DiskStore.cache(job.id))
                    guard store.jobs.first(where: { $0.id == job.id })?.state == .preparing else { return }
                    store.change(job.id) { $0.pages = pages; $0.state = .downloading; $0.message = "" }
                } catch is CancellationError { }
                catch { self?.fail(job.id, error) }
            }
            // Prepare one album at a time, allowing its image transfers to start promptly.
            break
        }
        let limit = max(1, min(12, store.preferences.concurrency))
        var adopted = 0
        for job in store.jobs where job.state == .downloading {
            if job.finished.count == job.pages.count && !job.pages.isEmpty {
                export(job); continue
            }
            for (index, page) in job.pages.enumerated() where !job.finished.contains(index) {
                let runningForSource = active.keys.compactMap { Self.parse($0)?.0 }.filter { id in store.jobs.first(where: { $0.id == id })?.comic.source == job.comic.source }.count
                    + direct.keys.compactMap { Self.parse($0)?.0 }.filter { id in store.jobs.first(where: { $0.id == id })?.comic.source == job.comic.source }.count
                if runningForSource >= limit { break }
                let key = "\(job.id.uuidString):\(index)"
                if active[key] != nil || direct[key] != nil { continue }
                // Adopt a completed file after a process termination between file move and state save.
                if FileManager.default.fileExists(atPath: DiskStore.raw(job.id, index).path) {
                    store.change(job.id) { $0.finished.insert(index) }
                    adopted += 1
                    if adopted >= 32 {
                        if !cacheRecoveryScheduled {
                            cacheRecoveryScheduled = true
                            Task { [weak self] in
                                await Task.yield()
                                self?.cacheRecoveryScheduled = false; self?.pump()
                            }
                        }
                        return
                    }
                    continue
                }
                let urls = job.comic.source == .picacg ? MediaRequest.picaURLs(page.url) : [page.url]
                let url = urls[min(mediaAttempts[key] ?? 0, urls.count - 1)]
                let request = MediaRequest.make(url: url, platform: job.comic.source, preferences: store.preferences)
                if useDirectTransfer {
                    startDirect(request, key: key, id: job.id, index: index)
                    continue
                }
                let transfer = session.downloadTask(with: request)
                transfer.taskDescription = key
                active[key] = transfer
                transfer.resume()
            }
            if let updated = store.jobs.first(where: { $0.id == job.id }), updated.finished.count == updated.pages.count,
               !updated.pages.isEmpty { export(updated) }
        }
    }
    func pause(_ id: UUID, state: JobState = .paused, automatic: Bool = false, pumpAfter: Bool = true) {
        store?.change(id) { $0.state = state; $0.resumeAutomatically = automatic }
        preparationIDs[id] = nil
        exportIDs[id] = nil
        preparations.removeValue(forKey: id)?.cancel()
        exports.removeValue(forKey: id)?.cancel()
        for key in Array(direct.keys) where key.hasPrefix(id.uuidString + ":") {
            directIDs[key] = nil
            direct.removeValue(forKey: key)?.cancel()
        }
        for (key, task) in active where key.hasPrefix(id.uuidString + ":") {
            task.cancel(); active.removeValue(forKey: key)
        }
        if pumpAfter { pump() }
    }
    func pauseAll(ids: Set<UUID>) {
        for job in store?.jobs ?? [] where ids.contains(job.id) && (job.state.isRunning || job.resumeAutomatically == true) {
            pause(job.id, pumpAfter: false)
        }
        pump()
    }
    func suspendLocalWork() {
        let ids = Set(direct.keys.compactMap { Self.parse($0)?.0 }).union(exports.keys).union(preparations.keys)
        for id in ids {
            pause(id, automatic: true, pumpAfter: false)
            store?.change(id) { $0.message = "等待系统后台时间，进度已保留，将自动接续。" }
        }
        store?.background.scheduleRecovery()
    }
    func resumeAutomatic() {
        guard restored, let store else { return }
        for job in store.jobs where job.state == .paused && job.resumeAutomatically == true
            && (!store.isAutomaticExcluded(job.comic, owner: job.owner) || job.exclusionApproved == true) {
            resume(job.id, pumpAfter: false)
        }
    }
    private func startDirect(_ request: URLRequest, key: String, id: UUID, index: Int) {
        let generation = UUID()
        directIDs[key] = generation
        direct[key] = Task { [weak self] in
            guard let self, let store = self.store else { return }
            var token: UIBackgroundTaskIdentifier = .invalid
            if !store.background.hasExecutionTime { token = UIApplication.shared.beginBackgroundTask(withName: "Download image directly") { [weak self] in
                Task { @MainActor in
                    if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
                    guard let self, self.directIDs[key] == generation else { return }
                    guard !store.background.hasExecutionTime else { return }
                    self.pause(id, automatic: true)
                    self.store?.change(id) { $0.message = "等待系统后台时间，进度已保留，将自动接续。" }
                    store.background.scheduleRecovery()
                }
            } }
            defer {
                if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
                if self.directIDs[key] == generation {
                    self.directIDs[key] = nil
                    self.direct[key] = nil
                    self.pump()
                }
            }
            do {
                let config = self.directConfiguration ?? URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                try NetworkConfiguration.apply(store.preferences, to: config)
                let staged = try await DownloadStorage.receive(request, configuration: config, directory: DiskStore.cache(id))
                defer { try? FileManager.default.removeItem(at: staged) }
                try Task.checkCancellation()
                guard self.directIDs[key] == generation,
                      store.jobs.first(where: { $0.id == id })?.state == .downloading else { return }
                try DownloadStorage.commit(staged, to: DiskStore.raw(id, index))
                store.change(id) { $0.finished.insert(index) }
            } catch is CancellationError { }
            catch {
                guard self.directIDs[key] == generation else { return }
                if !self.retryMedia(error, key: key, id: id, index: index) { self.fail(id, error) }
            }
        }
    }
    func resume(_ id: UUID, pumpAfter: Bool = true) {
        if let store, let job = store.jobs.first(where: { $0.id == id }),
           store.isAutomaticExcluded(job.comic, owner: job.owner), job.exclusionApproved != true { return }
        mediaAttempts = mediaAttempts.filter { !$0.key.hasPrefix(id.uuidString + ":") }
        let imageHost = try? Validation.hosts(store?.preferences.effectiveImageDomain ?? Preferences.defaultImageDomain).first
        store?.change(id) { job in
            job.finished = job.finished.filter { FileManager.default.fileExists(atPath: DiskStore.raw(id, $0).path) }
            if job.comic.source == .jmcomic, let imageHost {
                for index in job.pages.indices {
                    var url = URLComponents(url: job.pages[index].url, resolvingAgainstBaseURL: false)
                    url?.host = imageHost
                    if let updated = url?.url { job.pages[index].url = updated }
                }
            }
            job.state = job.pages.isEmpty ? .queued : .downloading; job.message = ""; job.resumeAutomatically = false
        }
        if pumpAfter { pump() }
    }
    private func retryMedia(_ error: Error, key: String, id: UUID, index: Int) -> Bool {
        guard MediaRequest.canRetry(error), let job = store?.jobs.first(where: { $0.id == id }),
              job.state == .downloading, job.comic.source == .picacg, job.pages.indices.contains(index) else { return false }
        let next = (mediaAttempts[key] ?? 0) + 1
        guard next < MediaRequest.picaURLs(job.pages[index].url).count else { return false }
        mediaAttempts[key] = next
        store?.change(id) { $0.message = "图片线路被拒绝，正在自动切换线路（\(next + 1)）" }
        return true
    }
    private func fail(_ id: UUID, _ error: Error) {
        guard let state = store?.jobs.first(where: { $0.id == id })?.state,
              state != .paused, state != .deleted else { return }
        pause(id, state: .failed)
        let message = AppStore.friendly(error)
        store?.change(id) { $0.message = message }
        store?.log(message)
    }
    private func export(_ job: DownloadJob) {
        guard exports[job.id] == nil, let store else { return }
        store.change(job.id) { $0.state = .exporting; $0.renderedPages = 0; $0.skippedPages = [] }
        let bookmark = store.preferences.directoryBookmark
        let generation = UUID()
        exportIDs[job.id] = generation
        exports[job.id] = Task { [weak self] in
            defer {
                if self?.exportIDs[job.id] == generation {
                    self?.exportIDs[job.id] = nil
                    self?.exports[job.id] = nil
                    self?.pump()
                }
            }
            var token: UIBackgroundTaskIdentifier = .invalid
            if !store.background.hasExecutionTime { token = UIApplication.shared.beginBackgroundTask(withName: "Export PDF") { [weak self] in
                Task { @MainActor in
                    if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
                    guard !store.background.hasExecutionTime, self?.exportIDs[job.id] == generation else { return }
                    self?.pause(job.id, automatic: true)
                    store.background.scheduleRecovery()
                }
            } }
            defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
            do {
                let result = try await ImagePipeline.shared.exportResult(job, bookmark: bookmark, onProgress: { [weak engine = self] count, skipped in
                    guard let engine else { return }
                    Task { @MainActor in
                        guard engine.exportIDs[job.id] == generation else { return }
                        store.change(job.id) { $0.renderedPages = count; $0.skippedPages = skipped }
                    }
                })
                try Task.checkCancellation()
                guard store.jobs.first(where: { $0.id == job.id })?.state == .exporting else { return }
                store.change(job.id) {
                    $0.state = .completed; $0.output = result.url; $0.skippedPages = result.skipped
                    let skipped = result.skipped.count
                    $0.message = skipped == 0 ? "PDF 已保存到文件 App" : "PDF 已保存，已跳过 \(skipped) 张无效图片（内容可能缺页）"
                }
                store.log("《\(job.comic.title)》\(store.jobs.first(where: { $0.id == job.id })?.message ?? "下载完成")")
                // Keep raw pages until the completed job and PDF location are durable.
                if await store.flushProgress() { try? FileManager.default.removeItem(at: DiskStore.cache(job.id)) }
            } catch is CancellationError { }
            catch { self?.fail(job.id, error) }
        }
    }
    nonisolated static func parse(_ key: String) -> (UUID, Int)? {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[1]), index >= 0 else { return nil }
        return (id, index)
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let (id, index) = Self.parse(key) else { return }
        // Move before returning: URLSession removes the temporary file as soon as this callback returns.
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ImageHTTPError(status: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try DownloadStorage.prepare(DiskStore.cache(id))
            let staged = DiskStore.cache(id).appendingPathComponent(UUID().uuidString + ".partial")
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: staged) }
                guard let self, let job = self.store?.jobs.first(where: { $0.id == id }),
                      self.active[key] === downloadTask,
                      job.state == .downloading, job.pages.indices.contains(index) else { return }
                do {
                    try DownloadStorage.commit(staged, to: DiskStore.raw(id, index))
                    self.active[key] = nil
                    self.store?.change(id) { $0.finished.insert(index) }
                    self.pump()
                } catch { self.fail(id, error) }
            }
        } catch {
            Task { @MainActor [weak self] in
                guard self?.active[key]?.taskIdentifier == downloadTask.taskIdentifier else { return }
                guard let self else { return }
                self.active[key] = nil
                if self.retryMedia(error, key: key, id: id, index: index) { self.pump() }
                else { self.fail(id, error) }
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription, let (id, index) = Self.parse(key) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A canceled older transfer must not remove a newer retry with the same description.
            guard self.active[key]?.taskIdentifier == task.taskIdentifier else { return }
            self.active[key] = nil
            if DownloadStorage.needsDirectTransfer(error) {
                if !self.useDirectTransfer {
                    self.store?.log("系统无法创建下载临时文件，已自动切换兼容下载；系统允许后台执行时会接续图片下载与 PDF 转换。")
                }
                self.useDirectTransfer = true
            } else if (error as NSError).code != NSURLErrorCancelled {
                if !self.retryMedia(error, key: key, id: id, index: index) { self.fail(id, JMError.message("图片下载失败：" + AppStore.friendly(error))) }
            }
            self.pump()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            await self?.store?.flushProgress()
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }
}
