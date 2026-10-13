import BackgroundTasks
import UIKit

@MainActor
final class BackgroundWork {
    weak var store: AppStore?
    private var enabled = false
    private var processing: BGProcessingTask?
    private var processingID: String { (Bundle.main.bundleIdentifier ?? "app.jmdownloader.jmdownloader") + ".processing" }
    var hasExecutionTime: Bool { processing != nil }

    func register() {
        guard !enabled else { return }
        // BGTaskScheduler does not execute these tasks in Simulator.
        #if !targetEnvironment(simulator)
        enabled = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: .main) { [weak self] task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let self, let store = self.store else { task.setTaskCompleted(success: false); return }
                self.processing = task
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.processing === task else { return }
                        self.processing = nil
                        store.engine.suspendLocalWork()
                        task.setTaskCompleted(success: false)
                        self.scheduleRecovery()
                    }
                }
                store.start()
                store.engine.resumeAutomatic()
                store.engine.pump()
            }
        }
        let oldPrefix = (Bundle.main.bundleIdentifier ?? "app.jmdownloader.jmdownloader") + ".continued."
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            for request in requests where request.identifier.hasPrefix(oldPrefix) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
            }
        }
        #endif
    }
    // Silent scheduling only: continued-processing requests create system Live Activities.
    func beginUserWork() { scheduleRecovery() }
    func refresh() {
        guard let store, store.engine.isReady else { return }
        if let processing, !store.jobs.contains(where: { $0.state.isRunning || $0.resumeAutomatically == true }) {
            processing.setTaskCompleted(success: true); self.processing = nil
        }
    }
    func scheduleRecovery() {
        guard enabled, let store else { return }
        let jobs = store.jobs.filter { $0.state.isRunning || $0.resumeAutomatically == true }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingID)
        guard !jobs.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = jobs.contains { $0.pages.isEmpty || $0.finished.count < $0.pages.count }
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { store.log("系统未安排额外后台时间；下次返回应用会自动接续系统暂停的任务。") }
    }
}
