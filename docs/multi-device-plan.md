# Multiple Devices Per Person

**Status: design, unbuilt.** Covers [#68] (two installs on one Apple ID break each other's
pairing) and the first half of [#72] (one person, several devices). Written before any code,
in the present tense of the time; when the code lands, this file gets a status header like
`docs/private-database-plan.md` has and stops being a description of the future.

Target release: not yet fixed. Nothing here blocks 2.1.1, which is with App Review.

[#68]: https://github.com/timfallmk/i-need-attention/issues/68
[#72]: https://github.com/timfallmk/i-need-attention/issues/72

## The mismatch

The app models identity as **install**; CloudKit models it as **account**. #68 is not three
bugs, it is that one mismatch surfacing in three places, and the third is the only one that
needs real work.

Everything the app persists about itself lives in `UserDefaults`, which is per-install by
construction: `DeviceIdentity.id`, `PairState`'s non-secret half, and the inbox zone name. Everything CloudKit gives us is
per-account: the private database, the subscriptions in it, the zones it holds, and — because
`kSecAttrSynchronizable` is on — the pair key too. Sign a second device into the same Apple
ID and the two halves disagree about how many people are present.

### 1. Two devices, two zones

`InboxZone.currentName` mints `attention-inbox-<uuid>` into `UserDefaults` on first read. A
second install has no stored name, so it mints a second one. Both zones now sit in the same
private database and only one of them is the one the partner writes into.

### 2. The second device retires the first device's subscriptions

`CloudKitService.registerSubscriptions` treats a subscription whose `zoneID` is not the
current zone as stale, deletes it, and saves a replacement pointed at the current zone. That
is exactly right for re-pairing, which is what it was written for — the IDs are constants and
the zone name rotates, so ID-matching alone would leave a pairing that looks healthy and never
pushes.

It is exactly wrong across two devices. Install #2 comes up, finds four subscriptions naming
install #1's zone, and repoints all four at its own. Install #1 keeps a `PairState` that still
names the partner and still names a zone it owns, and simply stops being pushed to. Nothing
tells it. `Settings → Diagnostics` would say `staleZone`, but only if someone looked.

### 3. `senderDeviceID` is per install

Every classification of "mine" versus "theirs" compares `senderDeviceID` against
`PairState.myDeviceID` or `partnerDeviceID` — `AppState.handleIncomingChange`,
`HistoryView`, `DiagnosticsGatherer`. With one device each that is correct. With two it is
wrong in both directions:

- An alert **you** sent from your iPad reads as *incoming* on your iPhone, because its
  `senderDeviceID` is not the iPhone's.
- An alert your **partner** sent from *their* second device matches neither branch in
  `handleIncomingChange` and is dropped on the floor without a log line.

The second one is worth saying plainly: it is a silent message loss that exists today, and it
does not need anything in this plan to happen — only a partner who adds a device.

## The shape of the fix

Fixing the model dissolves (1) and (2) and leaves (3) as the actual work.

### Discover the zone instead of minting it

Zone names are already prefixed. `privateDB.allRecordZones()` lists what this account owns, so
the name can be *found* rather than invented:

1. A stored name whose zone exists → use it. **This is every install that exists today**, so
   the migration is a no-op for them.
2. A stored name whose zone does not exist → either a name minted a moment ago and not yet
   created, or a pairing ended from another device. `PairState` tells them apart: no local
   pairing means the former, a local pairing means the latter. See "Unpairing is account-wide".
3. No stored name → look for an adoptable zone, below. This is the second device.
4. Nothing adoptable → mint, as today.

#### What makes a zone adoptable

Not "it carries the prefix". `tearDownInboxZone` rotates the stored name **whether or not the
zone delete succeeded** — deliberately, and for a good reason documented at the call site: the
old name is what the next pairing would otherwise reuse, and a zone-wide share hands over the
whole zone. The designed consequence is that a failed delete leaves an orphaned prefixed zone
in the account. A fresh second device that adopted one of those by prefix alone would pick up
the previous partner's records and offer them to the next one, which is the exact leak
per-pairing zone names exist to prevent.

So the test is cryptographic rather than lexical: **a zone is adoptable when it holds a
`PairProfile` that opens under the pair key this account currently has.** Both halves matter.
`unpair` calls `PairState.clear()`, which drops the synchronizable keychain item, and a
synchronizable delete propagates — so after an unpair there is no key on the account and
nothing is adoptable, which is the correct answer. A zone left over from an *earlier* pairing
is sealed under a key that no longer exists and fails the same test. What passes is a zone
belonging to the pairing the account is in right now, which is precisely what a second device
is looking for.

If more than one zone passes — a genuine race, two devices pairing within the same moment
under the same key — the property that matters is not which is picked but that **every device
picks the same one**, because disagreeing is the bug this whole change exists to remove. Sort
the surviving names lexicographically and take the first: a pure function of what the server
holds, so two devices running it a second apart agree. Losers are left alone rather than
deleted — deleting a zone deletes a share with it, and a wrong guess there costs a live
pairing.

#### Don't mint before the key arrives

The adoptability test needs the pair key, and on a brand-new second device the key arrives by
iCloud Keychain sync, which is not instant and is not something the app is told about. A launch
that beats the sync finds no key, finds nothing adoptable, mints a name, and — because
`registerSubscriptions` calls `ensureInboxZone` at every launch regardless of pairing state —
creates a rival zone. That is #68 reproduced by a race instead of by design.

The fix is to stop creating a zone the device has no use for: a device with no `PairState` and
no pair key is not in a pairing and does not need an inbox. Minting moves to the point where a
pairing actually starts, and launch-time discovery on an unpaired device simply finds nothing
and does nothing. Re-running discovery on foreground then picks the zone up whenever the key
does land, with no extra signal required.

#### The mechanical cost

`InboxZone.currentName` is synchronous today and this makes the lookup async.
`CloudKitService.inboxZoneID` is the caller that has to change; `HistoryView` and `AppState`
read `currentName` as a *pairing identifier* for the archive, which wants the stored value and
not a network round trip, so they stay as they are. `ensureInboxZone` is already async and
already deduplicates through `EnsuredZones`, so discovery belongs there with the resolved name
cached behind the same lock.

### Unpairing is account-wide, and has to say so

`unpair` deletes the zone and rotates the stored name. The other device still holds the old
name and a `PairState` that claims a healthy pairing. Discovery case (2) above is what catches
it: stored name, no such zone, local `PairState` present → clear the pairing and set a notice,
in the same shape as `PartnerUnpairedNotice` and for the same reason. "Why am I suddenly
unpaired?" needs an answer on the pairing screen or the app looks broken.

Two details to get right while implementing, both found in the writing:

- `unpair()` tears the zone down (which rotates) and only then calls `PairState.clear()`. A
  discovery running between those two lines would see a missing zone and a live `PairState`
  and fire the notice on the device doing the unpairing. Clearing before the teardown, or
  gating discovery for the duration, closes it.
- A vanished zone must **not** fall through to adoption. If the person unpaired and then
  paired with someone else, the zone sitting there belongs to the new pairing, and adopting
  it would leave a `PairState` naming the old partner attached to the new partner's zone.
  Ending the pairing first and adopting on a later pass keeps the two apart.

One imprecision this leaves, in the explanation rather than the action: signing the device
into a *different* Apple Account also makes the zone unfindable, and the notice then blames
another device when the pairing was really left behind with the old account. Ending it is
still the right action — that pairing cannot work from this account — but the wording is
wrong until `PairState` carries the account's own record ID, which is step 3.

This is the behaviour the UX section below commits to: pairing or unpairing from any device
does it for the person, not for the device.

### The pair key needs nothing

`PairSecretStore` already stores one synchronizable item per Apple ID
(`kSecAttrSynchronizable: true`, `AfterFirstUnlock`, App Group as access group). That was only
ever wrong because two installs on one account could be two *different* pairings; once one
account is one person is one pairing, one key per account is the correct cardinality and the
second device gets the key by iCloud Keychain without asking.

What this does **not** fix, because it is a different axis entirely: a Debug build and a
TestFlight build on the same Apple ID still share that one item while talking to different
CloudKit environments, so pairing in Debug still overwrites the key Production is using. That
is cross-*environment*, not cross-device; it stays a testing rule (`CLAUDE.md` → "Testing with
a second install") rather than something this change can close.

### The subscriptions need nothing

Constant subscription IDs in a per-account database are only wrong when they name different
zones. Once every device discovers the same zone, `registerSubscriptions` finds all four live
and saves nothing — and CloudKit fans a subscription's push out to every device registered on
the account, so the second device gets the banner without owning a subscription of its own.
The delete-stale branch stays exactly as it is; re-pairing still needs it.

### Person identity: the real work

Replace the per-install `senderDeviceID` with an account-scoped identity.
`CKContainer.userRecordID` is the obvious one, and half of it is already in the codebase: the
handshake reads the partner's from `metadata.ownerIdentity.userRecordID` (`ZoneSharing`) in
order to name them as the sole participant on the second share. Ours is one call this app has
never had to make.

The migration is **additive**, because records written by older builds are still sitting in
both zones and must keep rendering:

- New `Alert` field `senderUserID`, written alongside `senderDeviceID`, never instead of it.
- Readers prefer `senderUserID` and fall back to `senderDeviceID` when it is absent.
- `PairState` gains `myUserID` and `partnerUserID`, populated during the handshake and
  backfilled on launch for existing pairings — ours from `userRecordID`, theirs from the share
  metadata the pairing already reads.
- Until a pairing has both user IDs, classification falls back to today's device comparison, so
  an existing pairing keeps working through the upgrade and improves the moment both sides have
  written a record under the new field.

Sites to change: `AlertRecord`, `ArchivedAlert`, `AppState.handleIncomingChange`,
`HistoryView` (row direction and the partner-name heuristic), `DiagnosticsGatherer`. The
`Alert` field is the one real schema change in this plan — a String, **not** indexed (zone
membership is the filter, nothing queries the sender), added to `cloudkit-schema.ckdb` in the
same commit and deployed Development → Production. Additive, so records written by older
builds simply lack it and the fallback covers them; it changes nothing about who can read
`Alert`, which still carries its pre-2.0 `_icloud` grants for the public-database records that
have not been purged yet. `Tools/AttentionCLI` writes
`senderDeviceID` and can keep doing so; the fallback covers it.

`DeviceIdentity.id` does not go away. It stays as what it has always been — the identifier of
an install — and is still what `DataErasure` resets. It just stops being asked to answer a
question about a person.

### The fifth subscription

A silent `CKQuerySubscription` on your own zone, record type `Alert`, `firesOnRecordUpdate`,
predicate `state == "acknowledged"`, `shouldSendContentAvailable`.

It does not overlap the four that exist. `incoming-alerts-v2` watches `Alert` but fires on
creation only; `outgoing-status-v2` and `outgoing-ack-v3` both watch `AlertStatus`, which is
the *sender's* copy in the *sender's* zone. Nothing today fires when an `Alert` in your own
zone changes state, which is precisely the event "I acknowledged this from my other device".

Why it is needed at all: `removeDeliveredNotifications` only reaches the notification centre of
the process that calls it. If the banner is sitting on your iPad's lock screen and you
acknowledge from your iPhone, the only thing that can clear the iPad's banner is code running
on the iPad. Without this subscription, every device you own accumulates banners for alerts you
have already answered — which, in an app whose entire premise is one urgent notification,
is the failure that would make a second device feel worse than no second device.

No schema change: the predicate needs `Alert.state` to be QUERYABLE and it already is —
`cloudkit-schema.ckdb` line 91, `state STRING QUERYABLE`, indexed since the pre-2.0 design
queried on it. So this step is code only.

## Expected UX

Deliberately almost invisible. The feature is "it works on my iPad too", and a feature like
that is best delivered as the absence of a problem.

**Adding a device.** Sign in to the same Apple ID, install the app, open it. It discovers the
zone and the key and comes up paired, with history. No QR scan, no confirmation sheet, no
second pairing flow — there is nothing to confirm, because Apple already authenticated the
account and iCloud Keychain already moved the key.

**Sending.** Any device can send. The cooldown is `AppState.cooldownEnds`, in memory and
per-install by design (it is a fat-finger guard, not a rate limit), so it stays per-device; two
presses from two devices inside the cooldown window is a person doing it on purpose. The
sender's own status pill will not be live across devices in this pass — the iPad that sent it
learns the alert was acknowledged, the iPhone that didn't send it does not light up — because
that needs a subscription on the partner's zone, which the shared database cannot offer. It is
a real gap and it is the right one to defer.

**Receiving.** Every device on the account gets the push, because CloudKit fans it out. The
first device you answer on clears the rest, via the fifth subscription.

**Unpairing.** Account-wide, and stated as such at the point of the action: unpairing ends the
pairing on every device you own. The other devices find out on next launch or foreground and
say why, per "Unpairing is account-wide" above.

**Pairing someone new from a second device.** Same thing viewed from the other end, and it
deserves a warning before it happens rather than an explanation afterwards: pairing from any
device replaces the pairing everywhere.

**Erase All My Data.** Already deletes the synchronizable keychain item, and a synchronizable
delete propagates — so it has always been account-wide in effect (#68 §1a). This change makes
that honest rather than incidental, and the confirmation copy should say it.

**The watch.** Unchanged. It talks to its own paired iPhone and nothing else. A person with two
iPhones and one watch has the watch bound to one of them, which is Apple's constraint, not
ours.

**The only new pixels** are one line in `Settings → You`, under the existing "Paired with"
row: *signed in on 2 devices*. It exists so the count is checkable when something looks wrong,
and it is the whole visible surface of the feature.

## Order of work

Sequenced so each step is shippable on its own and the riskiest thing lands on top of the
safest.

1. **Zone discovery, and adopting the pairing that goes with it.** The enabler, and a
   no-op for every install that exists. Closes the subscription half of #68 as a side
   effect: they stop fighting once the zone agrees. Discovery alone would have been
   unreachable on the device that needs it — `registerSubscriptions` only runs for an
   install that already believes it is paired — so the adopting half ships with it:
   `adoptExistingPairing` reads the partner's zone out of the shared database (share
   acceptance is per account, so it is already there) and builds a `PairState` from the
   two profiles. It takes `myDeviceID` from the profile a previous device wrote into the
   partner's zone rather than from this install, so the account keeps presenting one
   identity and the partner does not drop the newcomer's alerts. That makes step 3 a
   robustness change rather than a prerequisite.
2. **Unpaired-elsewhere notice.** Small, and discovery case (2) is meaningless without it.
3. **Person identity.** The additive `senderUserID` migration, plus `PairProfile.userID` so
   each side can learn the other's without a share round trip. One `SenderIdentity` holds
   the fallback rule — account identity when *both* ends have one, per-install identity
   otherwise — because four hand-written copies of that condition would not stay identical.
   Two things the writing turned up: the exchange deadlocks unless something publishes an
   identity unprompted (each side learns the other's by reading a profile, and nothing
   writes one except a rename), so a pairing publishes once per device; and the
   dropped-alert bug in `handleIncomingChange` is better fixed by deciding from the *zone*
   than by adding a second identity to the same match — only a share participant can write
   into the zone we own, so anything there that is not ours is theirs, whether or not
   either side has an account identity yet.
4. **The fifth subscription.** Code only — `Alert.state` is already indexed.
5. **The Settings line.**

## What must be verified before shipping

None of this can be checked in the dev container — there is no Xcode toolchain here — and most
of it cannot be checked on one device either. In rough order of how much a wrong answer would
cost:

- **Two devices on one Apple ID both receive the push from one subscription.** The whole design
  rests on CloudKit's account-wide fanout. It is documented behaviour and it is still the
  assumption that would be most expensive to have wrong.
- **`allRecordZones()` on the private database lists zones created by the *other* device**, and
  promptly enough to be useful on a fresh install's first launch.
- **A second device's launch-time path really does avoid minting before the key syncs.** The
  race above is the one way this change could make #68 worse rather than better.
- **`userRecordID` is stable across devices on one account** and is what the share metadata
  reports for the partner, so the two sides of the comparison are the same namespace.
- **A second `CKQuerySubscription` on `Alert` in the same zone is accepted** alongside
  `incoming-alerts-v2`, differing only in options and predicate, and its silent push arrives.
- **The second device's `registerSubscriptions` really does save nothing** once discovery
  agrees — verifiable straight from `Settings → Diagnostics`, which already reports
  per-subscription zone match.
- **Testing this needs an Apple ID that is on no TestFlight install of this app**, for the
  keychain reason above. That rule predates this work and this work does not relax it.

## Out of scope here

- **Other platforms** (iPad as a first-class target, macOS, Vision) — the rest of #72. This
  change is a prerequisite for them and not a delivery of them.
- **More than two *people*.** Unchanged and still out of scope; this is several devices per
  person, not several people per pairing.
- **Live status across your own devices.** Noted under "Sending" above as a deliberate gap.
