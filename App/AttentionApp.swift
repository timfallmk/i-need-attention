import CloudKit
import SwiftUI
import UIKit

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
                    // Activate the watch bridge before bootstrap so that the initial
                    // pushWatchSnapshot() inside bootstrap finds an activated WCSession
                    // (sendSnapshot bails out otherwise). The bridge also re-pushes
                    // when activation completes as a belt-and-braces guard.
                    WatchBridge.shared.activate(
                        onPress: { @MainActor in
                            await appState.sendAttention()
                        },
                        onAck: { @MainActor recordName, emoji in
                            await appState.acknowledgeIncomingFromWatch(recordName: recordName, emoji: emoji)
                        },
                        onClear: { @MainActor in
                            appState.clearOutgoing()
                        },
                        onActivated: { @MainActor in
                            appState.pushWatchSnapshot()
                        }
                    )
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
                    await appState.reconcileLatestAlert()
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
