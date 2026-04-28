import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct AttentionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    appDelegate.appState = appState
                    Haptics.prepare()
                    PushNotifications.shared.configure()
                    await appState.bootstrap()
                    if !appState.notificationsAuthorized && !appState.notificationsDenied {
                        // First launch — ask for permission. Critical-alert option
                        // only takes effect if Apple has granted the entitlement.
                        let granted = await PushNotifications.shared.requestAuthorization(
                            requestCritical: appState.settings.acceptCriticalAlerts
                        )
                        appState.notificationsAuthorized = granted
                        await appState.refreshNotificationStatus()
                    }
                    WatchBridge.shared.activate { @MainActor in
                        await appState.sendAttention()
                    }
                }
                .preferredColorScheme(nil)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check iCloud and notification permission when the user returns from
            // Settings — both can change while we're backgrounded.
            if newPhase == .active {
                Task {
                    await appState.refreshICloudStatus()
                    await appState.refreshNotificationStatus()
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                }
            }
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
