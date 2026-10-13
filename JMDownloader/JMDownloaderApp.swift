import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppStore.shared.background.register()
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let store = AppStore.shared
        store.start()
        store.engine.backgroundCompletion = completionHandler
    }
}

@main
struct JMDownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = AppStore.shared
    @StateObject private var navigation = AppNavigationState(store: AppStore.shared)
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, navigation: navigation)
                .tint(navigation.configuration.preferences.accent)
                .preferredColorScheme(navigation.configuration.preferences.colorScheme)
                .task { store.start() }
                .onChangeCompat(of: scenePhase) { _, phase in
                    if phase == .active { store.becameActive() }
                    else if phase == .background { store.persist(); store.background.scheduleRecovery() }
                }
        }
    }
}
