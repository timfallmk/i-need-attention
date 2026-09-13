# Attention

A two-person iOS app: tap the big red button, and your partner gets a push that says you need attention. Personal-use, paired by QR scan, no backend besides what Apple provides (CloudKit + APNs).

Pairing is between two *people*, not two handsets: every device signed in to the same Apple Account shares one pairing, so an iPhone and an iPad both send and receive without pairing twice. That second device adopts the pairing by reading the pair key out of the keychain, so it needs **iCloud Keychain** turned on — without it the device stays on the pairing screen with nothing to adopt. iPhone and iPad are supported from 2.2.0; an Apple Silicon Mac or Vision Pro runs the iPad build.

```
Device A                      iCloud (CloudKit)                   Device B
+--------+          +--------------------------------+           +--------+
|  TAP   |  write   |  B's inbox zone                |   push    |  alert |
|  big   | =======> |  (B's PRIVATE db, shared to A) | ========> |  banner|
|  red   |          |  contents sealed with the      |           |  buzz  |
|        | <======= |  pair key, held only on the    | <======== |  tap   |
| status |   push   |  paired devices                |  ack/seen |  ack   |
+--------+          +--------------------------------+           +--------+
```

Each person owns a zone in their own private database and shares it with their
partner; you write into *theirs*. Access is enforced by CloudKit per zone, and
everything human-readable is encrypted before it leaves the device. There is no
shared table and no lookup value that grants access.

## What's in here

- `App/` — the iOS app (SwiftUI, iOS 17+).
- `Watch/Watch/` — watchOS companion. Sends presses to the iPhone via WatchConnectivity.
- `NotificationService/` — Notification Service Extension. Decrypts the alert and upgrades the push to `.timeSensitive`, which pierces Focus.
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

1. **Pick your team.** Change `DEVELOPMENT_TEAM` in `project.yml` to your own Team ID (developer portal → Membership) and re-run `xcodegen generate`. The committed value is the original author's and won't work for you. Setting it per target in Xcode works too, but `*.xcodeproj/` is regenerated from `project.yml`, so it won't survive the next generate.
2. **Set bundle IDs.** Replace `com.timfallmk.attention` everywhere it appears (the `*.entitlements` files, `project.yml`, and `Shared/Constants.swift` for both `cloudKitContainerID` and `AppGroup.identifier`) with your own reverse-DNS prefix. Re-run `xcodegen generate`.
3. **Create the iCloud container.** In Signing & Capabilities → iCloud → click **+ Container** and create `iCloud.<your.bundle.id>`. Update `Constants.cloudKitContainerID` to match.
4. **Create the App Group.** In Signing & Capabilities → **+ Capability → App Groups** → **+** → name it `group.<your.bundle.id>`. Add it to **both** the `Attention` target and the `AttentionNotificationService` target. Update `Constants.AppGroup.identifier` to match.
5. **First run.** Build + install on both devices (each signed in to its own Apple ID). The first launch asks for notification permission and shows the pairing screen.

## CloudKit schema

The schema is checked in as `cloudkit-schema.ckdb` — import it rather than creating
record types by hand:

1. Sign in at <https://icloud.developer.apple.com/dashboard/> and pick your container.
2. **Import Schema** and give it `cloudkit-schema.ckdb`.
3. When you're ready to ship, **Deploy Schema Changes…** to promote Development to
   Production.

`SETUP.md` §4 is the full version, including the indexes CloudKit creates for
subscriptions rather than the file — those come from running a Debug build on a device
once, and are the usual cause of "push works in development but not in TestFlight".

## Pairing

Tap **Show Code** on device A. Tap **Scan Code** on device B and point it at A. Done — either of you can now press the button and receive alerts.

To repair: open Settings → Unpair, then start over. Only one of you needs to do it, and only once:
unpairing is **account-wide**, so it ends the pairing on every device signed in to your Apple Account,
and your partner's devices discover it the next time they send or open the app.

## Alert priority

Alerts are delivered `.timeSensitive`, which pierces Focus and Do Not Disturb.
`com.apple.developer.usernotifications.time-sensitive` is auto-granted — just add the
capability in Xcode.

**Critical Alerts are not available.** They pierce silent mode as well, and the code for
them is still here (sender flag, receiver toggle, the three-way decision in the NSE) but
commented out: Apple declined the entitlement for this app. `CLAUDE.md` lists the exact
blocks to restore if that ever changes. Until then a ping flagged critical is delivered
time-sensitive, which is the same thing minus silent mode.

The receiver's settings are read by the Notification Service Extension through the App
Group container, which is why both targets need the App Group capability.

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

- **Your partner's device is inside the boundary, and nothing else is.** Since 2.0 each person owns an inbox zone in their own private CloudKit database and shares it with their partner, so access is enforced per zone by CloudKit rather than by a value anyone can read. Record contents are sealed with ChaCha20-Poly1305 under a key derived from the pair key, which never reaches the storage provider — it holds ciphertext. What that does *not* protect against is a compromised device: the key is on every device either of you has signed in, which is more than two if either of you pairs an iPad. That is the right place for the boundary in a two-person app, but it is a boundary, and it is wider than the two handsets it started as. Structural fields (state, timestamps, device IDs) stay plaintext because predicates and sorting need them.
- **Pre-2.0 records were in the public database and some may still be there.** Before 2.0 everything lived in a world-readable table with the `pairKey` as a plaintext field on the record — a lookup value, not a credential, so it protected nothing. Upgrading re-pairs under a new key and archives the old history locally; the originals are removed by a purge that runs once both partners have upgraded. Assume anything sent before 2.0 was readable by any authenticated iCloud client.
- **Silent pushes for status updates can be throttled** by iOS if your device is in Low Power Mode or the app has been force-quit. The "Seen / Acknowledged" indicator may take a moment to update.
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
