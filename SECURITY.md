# Security Policy

This is a personal-use app paired in person by QR scan, or remotely by an invite link.

**Be aware of what the `pairKey` is and isn't.** It is a 128-bit random value that identifies a pair, and the app treats it as a lookup key. It is **not** an access control. All records live in CloudKit's *public* database, where security roles are granted per record type with no row-level scoping — so one grant covers every record of that type. **Any authenticated iCloud client** that can reach the container reads all of them, and the `pairKey` is itself a readable field on the Pair record, so knowing a pairKey is not required to read one.

The schema in `cloudkit-schema.ckdb` grants `_world` (unauthenticated) nothing, so anonymous reads are not possible against a container deployed from it. Check this in CloudKit Dashboard for any container you operate — a schema file does not configure a live container, and one set up earlier may still carry the grant.

`_icloud` (authenticated) read and write remain, because every device running the app is a signed-in iCloud client and the app cannot work without them. Closing that gap means moving off the public database. It is planned, not done.

## Reporting a vulnerability

If you find a security issue, **please don't open a public GitHub issue.** Instead, use one of:

- GitHub's [private vulnerability reporting](../../security/advisories/new), or
- Email the maintainer at `timfall+github@gmail.com`.

I aim to acknowledge within a few days and to ship a fix within two weeks for anything that exposes user data, or that widens access beyond what this document describes.

## Scope

In scope:

- Anything that lets a party with no CloudKit access to this container read or write into a pair.
- Anything that widens what a signed-in iCloud user can reach beyond what the public-database design already permits (documented above — please don't report that as new).
- Anything that lets a paired device escalate beyond the documented send / receive / acknowledge surface.
- Bypasses of the user-controlled toggles for critical alerts and sender-side acknowledgement banners.

Out of scope:

- App Store distribution issues (the app is TestFlight-only and is not intended for the App Store).
- Server-side CloudKit availability, rate-limiting, or quota issues — that's Apple's surface.
- Issues that require physical access to an unlocked device.
- Social-engineering attacks on the in-person QR exchange (the threat model assumes pairing happens between two trusted humans in the same room).
