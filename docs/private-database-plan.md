# Private Inbox Zones + Encrypted Payloads

**Status: in progress.** Supersedes "Option 3" as originally scoped (a single `CKShare`d zone owned by the inviter). This doc is the design record and the decision log.

Landed so far: the crypto layer (`Shared/PairCrypto.swift`) and the diagnostics export, both pure enough not to wait on the spike. Everything structural is still unbuilt.

**The spike is complete and the design survived it.** All four questions answered favourably: a participant's write fires the owner's subscription, a visible push renders a banner with the app force-quit, programmatic share acceptance needs no consent UI, and the owner's identity is readable from share metadata. The private database also accepts the visible-push-on-update shape the public database refuses, so the `Ack` record type can go. Caveats and the gaps inside those answers are recorded under [What must be verified](#what-must-be-verified-before-writing-production-code); the significant one is that everything was tested in **Development**.

Target release: **2.0.0**.

## Why

PR #61 closed anonymous read of the public database — verified behaviourally, a Web Services query with a valid API token now returns `ACCESS_DENIED` where it previously returned every `Pair` record with its `pairKey` in plaintext.

What that did not close: public-database security roles are per record type with no row-level scoping, so `_icloud` — every signed-in Apple ID — retains read *and write* on `Pair`, `Alert`, and `Ack`. Any authenticated client that can reach the container can still read every pair's records, and can still write into any pair. #62 bounds how hostile writes *render*; it does not stop them.

