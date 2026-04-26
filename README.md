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
2. **Set bundle IDs.** Replace `com.example.attention` everywhere it appears (the three `*.entitlements` files, `project.yml`, and `Constants.cloudKitContainerID`) with your own reverse-DNS prefix. Re-run `xcodegen generate`.
3. **Create the iCloud container.** In Signing & Capabilities → iCloud → click **+ Container** and create `iCloud.<your.bundle.id>`. Update `Constants.cloudKitContainerID` to match.
4. **First run.** Build + install on both phones (each signed in to its own Apple ID). The first launch asks for notification permission and shows the pairing screen.

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
3. Set **Default Security Roles** for both record types: World = Read + Write (this is a public DB, gated by knowledge of the pairKey).
4. Promote schema to **Production** when ready (`Deploy to Production…`).

> Apple auto-creates record types the first time the app saves one in development, but the queryable indexes have to be added manually here. Without them, subscriptions silently fail.

## Pairing

Tap **Show Code** on phone A. Tap **Scan Code** on phone B and point it at A. Done — both phones can now press the button and receive alerts.

To repair: open Settings → Unpair, then start over. (Both phones unpair separately.)

## Critical Alerts

The toggle in Settings flags your outgoing pings as critical, and the Notification Service Extension on the receiver upgrades them to `.critical` interruption level. Critical Alerts require a one-time entitlement from Apple — request it in your developer account under **Certificates, Identifiers & Profiles → Identifiers → your App ID → Capabilities → Critical Alerts**. Until granted, the system silently downgrades to `.timeSensitive`, which still pierces Focus.

`com.apple.developer.usernotifications.time-sensitive` is auto-granted; just add the capability in Xcode.

## Custom sound

Drop a `needs-attention.caf` (≤30s) into `App/Resources/` and add it to the app target. CloudKit will reference it by filename. See `App/Resources/SOUND_PLACEHOLDER.md`.

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
| Watch → iPhone bridge | `App/Services/WatchBridge.swift` and `Watch/Watch/WatchSession.swift` |

## Known limitations

- **Public CloudKit DB.** Anyone signed in to iCloud who knows your `pairKey` can write to your pair. The pairKey is 128-bit random and only ever transmitted via in-person QR scan, so this is acceptable for personal use but isn't suitable as a privacy boundary against a determined adversary.
- **Silent pushes for status updates can be throttled** by iOS if your phone is in Low Power Mode or the app has been force-quit. The "Seen / Acknowledged" indicator may take a moment to update.
- **No app icon yet.** Add a 1024×1024 PNG to `App/Assets.xcassets/AppIcon.appiconset/` (and the equivalent watch asset catalog).

## License

Personal use. Have fun.
