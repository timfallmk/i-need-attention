# App States

Reference for all distinct states the app can be in, organized by layer.

## Screen-level states

Controlled by `RootView`. Evaluated in priority order on every render.

| State | Condition | View shown |
|---|---|---|
| **iCloud gate** | `iCloudStatus` is `.noAccount`, `.restricted`, or `.temporarilyUnavailable` | `ICloudGateView` |
| **Unpaired** | iCloud is available but `pair == nil` | `PairingFlowView` |
| **Paired** | `pair` is set | `MainView` |

## Alert lifecycle states

The three values the `Alert.state` CloudKit field can hold (`Constants.AlertState`). Each is a milestone in the round-trip from sender to receiver.

| State | Set by | When |
|---|---|---|
| `sent` | `CloudKitService.sendAlert` | Alert record is first written by the sender |
| `seen` | `CloudKitService.markAlertSeen` | Receiver's app processes the incoming push (see below) |
| `acknowledged` | `CloudKitService.acknowledgeAlert` | Receiver explicitly taps an emoji or "Acknowledge" |

### When "seen" is set

"Seen" does **not** require the receiver to tap anything in most circumstances:

- **App foregrounded or backgrounded**: `AppDelegate.didReceiveRemoteNotification` fires when the push lands → `AppState.handleIncomingChange` → `markAlertSeen` is called automatically.
- **App terminated (force-quit)**: alert pushes don't wake a terminated app. The state flips to `seen` only when the user **taps the banner**, launching the app and firing `userNotificationCenter(_:didReceive:)` with `defaultActionIdentifier` (`PushNotifications.swift`).
- **Inline ack from banner** (pull-down → tap emoji without opening app): skips `seen` entirely and goes straight to `acknowledged`.

## Status pill states

What `StatusIndicatorView` shows on the main screen. Incoming-unacked beats outgoing-pending beats idle.

| State | Emoji | Title | Subtitle | Tint |
|---|---|---|---|---|
| **Idle** | 💗 | "All quiet" | "Cooling down" if cooldown active, else none | Secondary |
| **Outgoing sent** | 📡 | "Sent" | "Waiting for them to look" | Blue |
| **Outgoing seen** | 👀 | "Seen" | "They saw it" | Indigo |
| **Outgoing acknowledged** | ✅ or chosen emoji | "Acknowledged" | "They got back to you" | Green |
| **Incoming pending** | 🔔 | "PartnerName \<message\>" | Relative timestamp | Red |

Outgoing acknowledged shows a dismiss (×) button. Tapping it calls `AppState.clearOutgoing`, which persists the record name to `UserDefaults` so the pill doesn't re-surface the same ack after backgrounding or relaunch.

Cooldown is an in-memory timer (`AppState.cooldownEnds`). It is not persisted — force-quitting the app resets it. It is purely a UI guard against accidental double-taps.

## iCloud account states

Sourced from `CKContainer.accountStatus()`, stored in `AppState.iCloudStatus`. The gate check in `RootView` blocks the app on `.noAccount`, `.restricted`, and `.temporarilyUnavailable`.

| Value | Meaning |
|---|---|
| `.couldNotDetermine` | Initial / still checking |
| `.available` | Normal; app proceeds |
| `.noAccount` | No Apple ID signed in |
| `.restricted` | Screen Time or MDM profile blocking iCloud |
| `.temporarilyUnavailable` | Network or server issue |

## Notification permission states

Tracked in `AppState.notificationsAuthorized` / `notificationsDenied`. Used to show a setup warning in Settings.

| State | Condition |
|---|---|
| **Authorized** | `authorizationStatus` is `.authorized` or `.provisional` |
| **Denied** | `authorizationStatus` is `.denied`; Settings shows a deep-link to fix it |
| **Not yet requested** | Neither flag set; permission prompt fires on first launch |
