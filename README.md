# Attention

A two-phone iOS app: tap the big red button, the other phone gets a push that says you need attention. Personal-use, paired by QR scan, no backend besides what Apple provides (CloudKit + APNs).

```
iPhone A                 iCloud (CloudKit)               iPhone B
+--------+                +------------------+            +--------+
|  TAP   |  write Alert  |  public DB +     |  push     |  alert  |
|  big   | ============> |  CKQuerySub      | ========> |  banner |
|  red   |               |  (filter on      |            |  buzz   |
|        |  <==========  |   pairKey)       | <======== |   tap   |
| status |  silent push  |                  |  ack/seen |   ack   |
+--------+                +------------------+            +--------+
```

## What's in here

- `App/` — the iOS app (SwiftUI, iOS 17+).
- `Watch/Watch/` — watchOS companion. Sends presses to the iPhone via WatchConnectivity.
- `NotificationService/` — Notification Service Extension. Upgrades incoming pushes to `.timeSensitive` (or `.critical` if the sender requested it and Apple has granted you the entitlement).
- `Shared/` — types used by both the app and the NSE.
- `project.yml` — XcodeGen spec. Run `xcodegen` to materialize `Attention.xcodeproj`.

## Build it

You need: Xcode 15+, an Apple Developer account, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Attention.xcodeproj
```

Then in Xcode:

1. **Pick your team.** Select the `Attention` target → Signing & Capabilities → Team. Repeat for `AttentionWatch` and `AttentionNotificationService`.
2. **Set bundle IDs.** Replace `com.example.attention` everywhere it appears (the three `*.entitlements` files, `project.yml`, and `Constants.swift` for both `cloudKitContainerID` and `AppGroup.identifier`) with your own reverse-DNS prefix. Re-run `xcodegen generate`.
3. **Create the iCloud container.** In Signing & Capabilities → iCloud → click **+ Container** and create `iCloud.<your.bundle.id>`. Update `Constants.cloudKitContainerID` to match.
4. **Create the App Group.** In Signing & Capabilities → **+ Capability → App Groups** → **+** → name it `group.<your.bundle.id>`. Add it to **both** the `Attention` target and the `AttentionNotificationService` target. Update `Constants.AppGroup.identifier` to match.
5. **First run.** Build + install on both phones (each signed in to its own Apple ID). The first launch asks for notification permission and shows the pairing screen.

## CloudKit Dashboard setup (first run only)

After your first sign-in to the container at <https://icloud.developer.apple.com/dashboard/>:

1. Create the **Pair** record type with these fields (all `String`, except where noted):
   - `pairKey` — **mark as Queryable**
   - `deviceA`, `deviceB`, `nameA`, `nameB`
2. Create the **Alert** record type:
   - `pairKey` — **Queryable + Sortable**
   - `senderDeviceID` — **Queryable**
   - `senderName`, `message`, `state`, `ackEmoji` — String
   - `seenAt`, `acknowledgedAt` — Date/Time
   - `critical` — Int (Int64), default `0`
3. Set **Default Security Roles** for both record types: `_world` = Read, `_icloud` = Create + Read + Write. CloudKit does not permit World Write; authenticated iCloud users are the effective write gate (both phones are always signed in). The pairKey is the access secret.
4. Promote schema to **Production** when ready (`Deploy to Production…`).

> Apple auto-creates record types the first time the app saves one in development, but the queryable indexes have to be added manually here. Without them, subscriptions silently fail.

## Pairing

Tap **Show Code** on phone A. Tap **Scan Code** on phone B and point it at A. Done — both phones can now press the button and receive alerts.

To repair: open Settings → Unpair, then start over. (Both phones unpair separately.)

## Critical Alerts

The split is two-sided so each user controls their own phone:

- **Sender** (per-press): tap the big button for a normal ping, or **long-press → Send as Critical** to flag this specific ping as urgent.
- **Receiver** (master toggle in Settings): "Accept Critical Alerts from \<partner\>" — defaults off. If unchecked, criticals from your partner are downgraded to `.timeSensitive` on your device.

A ping is presented as `.critical` (pierces silent + Focus + DND) only when **all three** are true:
1. The sender long-pressed and chose Send as Critical
2. The receiver has Accept Critical Alerts on
3. Apple has granted the Critical Alerts entitlement to your app ID

Critical Alerts require a one-time entitlement from Apple — request it under **Certificates, Identifiers & Profiles → Identifiers → your App ID → Capabilities → Critical Alerts**. Until granted, criticals fall back to `.timeSensitive`, which still pierces Focus.

`com.apple.developer.usernotifications.time-sensitive` is auto-granted; just add the capability in Xcode. The receiver toggle is read by the Notification Service Extension via the App Group container, which is why both targets need the App Group capability.

## Custom sound

A `needs-attention.caf` is already bundled in `App/Resources/`. To replace it, drop a new file (≤30s) there and re-run `xcodegen generate` — XcodeGen includes the whole `App/Resources/` folder automatically, so no manual "Add to target" step is needed. See `App/Resources/SOUND_PLACEHOLDER.md` for source attribution and `afconvert` re-derivation steps.

## Watch app

Reuses the iPhone's CloudKit credentials via WatchConnectivity — the watch never talks to CloudKit directly. Press the button on the watch, the message hops to the iPhone, the iPhone sends the alert.

## Architecture quick reference

| Concern | File |
| --- | --- |
| Big red button | `App/Views/AttentionButton.swift` |
| Status pill (Sent/Seen/Acked) | `App/Views/StatusIndicatorView.swift` |
| Pairing handshake | `App/Services/PairingService.swift` |
| All CloudKit reads/writes | `App/Services/CloudKitService.swift` |
| Push permissions + delegate | `App/Services/PushNotifications.swift` |
| Priority upgrade for incoming | `NotificationService/NotificationService.swift` |
| Receiver toggle shared with NSE | `Shared/SharedSettings.swift` (App Group) |
| Watch → iPhone bridge | `App/Services/WatchBridge.swift` and `Watch/Watch/WatchSession.swift` |

## Known limitations

- **Public CloudKit DB.** Anyone signed in to iCloud who knows your `pairKey` can write to your pair. The pairKey is 128-bit random and only ever transmitted via in-person QR scan, so this is acceptable for personal use but isn't suitable as a privacy boundary against a determined adversary.
- **Silent pushes for status updates can be throttled** by iOS if your phone is in Low Power Mode or the app has been force-quit. The "Seen / Acknowledged" indicator may take a moment to update.
- **No app icon yet.** Add a 1024×1024 PNG to `App/Assets.xcassets/AppIcon.appiconset/` (and the equivalent watch asset catalog).

## License

Personal use. Have fun.
