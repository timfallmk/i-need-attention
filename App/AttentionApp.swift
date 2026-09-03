import CloudKit
import SwiftUI
import os.log
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
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
                .task {
                    appDelegate.appState = appState
                    // Lets willPresent apply a foreground status without routing through
                    // the app delegate, which has no part in that callback.
                    PushNotifications.shared.appState = appState
                    Haptics.prepare()
                    // Idempotent, and re-run here so the categories and the delegate are
                    // in place even if the delegate hook ever stops being called first.
                    PushNotifications.shared.configure()
                    // Subscribe early so a payload delivered during this launch is captured.
                    MetricKitCollector.shared.start()
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
                        onClear: { @MainActor recordName in
                            appState.clearOutgoing(recordName: recordName)
                        },
                        onSnooze: { @MainActor recordName, minutes in
                            appState.snoozeIncomingFromWatch(recordName: recordName, minutes: minutes)
                        },
                        onActivated: { @MainActor in
                            appState.pushWatchSnapshot()
                        }
                    )
                    await appState.bootstrap()
                    if !appState.notificationsAuthorized && !appState.notificationsDenied {
                        // First launch — ask for permission. Critical Alerts opt-in
                        // commented out: Apple denied the entitlement. Re-enable by
                        // restoring the requestCritical: parameter to the user setting.
                        // let granted = await PushNotifications.shared.requestAuthorization(
                        //     requestCritical: appState.settings.acceptCriticalAlerts
                        // )
                        let granted = await PushNotifications.shared.requestAuthorization(
                            requestCritical: false
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
                    await appState.reconcilePendingInvite()
                    await appState.reconcileHalfFormedPair()
                    await appState.refreshPartnerName()
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
        // Here, and not from a view's `.task`. Tapping an inline ack action on a banner
        // launches the app *in the background*, where no scene connects and no view body
        // ever runs — so a delegate set from SwiftUI is never set at all, and iOS finds
        // nobody to deliver the response to. The tap then does nothing, silently, while
        // the actions still render: categories persist on the system side from an earlier
        // launch, so the buttons appear whether or not this launch registered them.
        PushNotifications.shared.configure()
        Logger(subsystem: "com.timfallmk.attention", category: "Push")
            .notice("didFinishLaunching: notification delegate installed")
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            // Same background-launch problem: `appState` is handed over from a view's
            // `.task`, so a launch with no scene has none. Build one rather than dropping
            // the push — AppState's init only reads local storage.
            let state = appState ?? AppState()
            let result = await PushNotifications.shared.handleRemoteNotification(userInfo, appState: state)
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
        // Not fatal — pushes simply won't deliver until iCloud is signed in. Logged
        // rather than swallowed: silence here is indistinguishable from a subscription
        // that never fired, and the two need completely different fixes.
        Logger(subsystem: "com.timfallmk.attention", category: "Push")
            .error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }
}
