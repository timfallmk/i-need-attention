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
3. Set **Default Security Roles**: `_world` = **nothing**, `_icloud` = Create + Read + Write. Do not grant `_world` Read — it exposes every record, `pairKey` included, to unauthenticated callers. See `SECURITY.md` for what the pairKey does and does not protect.
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

- **Public CloudKit DB.** Records live in the public database, where CloudKit grants permissions per record type with no row-level scoping. **Any authenticated iCloud client** that can reach the container can read every pair's records — the `pairKey` is a field on the Pair record, not a credential, so knowing one isn't required to read it. Anonymous (`_world`) access is not granted by the schema in this repo; authenticated read and write remain, because the app itself is an authenticated client. Treat nothing here as private from a determined party.
- **Silent pushes for status updates can be throttled** by iOS if your phone is in Low Power Mode or the app has been force-quit. The "Seen / Acknowledged" indicator may take a moment to update.
- **App icon** is generated by `Tools/generate_icons.py` (requires Pillow: `pip install pillow`). Re-run it after editing that script to update `App/Assets.xcassets/AppIcon.appiconset/` and `Watch/Watch/Assets.xcassets/AppIcon.appiconset/`.

## License

[Mozilla Public License 2.0](LICENSE). Every file in this repository is Covered
Software under it unless that file says otherwise in its own header.

**There are no per-file licence headers, deliberately.** MPL's Exhibit A offers
the LICENSE-file alternative precisely so a project need not carry one in every
file, and a header that only restates the root licence buys nothing while
guaranteeing drift — a stale year, a missed file, a copied header that now names
the wrong terms. A notice earns its place only where it *contradicts* the root
licence, so that is the one case this repo requires one: **a file under terms
other than MPL-2.0 must carry its own notice.** Everything unmarked is MPL.

Third-party material bundled here is not source and is tracked separately: see
[`App/Models/OpenSourceLicenses.swift`](App/Models/OpenSourceLicenses.swift),
which is also what Settings → Open Source renders to users. Currently that is
Unicode Emoji Data and the notification sound (CC BY 3.0 — attribution details
in [`App/Resources/SOUND_PLACEHOLDER.md`](App/Resources/SOUND_PLACEHOLDER.md)).

MPL rather than a GPL-family licence because this app is distributed through the
App Store. GPL §10's "no further restrictions" clause and the App Store's terms
of use are in tension — the reason VLC came off the store in 2011 — and while a
sole copyright holder isn't bound by their own outbound grant, anyone who forks
this repo would be. MPL's copyleft is per-file: modifications to these files stay
open, a larger work that includes them doesn't have to be, and nothing about
shipping the result through a store is in doubt.
