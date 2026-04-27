# Remote Pair Sharing Plan

Future enhancement: let the inviter share the pair link out-of-band (iMessage, AirDrop, etc.) instead of requiring the partner to physically scan a QR.

## Why

The current flow requires both phones to be in the same room to scan a QR. That's a hassle when:
- You're setting up for someone who lives elsewhere
- You realize you want to pair after-hours and your partner isn't with you
- The lighting / camera / QR rendering is finicky

CloudKit already does most of the heavy lifting — the QR is just a transport for the URL `attention://pair?k=<pairKey>&id=<deviceID>&n=<name>`. Any transport that delivers that string to the partner works in principle.

## What's missing today

The inviter's `ShowCodeView` polls the Pair record every 2s to detect the joiner filling `deviceB` (`PairingService.waitForJoiner`). The poll task is cancelled `onDisappear` of the view. So if the inviter:

1. Taps Show Code
2. Copies/shares the URL via iMessage
3. Closes the screen (or the app)

…the Pair record in CloudKit still exists, the partner can still complete pairing, but the inviter's phone never learns about it. They end up with no local `PairState` despite a fully-paired record on the server.

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

### 2. Install Pair subscription before the joiner completes

Right now `registerSubscriptions(...)` is called from `PairingService.waitForJoiner` and `completePairing`, both of which run after the pair is fully established. Move (or duplicate) the registration of the `pair-updates-v1` subscription so it's installed when the inviter creates the partial record.

Net effect: the inviter's phone gets a silent push when `deviceB` is filled, without polling.

### 3. Push handler

`PushNotifications.handleRemoteNotification` already routes `pair-updates-v1` pushes to `AppState.refreshPairFromCloud()`. Extend that path: if there's a `PendingInvite` and no `PairState` yet, build the `PairState` from the now-complete Pair record (deviceB, nameB) and save it just like `waitForJoiner` does.

### 4. UI

- **Show Code screen**: keep the QR, plus a Share button next to it that opens `UIActivityViewController` with the URL — so the user can iMessage/AirDrop/copy it.
- **Main screen when there's a `PendingInvite` but no `PairState`**: show a banner ("Waiting for partner to accept…") with a Cancel option. On launch, show this state automatically so the user doesn't think pairing is "stuck".
- **On the Pair update push completing pairing**: switch UI to the standard paired state, fire `Haptics.success()`.

### 5. Cancel / cleanup

- Manual cancel from the banner: delete the Pair record (or just clear the local PendingInvite — the orphan record is fine; it'll never get used because nobody knows the pairKey).
- TTL: if the PendingInvite is older than ~24h, prompt the user to renew or cancel. Stale records aren't a security risk per se but they clutter CloudKit.

## Security note

The pairKey is the trust boundary. Today it's only transmitted via in-person QR scan, which keeps it off the wire entirely. Remote sharing puts it on whatever transport the user chooses:

- **iMessage between Apple IDs**: end-to-end encrypted. Effectively as safe as in-person QR.
- **SMS / non-iMessage**: cleartext over carrier infrastructure. Anyone with intercept access could pair.
- **Email**: usually TLS-encrypted in transit but stored in mailboxes; depends on provider.
- **AirDrop**: peer-to-peer encrypted, requires proximity. Effectively as safe as in-person QR.

For a personal-use app between trusted people, iMessage and AirDrop are fine. The README already notes the public CloudKit DB isn't a privacy boundary against determined adversaries; this enhancement doesn't change that, but the docs should explicitly call out that the user controls the transport's security.

## When to do this

When in-person pairing becomes a recurring annoyance, or when adding a third user / re-pairing flow that doesn't require physical proximity.
