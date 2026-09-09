# Security Policy

A two-person app with no server and no accounts. You pair with exactly one other person, in
person by QR scan or remotely by an invite link, and after that the app is a button. There is
no backend beyond Apple's CloudKit and APNs, and no operator-held credential that can read
your data.

## Where your data lives

Each person owns one **inbox zone** in their own CloudKit private database and shares it with
their partner using a zone-wide `CKShare`. You write into *their* zone; what arrives for you
lands in the zone you own. Nobody owns "the pair" — access is enforced by CloudKit per zone,
not by a value anyone can read.

The zone is per **pairing**, not per install. `InboxZone` mints a fresh name each time you
pair, and unpairing deletes the old zone. A zone-wide share grants its participant the entire
zone, so reusing a name would hand a new partner everything the previous one left behind.

## What is encrypted, and what is not

Everything human-readable is sealed before it reaches CloudKit. `Shared/PairCrypto.swift`
derives a key from the pair key with `HKDF<SHA256>` and seals each field with `ChaChaPoly`,
authenticating the destination field name so a sealed `senderName` cannot be moved into a
`message` field and still open. Sender names, message text and acknowledgement emoji are
ciphertext at rest. Apple stores bytes it cannot read, because the key never leaves the two
phones.

A record written by someone who does not hold the key fails to open at all, so hostile writes
are discarded rather than merely rendered safely.

**Structural fields stay plaintext**, because predicates and sorting need them: the sending
device's identifier, the alert's state, its timestamps, and the per-press critical flag. They
say nothing that the existence of the zone does not already say — but they are metadata, and
a participant in the zone can see them.

The pair key is **never written to CloudKit**. Where a queryable value is needed, the record
carries `PairCrypto.lookupHash` — SHA-256 over the key — instead.

## Where the key lives

The pair key is a 128-bit random value held in the Keychain (`Shared/PairSecretStore.swift`),
with the App Group as its access group so the notification service extension can decrypt
pushes. It is `kSecAttrAccessibleAfterFirstUnlock`, because the extension renders notifications
that arrive against a locked screen.

It is deliberately **synchronizable** rather than `ThisDeviceOnly`. From 2.0 the key decrypts
every payload, so a device that arrives without it cannot read history still sitting in
CloudKit, and re-pairing is not a solo recovery — it needs the partner and a fresh scan.
`CLAUDE.md` records the full reasoning.

## What this does not protect against

- **A compromised device.** The key is on both phones. That is the right place for the boundary
  in a two-person app, but it is a boundary: anyone with your unlocked device, or with your
  Keychain, can read everything.
- **Metadata within the pair.** Your partner's device can see when you asked for attention, how
  often, and whether you answered. That is inherent to the feature.
- **Apple's infrastructure availability.** Delivery depends on CloudKit and APNs.

## Records from before 2.0

Versions before 2.0 stored records in CloudKit's **public** database with human-readable
fields and no encryption, and the `pairKey` was a plaintext field on a record any signed-in
iCloud client could query. That design is gone. `Pair`, `Alert` and `Ack` remain in
`cloudkit-schema.ckdb` with `_icloud` grants and are read but never written;
`CloudKitService.purgeLegacyPublicRecords` removes the leftovers as pairs migrate. Assume
anything sent before 2.0 was readable by any authenticated iCloud client.

For the avoidance of doubt about the schema file: `GRANT READ TO "_world"` appears there only
on `Users` and `cloudkit.share`, which are Apple's own system record types — `cloudkit.share`
needs it so a share URL resolves for someone who has not accepted yet. The app's own 2.0 record
types, `PairProfile` and `AlertStatus`, carry no grants, because records in a private zone are
governed by that zone's share participants rather than by record-type roles.

## Known issues

Open and tracked rather than undisclosed. Please do not file these as new:

- **Two installs signed into one Apple ID can break each other's pairing** ([#68]). Subscription
  identifiers are constants in a per-account database, and the pair key is one synchronizable
  Keychain item. Both failures are silent. Code reading; no confirmed occurrence.
- **A watch press queued while the phone is unreachable has no expiry** ([#69]). It is delivered
  whenever the phone next wakes, against whatever pairing exists then.
- **Acknowledging an already-acknowledged alert re-pushes a banner for it** ([#70]).

[#68]: https://github.com/timfallmk/i-need-attention/issues/68
[#69]: https://github.com/timfallmk/i-need-attention/issues/69
[#70]: https://github.com/timfallmk/i-need-attention/issues/70

## Supported versions

The current App Store or TestFlight build is the only supported version. Versions before 2.0
use the public-database design described above and should not be used.

## Reporting a vulnerability

**Please don't open a public GitHub issue.** Email the maintainer at
`timfall+github@gmail.com`.

I aim to acknowledge within a few days, and to ship a fix within two weeks for anything that
exposes user data or widens access beyond what this document describes. This is a personal
project maintained by one person; that is a good-faith target, not a service commitment.

## Scope

In scope:

- Anything that lets a party outside a pairing read or write into it.
- Anything that lets a participant reach beyond the documented send / receive / acknowledge /
  snooze surface, or beyond their own zone.
- Weaknesses in the sealing scheme, the key derivation, or how the pair key is stored, shared
  or rotated.
- Anything that causes an alert to reach the wrong person, or a notification to name the wrong
  sender.
- Pairing-flow flaws: a scanned or pasted invite that joins a zone the user did not intend, or
  a share that grants more than the pairing requires.

Out of scope:

- CloudKit and APNs availability, rate limiting, and quotas — Apple's surface.
- Issues requiring physical access to an unlocked device, or possession of the Keychain.
- Metadata visible to your own partner, listed above as an accepted property.
- Social engineering of the in-person QR exchange; the threat model assumes pairing happens
  between two people who intend to pair.
- The pre-2.0 public-database design itself, which is documented above and superseded.
