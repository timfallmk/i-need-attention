# Remote Pair Sharing Plan

**Status: implemented** (issue #44). The inviter can share the pair link out-of-band (iMessage, AirDrop, etc.) instead of requiring the partner to physically scan a QR. This doc is the design record; the sections below describe the pre-implementation state and the plan as built. One addition beyond the plan: a "Got an invite link? Paste it" fallback on the pairing chooser, because some transports don't render custom-scheme URLs as tappable links.

## Why

The current flow requires both phones to be in the same room to scan a QR. That's a hassle when:
- You're setting up for someone who lives elsewhere
- You realize you want to pair after-hours and your partner isn't with you
- The lighting / camera / QR rendering is finicky

CloudKit already does most of the heavy lifting — the QR is just a transport for the URL `attention://pair?k=<pairKey>&id=<deviceID>&n=<name>`. Any transport that delivers that string to the partner works in principle.

## What's missing today

Two independent gaps, one on each side of the handshake.

**Inviter side: no way to learn of a late completion.** The inviter's `ShowCodeView` polls the Pair record every 2s to detect the joiner filling `deviceB` (`PairingService.waitForJoiner`). The poll task is cancelled `onDisappear` of the view. So if the inviter:

1. Taps Show Code
2. Copies/shares the URL via iMessage
3. Closes the screen (or the app)

…the Pair record in CloudKit still exists, the partner can still complete pairing, but the inviter's phone never learns about it. They end up with no local `PairState` despite a fully-paired record on the server.

**Joiner side: no way to receive the link at all.** The only intake for a pair payload is the QR scanner (camera). The iOS app does not register the `attention://` URL scheme and has no `.onOpenURL` handler — only the *watch* app handles `attention://` (the complication's `attention://press`). Tapping a shared pair link in Messages on the partner's phone today does nothing.

## Plan

### 1. Persist the pending invite

Save the `PairingInvite` (pairKey, my deviceID, my name) plus the saved CKRecord ID locally as soon as `startInviting` succeeds:

```swift
struct PendingInvite: Codable {
    let pairKey: String
    let myDeviceID: String
    let myName: String
    let recordName: String     // CKRecord.ID.recordName
    let createdAt: Date
}
```

Persist to UserDefaults (key e.g. `attention.pendingInvite.v1`). Clear on success or on user-initiated cancel.

### 2. Install subscriptions when the invite is created

Within the pairing flow, `registerSubscriptions(...)` runs only in `PairingService.waitForJoiner` and `completePairing` — i.e. after the pair is fully established. (`AppState.bootstrap` also calls it: a re-register on every paired launch, and a placeholder schema-seed in unpaired DEBUG builds — but neither covers an in-flight invite.) Move the pairing-flow registration to invite-creation time instead.

Registering *all four* subscriptions early is simpler than special-casing `pair-updates-v1`: `registerSubscriptions` is idempotent by subscription ID, and both inputs it needs (the pairKey and the inviter's own deviceID) are known the moment the invite is generated. The alert-related subscriptions are inert until alerts exist, so early registration is harmless.

Net effect: the inviter's phone gets a silent push when `deviceB` is filled, without polling.

**Cleanup obligation this creates:** if the user cancels or regenerates an invite — or joins someone *else's* pair while offering their own invite — the subscriptions registered under the abandoned pairKey linger and would shadow a later registration under the same IDs. Clean them up first, and fail fast (don't proceed with the new registration) if cleanup fails. As built, cleanup only ever runs **unpaired**, where this app has no subscriptions worth keeping — so the existing `removeAllSubscriptions()` (the same call unpair uses) is exactly right, and no predicate-inspecting purge API is needed. (An earlier revision of this plan proposed a `purgeSubscriptions(pairKey:)` that matched on `predicateFormat`; that string is a debugging representation and unreliable to parse, so the blunt remove-all won.) The persisted `PendingInvite` is cleared only **after** cloud cleanup succeeds — it's the retry handle.

### 3. Completion delivery: push is the fast path, reconcile is the reliable one

`PushNotifications.handleRemoteNotification` already routes `pair-updates-v1` pushes to `AppState.refreshPairFromCloud()`. Extend that path: if there's a `PendingInvite` and no `PairState` yet, build the `PairState` from the now-complete Pair record (deviceB, nameB) and save it just like `waitForJoiner` does.

**Do not rely on the push alone.** `content-available` pushes are throttled by iOS and are *never* delivered to an app the user has force-quit. The reliable path is a launch/foreground reconcile: in `AppState.bootstrap` (and the foreground `reconcileLatestAlert` cycle), if a `PendingInvite` exists and there's no `PairState`, fetch the Pair record once and complete locally if `deviceB` is filled. This is a one-shot version of today's poll and reuses the same completion code as the push handler.

### 4. Joiner side: receiving the link

- **Register the `attention` URL scheme** for the iOS app: `CFBundleURLTypes` in the app's Info.plist, wired through `project.yml` (the Info.plist is build-time configured).
- **Add `.onOpenURL`** at the app scene level. Route `attention://pair?...` URLs into the pairing flow. Non-pair `attention://` URLs are ignored on iOS (the `press` host is watch-only).
- **Confirm before pairing.** A tapped link must not silently pair. Present a confirmation sheet ("Pair with <inviterName>?") showing the inviter's name from the URL, with explicit Pair/Cancel. On confirm, call the existing `PairingService.completePairing(payload:myName:)` — the payload is the URL string, which is exactly what the QR contains.
- **Trust posture is unchanged.** A tapped URL is the same untrusted input as a scanned QR. `PairingInvite.from(qrPayload:)` already parses defensively (validates scheme/host, no trapping on malformed input) — reuse it as-is. Per CLAUDE.md, never add a parsing path that trusts the payload more than the scanner does.
- **Why a custom scheme and not universal links:** universal links require an associated domain and a hosted `apple-app-site-association` file — i.e., a web server, which this app deliberately doesn't have. Custom-scheme links render as plain (non-preview) links in Messages and work when tapped; that's an acceptable trade for zero backend.

### 5. UI

- **Show Code screen**: keep the QR, plus a Share button next to it that opens `UIActivityViewController` (SwiftUI `ShareLink`) with the URL — so the user can iMessage/AirDrop/copy it.
- **Main screen when there's a `PendingInvite` but no `PairState`**: show a banner ("Waiting for partner to accept…") with a Cancel option. On launch, show this state automatically so the user doesn't think pairing is "stuck".
- **Joiner confirmation sheet** (new, see §4): inviter name + Pair/Cancel.
- **On completion (push or reconcile)**: switch UI to the standard paired state, fire `Haptics.success()`.

### 6. Cancel / cleanup

- Manual cancel from the banner: clear the local `PendingInvite`, purge the early-registered subscriptions (§2), and delete the Pair record (or leave it orphaned — it'll never get used because nobody knows the pairKey; deleting is tidier).
- TTL: if the `PendingInvite` is older than ~24h, prompt the user to renew or cancel. Stale records aren't a security risk per se but they clutter CloudKit.

## Security note

The pairKey is the trust boundary. Today it's only transmitted via in-person QR scan, which keeps it off the wire entirely. Remote sharing puts it on whatever transport the user chooses:

- **iMessage between Apple IDs**: end-to-end encrypted. Effectively as safe as in-person QR.
- **SMS / non-iMessage**: cleartext over carrier infrastructure. Anyone with intercept access could pair.
- **Email**: usually TLS-encrypted in transit but stored in mailboxes; depends on provider.
- **AirDrop**: peer-to-peer encrypted, requires proximity. Effectively as safe as in-person QR.

For a personal-use app between trusted people, iMessage and AirDrop are fine. The README already notes the public CloudKit DB isn't a privacy boundary against determined adversaries; this enhancement doesn't change that, but the docs should explicitly call out that the user controls the transport's security.

Registering the URL scheme also means *any* app or webpage can attempt to open `attention://pair?...`. The confirmation sheet in §4 is the mitigation: pairing never happens without an explicit user decision, and the worst a malicious link can do is show a "Pair with X?" prompt to decline.

## Touch points

`App/Services/PairingService.swift` (invite persistence, early registration, reconcile), `App/Services/PushNotifications.swift` (completion via push), `App/AppState.swift` (`bootstrap` reconcile, pending-invite state), `App/Views/PairingFlowView.swift` (ShareLink, waiting banner), a new joiner confirmation sheet, `App/Services/CloudKitService.swift` (`deletePair` for invite cancel), `project.yml` (CFBundleURLTypes). No CloudKit schema changes.

