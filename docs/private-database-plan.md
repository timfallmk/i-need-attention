# Private Inbox Zones + Encrypted Payloads

**Status: in progress.** Supersedes "Option 3" as originally scoped (a single `CKShare`d zone owned by the inviter). This doc is the design record and the decision log.

Landed so far: the crypto layer (`Shared/PairCrypto.swift`) — layer 2 below — which is pure logic and did not have to wait on the spike. Everything structural is still unbuilt, and **the spike has not been run**, so the four questions under [What must be verified](#what-must-be-verified-before-writing-production-code) are all still open. See the [work order](#work-order) for what is done and what is not.

Target release: **2.0.0**.

## Why

#61 closed anonymous read of the public database — verified behaviourally, a Web Services query with a valid API token now returns `ACCESS_DENIED` where it previously returned every `Pair` record with its `pairKey` in plaintext.

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

Four questions. None of these are asserted anywhere above; where the design depends on an answer, that dependency is named.

1. **Does a participant's write into the owner's zone fire the owner's private-database subscription?** The whole inbox model rests on this. If it does not, the design collapses back to shared-database subscriptions and the original risk returns.
2. **Can that subscription produce a visible (mutable-content) push?** This is what lets the NSE render a banner with the app force-quit — the app's core property. The `Ack` record type exists today only because the *public* database rejects `firesOnRecordUpdate` with a visible push; whether that restriction applies to private databases is unconfirmed.
3. **Does programmatic share acceptance require user-consent UI?** Steps 2 and 4 of the handshake assume `CKFetchShareMetadataOperation` → `CKAcceptSharesOperation` works from a URL the app extracted itself. If the system insists on its own confirmation sheet, step 4 stops being invisible and the UX claim above weakens.
4. **Can B invite A by `userRecordID` learned from `share_A`'s owner?** If not, `share_B` needs a bearer URL delivered through `zone_A` — workable, but a second bearer token then exists briefly.

**Spike:** a throwaway branch, two iCloud accounts, two real devices. Question 2 is the one that can sink the approach; question 1 decides whether the inbox model is worth having at all.

If question 2 answers badly, the fallback is to keep a single content-free record in the public database purely as a push trigger — the payload is already encrypted, so a trigger record leaks only that *something* arrived. That is a meaningful concession on metadata and should be a deliberate decision, not a default.

### A simplification if 2 answers well

If visible pushes are permitted on record update in a private zone, the `Ack` record type can be deleted outright. It exists only as a public-database workaround, costing a second write per acknowledgement and a record type that is never garbage-collected. Nearly free to test in the same spike.

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

1. **Spike the four questions above.** Two accounts, two devices. Everything structural is contingent on 1 and 2. **Not run.**
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