What keeps this narrow today is that `CKContainer(identifier:)` traps without the iCloud container entitlement, which Apple issues only to the owning team (verified under both team-signed and ad-hoc signing — issue #60). The residual paths are a leaked token or a jailbroken device.

## The design

Three independent layers. They were originally treated as competing options; they are not, and combining them is what makes the result work.

### 1. Inbox zones, not outbox zones

Each user owns **one zone in their own private database — their inbox.** The partner writes into it.

- B owns `zone_B`, shared read-write with A. A's alerts to B are written into `zone_B`.
- A owns `zone_A`, shared read-write with B. B's alerts to A are written into `zone_A`.

Two consequences, and both are the reason for this shape rather than the more obvious outbox one:

- **B subscribes to B's own private database.** The critical path — the incoming alert that must render with the app force-quit — rides a private-database subscription rather than a participant observing someone else's zone. That is far better-trodden ground.
- **Deletion is survivable and symmetric.** If A deletes the app, B keeps `zone_B` and therefore keeps every alert A ever sent. Each side loses only what it was holding for the other. Compare the single-shared-zone design, where the owner leaving destroys everything for both.

There is no owner of "the pair." That asymmetry — and the run of awkward decisions that followed from it around history, transport, and identity — was an artifact of the single-zone shape, not of private databases.

### 2. Encrypted payloads

Content is sealed with an AEAD (`ChaChaPoly`, CryptoKit — no dependency, iOS 17 has it) under a key derived from the pair key via HKDF. CloudKit only ever holds ciphertext.

Where a lookup value is needed in a queryable field, store `SHA256(pairKey)` rather than the key itself. The raw key lives only in the invite and in each device's local state.

This is orthogonal to layer 1 — encryption does not care which database the ciphertext sits in — and buys two things that access control alone does not:

- Content is unreadable **to Apple**, not just to other users.
- A hostile write **fails the authentication tag and is discarded silently**. Strictly stronger than #62, where sanitization only bounds how junk renders.

### 3. The invite keeps our own URL scheme

Because the encryption key must travel out-of-band — it cannot live in CloudKit, that is the entire point — the invite can never be *just* an iCloud share URL. It has to be our payload carrying both a share reference and the key:

```
attention://pair?s=<share reference>&k=<key>
```

So the custom scheme survives. QR scans open this app rather than Safari, link-sharing behaves as it does today, and `remote-pair-sharing-plan.md` stays valid. The app accepts the share programmatically rather than letting the system route an `icloud.com` tap.

This falls out of the encryption requirement rather than being worked around, which is worth noting: the earlier plan's transport regression was a consequence of *not* encrypting.

## Pairing handshake

Two shares are required for symmetry, but only the first is user-visible. After B accepts `share_A`, B is a read-write participant in `zone_A` — the devices already have a channel, so the second share travels over it rather than over a second QR.

```
1. A taps Invite       creates zone_A + share_A
                       QR encodes attention://pair?s=<share_A>&k=<key>
2. B scans             accepts share_A; B can now write into zone_A
   ─────────────────── machine-to-machine from here ───────────────────
3. B (no UI)           creates zone_B; delivers share_B via a record in zone_A
4. A (no UI)           subscription fires; A accepts share_B
5. Both directions live
```

One tap, one scan — the same as today. The key is exchanged once and serves both zones.

By step 3, B knows A's identity from `share_A`'s owner, so `share_B` can be created with A invited by `userRecordID` and `publicPermission = .none`. **No second bearer token need ever exist.** Neither user types the other's iCloud address at any point; identity is discovered through the accept.

### The half-formed state

B accepts at step 2, so **B→A works before A→B does**. If step 4 fails, the pair is one-directional. This must be designed for, not assumed away:

- `PairState` tracks each direction separately; the pair is not "paired" until both are confirmed.
- The UI shows "finishing setup" rather than "paired" until then, and never presents a send button that would silently do nothing.
- Retry on next foreground. Recoverable without user action.

## What this gives, and what it does not

Gives:

- **Metadata privacy.** Other users cannot see that a pair exists, its device IDs, its timing, or its volume. Access is CloudKit-enforced per zone.
- **Content privacy from Apple.** Ciphertext at rest.
- **Hostile writes rejected**, not merely bounded.
- **Per-user quota.** Storage counts against each user's iCloud rather than this app's CloudKit quota.
- **Symmetry**, with no owner of the pair and survivable one-sided deletion.

Does not give:

- **Protection against a compromised device.** The key is on both phones. This is the correct place for the boundary to sit for a two-person app, but it is a boundary.
- **Freedom from the spike below.** The critical path moves onto better-supported machinery, but "better-supported" is not "verified."

## What must be verified before writing production code

Four questions. **All four have now been answered, and all four favourably** — see the results recorded below. They are kept here in their original form so the answers can be read against what was actually asked.

1. **Does a participant's write into the owner's zone fire the owner's private-database subscription?** The whole inbox model rests on this — if it does not, the design collapses back to shared-database subscriptions and the original risk returns.
   → **Yes.** Confirmed in both directions.
2. **Can that subscription produce a visible (mutable-content) push?** This is what lets the NSE render a banner with the app force-quit — the app's core property. The `Ack` record type exists today only because the *public* database rejects `firesOnRecordUpdate` with a visible push, and whether that restriction reached private databases was the question.
   → **It does not reach them.** The shape is accepted and stored, and a banner renders with the app force-quit.
3. **Does programmatic share acceptance require user-consent UI?** Steps 2 and 4 of the handshake assume `CKFetchShareMetadataOperation` → `CKAcceptSharesOperation` works from a URL the app extracted itself. If the system insists on its own confirmation sheet, step 4 stops being invisible and the UX claim above weakens.
   → **No sheet.** Acceptance is headless.
4. **Can B invite A by `userRecordID` learned from `share_A`'s owner?** If not, `share_B` needs a bearer URL delivered through `zone_A` — workable, but a second bearer token then exists briefly.
   → **The identity is readable.** Inviting by it is not yet exercised — see the gaps recorded below.

**Spike, as originally scoped:** a throwaway branch, two iCloud accounts, two real devices. Question 2 was the one that could sink the approach; question 1 decided whether the inbox model was worth having at all. In the event it took a single-account probe and a two-account app, and neither survives — the results below are what remains of them.

~~If question 2 answers badly, the fallback is to keep a single content-free record in the public database purely as a push trigger.~~ **Not needed** — question 2 answered well. Recorded here only so the discarded option is visible: it would have cost the metadata privacy that motivates the move.

### Spike result, 2026-09-02 — the save-time half of question 2 is answered: YES

Run from a throwaway macOS `.app` against **one** account's own private database, **Development** environment. Each subscription was saved and then read back with `allSubscriptions()`, because a subscription can save while the server silently strips the fields that make its push visible — which reads as success and behaves as failure.

| Shape | Saved | Server stored |
| --- | --- | --- |
| query / create / silent | accepted | `contentAvailable=true` |
| query / create / **visible** | accepted | `alertBody="Attention"  mutableContent=true` |
| query / **update** / **visible** | accepted | `alertBody="Attention"  mutableContent=true` |
| database subscription / visible | accepted | `alertBody="Attention"  mutableContent=true` |

**The private database does not carry the public database's restriction.** `firesOnRecordUpdate` combined with a visible mutable-content push — rejected with `BAD_REQUEST` on the public database, and the sole reason the `Ack` record type exists — is accepted here and stored intact. A `CKDatabaseSubscription` keeps the visible fields too, so the feared "silent-only" outcome did not materialise and a fallback exists either way.

**What this run did not establish** — server acceptance is necessary, not sufficient. All of
it was answered later the same day by the two-account spike recorded below; the list is kept
so it is clear what this probe alone could and could not show.

- **Delivery.** Whether APNs actually delivers, and whether a banner renders with the app
  force-quit. → answered under *question 2* below.
- **A participant's write**, rather than the zone owner's own. This probe confirmed only
  that such a subscription can exist on your own private database. → answered under
  *question 1* below.
- **Questions 3 and 4**, untouched here because both need a second Apple ID. → answered
  under *questions 3 and 4* below.

**Development only.** That caveat is the one thing here that still stands, and it stands for
every result in this document. Production has refused things Development allows before,
which is the entire reason for the `schema-seed` dance in CLAUDE.md.

### Spike result, 2026-09-02 — questions 3 and 4: the handshake holds

Run with two Apple IDs: an iOS Simulator signed into the second account owning the zone, a
physical device on the first account joining. A throwaway app with its own bundle ID, so
the production install was never touched.

**Q3 — programmatic acceptance needs no consent UI. Confirmed.**
`CKFetchShareMetadataOperation` returned metadata and `CKAcceptSharesOperation` succeeded,
both from code, and **iOS showed no sheet of its own**. So step 4 of the handshake can be
invisible, and the "one tap, one scan" claim above survives.

**Q4 — the owner's identity is readable from the share. Confirmed.**
`metadata.share.owner.userIdentity.userRecordID` came back populated, with
`nameComponents` present too. That is what lets B invite A back by identity rather than by
a typed email address, which was the objection that sank the earlier design.

**Two gaps inside those answers**, both worth closing before the handshake is built:

- The share tested was **link-based** (`publicPermission = .readWrite`), which is what the
  *first* share in the handshake uses. The *second* share is invited to a named
  participant, and whether accepting **that** is equally headless is untested.
- Q4 confirms the identity can be *read*. Creating a share that **invites** by that
  `userRecordID` is a separate call and has not been exercised.

### Spike result, 2026-09-02 — question 1: the inbox model works

**A participant's write into the owner's zone fires the owner's private-database
subscription. Confirmed**, in both directions, between two Apple IDs.

This is the load-bearing one. The whole reason for inbox zones rather than outbox zones is
that the receiver subscribes to their *own* private database, which is better-trodden
ground than a participant observing someone else's zone. That now rests on an observation
rather than an assumption.

Note for whoever builds this: **both sides need their own subscription.** A push arrives
only if the *receiving* side has registered one on its own zone; registering on one side
produces a working write and no notification, which looks like a delivery failure and is
not.

No banner appeared while the receiving app was in the foreground, which is correct rather
than a partial result — iOS suppresses banners for the foreground app unless it implements
`userNotificationCenter(_:willPresent:)`. The push was delivered; it simply was not drawn.

### Spike result, 2026-09-02 — question 2: the banner survives a force-quit

**A visible push generated by a private-zone subscription is delivered and renders a banner
with the receiving app force-quit. Confirmed on a physical device.**

This was the question that could have sunk the design. The app's whole purpose is that a
partner finds out immediately, and that property depends on a banner appearing when the app
is not running. It does.

The banner carried the subscription's static `alertBody`. That is the expected shape: in
production the notification service extension rewrites it with the sender's name, which the
shipping app already demonstrates works on alert pushes. What the spike had to establish
was that a push arrives and draws at all, and it does.

**The public-database trigger-record fallback is therefore not needed.** It was the
concession to be made if this answered badly, and it would have cost the metadata privacy
that motivates the whole move.

### Consequence: the `Ack` record type can go — acknowledging does not change

Worth stating plainly, because the name invites the opposite reading: **`Ack` is not the
acknowledgement.** The acknowledgement lives on the `Alert` record — `state` becomes
`acknowledged`, with `acknowledgedAt` and `ackEmoji` beside it — and `CloudKitService`
already says so in as many words: *"Source of truth for the in-app indicator remains the
Alert update above; the Ack record exists purely to trigger the visible banner."*

The `Ack` record is a duplicate written immediately afterwards for one reason: a
`firesOnRecordCreation` subscription can carry a visible push, and the public database
refuses the same thing on record *update*. It is a workaround wearing the feature's name.

So the acknowledge button, the emoji, the sender's banner and the status pill all stay.
What goes is a second write per acknowledgement and a record type that is never garbage
collected, along with `outgoing-ack-v2`, its predicate in `SubscriptionPredicates`, and the
`outgoingAckSubscriptionUnavailable` diagnostic plumbing that exists to report when that
subscription fails to register.

**The replacement is not "subscribe to any `Alert` update".** `markAlertSeen` also updates
the `Alert`, so an unfiltered update subscription would fire a banner when the partner
merely *looked* at the alert. The predicate has to be `state == "acknowledged"` — which is
exactly what the abandoned v1 attempt used. v1 was not wrong; it was rejected for the
visible-push-on-update rule that the spike has now shown does not apply here.

## Versioning

**2.0.0.** The first release since 1.0.0 that is not drop-in:

- `PairState` (`attention.pair.v1`) becomes meaningless; every existing user re-pairs.
- The invite payload changes shape, so a 1.7 device cannot read a 2.0 invite or the reverse.
- Records move databases, so 1.7 and 2.0 devices are invisible to each other.

`CURRENT_PROJECT_VERSION` stays at `1` — Xcode Cloud assigns the build number at archive time.

### Migration: hard cutover

Accepted deliberately. The current user base is small and known personally, so a forced re-pair with a spoken explanation is cheap, and getting the architecture right before a public release is worth more than a seamless upgrade for a handful of people.

2.0 drops public-database support outright. On first launch it invalidates the existing pair and prompts re-pairing, and says so plainly rather than appearing to work while doing nothing.

**History** is read from the public database once, at first launch, before anything is torn down, and kept as a local snapshot rendered alongside new records. Not replayed into the zones: it predates the encryption key's role as a content boundary, and re-uploading plaintext-derived records into the new model to preserve a list of past button presses is not worth the dedupe and ordering problems it creates.

## Surface that changes

`CloudKitService` is roughly fifteen methods, every one against `publicDB`.

| Area | Today | Under this plan |
| --- | --- | --- |
| Pairing | `createPair` / `fetchPair(pairKey:)` / `joinPair` — queryable `pairKey` lookup | Zone creation, two `CKShare`s, programmatic accept |
| Alerts | `sendAlert` / `markAlertSeen` / `acknowledgeAlert` on `publicDB` | Same shapes, written into the recipient's inbox zone, sealed |
| History | `fetchRecentAlerts(pairKey:)` | Zone-scoped fetch, plus the local pre-2.0 snapshot |
| Subscriptions | Four `CKQuerySubscription`s keyed on `pairKey` | Per the spike; own-private-database for the critical path |
| NSE | Fetches the `Alert` by record ID from `publicDB` | Must reach the private zone and hold the key — the key has to be readable from the App Group, which makes **Keychain rather than UserDefaults** the right home for it |
| Schema | `cloudkit-schema.ckdb`, three public record types | Private zones; `_icloud` grants stop being the control |

Also affected: `PairState` (new shape, per-direction state, key in Keychain — it currently imports `Security` only for `SecRandomCopyBytes` and stores everything in UserDefaults), `SubscriptionPredicates`, `AppState.bootstrap` (the DEBUG `schema-seed` dance is public-database-specific), `SETUP.md`, and `Tools/AttentionCLI` (issue #60).

Probably unaffected: the watch, which never talks to CloudKit and goes through `WatchBridge`.

## Debugging after the cutover

In Production, private-database data is invisible to the developer. After 2.0 the author can read their own pair and nothing else — and with layer 2, even a leaked record is ciphertext.

This is the same property as the fix, not a side effect of it: the author's ability to read any pair existed *because* every authenticated client could. There is no arrangement that keeps one and removes the other.

Replacements, for which the codebase already has a precedent in `SharedSettings.outgoingAckSubscriptionUnavailable` / `outgoingAckSubscriptionFailureReason`:

1. **User-side diagnostics export** — account status, zone and share state per direction, subscription registration results, recent alert state transitions with timestamps but no content, captured errors, app and build version.
2. **A two-account test pair** owned by the developer, as the primary development loop.
3. **`os_log` / sysdiagnose**, already structured and already `.public` on CloudKit error descriptions.
4. **`Tools/AttentionCLI` becomes coherent** — it can only ever act as the developer's own account against the developer's own data, rather than being a tool capable of reading everyone's. That argues for repairing it rather than deleting it.

**The diagnostics export is a prerequisite, not a follow-up.** Once 2.0 ships there is no other way to see a field failure.

## Work order

1. ~~**Spike the four questions above.**~~ **Done, 2026-09-02.** All four answered favourably, so nothing structural is blocked any more.
2. **Diagnostics export.** Independent of the spike, so it can run in parallel. Land it first so it is exercised on a known-good build.
3. `PairState` v2: per-direction state, key in Keychain, App-Group readable for the NSE.
4. ~~Crypto layer — HKDF, seal/open, hashed lookup value — with tests.~~ **Done** (`Shared/PairCrypto.swift`). Not yet wired into any record path; that lands with step 7.
5. First-launch read of pre-2.0 public history into a local snapshot.
6. Zone creation, both shares, programmatic accept, the half-formed state; rewrite `PairingService`.
7. Rewrite `CloudKitService` against inbox zones.
8. Subscriptions and NSE, per the spike.
9. Re-pair UI and cutover messaging.
10. Schema file, `SETUP.md`, `CLAUDE.md`.
11. `MARKETING_VERSION` → 2.0.0.
12. **Tester notes.** Last, once the user-facing behaviour has stopped moving.

Step 12 is a tracked file rather than a manual App Store Connect step: Xcode Cloud picks up `TestFlight/WhatToTest.<locale>.txt` from the project root and shows it as the build's "What to Test" in TestFlight. For this repo that means `TestFlight/WhatToTest.en-US.txt`, which does not exist yet. Locale-suffixed siblings are supported if it is ever worth translating, and `ci_scripts/ci_post_clone.sh` could generate the file instead if the notes ever need to be derived from the build — neither is needed here.

The note has to cover two things a 2.0.0 tester cannot discover on their own:

- **Their existing pair is gone and they must re-pair.** Both partners need to be on 2.0 before it will work, so the note should say that explicitly rather than leaving someone to conclude the app is broken.
- **What to actually exercise**, which is the half-formed state above as much as the happy path: pair, send both directions, acknowledge, check history, and confirm a banner still arrives with the app force-quit.

Note also that `CLAUDE.md` and `SETUP.md` both currently describe "What to Test" as a separate optional field in App Store Connect. That is true of the App Store Connect UI but misses the tracked-file route, so both need correcting alongside step 10.

Steps 2, 3 and 5 are independent of the spike and can proceed alongside it. Steps 6 onward are not.
