import CloudKit
import SwiftUI
import UIKit

@main
struct AttentionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    appDelegate.appState = appState
                    Haptics.prepare()
                    PushNotifications.shared.configure()
                    await appState.bootstrap()
                    if !appState.notificationsAuthorized {
                        let granted = await PushNotifications.shared.requestAuthorization(
                            requestCritical: appState.settings.requestCriticalAlerts
                        )
                        appState.notificationsAuthorized = granted
                    }
                    WatchBridge.shared.activate { @MainActor in
                        await appState.sendAttention()
                    }
                }
                .preferredColorScheme(nil)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let appState else { completionHandler(.noData); return }
            let result = await PushNotifications.shared.handleRemoteNotification(userInfo, appState: appState)
            completionHandler(result)
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // CloudKit handles APNs registration internally; no action needed.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Not fatal — pushes simply won't deliver until iCloud is signed in.
    }
}
