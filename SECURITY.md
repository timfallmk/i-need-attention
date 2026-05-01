# Security Policy

This is a personal-use app paired by QR scan in person. The only secret in the system is the per-pair `pairKey` — a 128-bit random value generated at pair time and never transmitted outside the in-person QR exchange. All CloudKit access for a pair is gated by knowledge of that key.

## Reporting a vulnerability

If you find a security issue, **please don't open a public GitHub issue.** Instead, use one of:

- GitHub's [private vulnerability reporting](../../security/advisories/new), or
- Email the maintainer at `timfall+github@gmail.com`.

I aim to acknowledge within a few days and to ship a fix to TestFlight within two weeks for anything that exposes user data or breaks the trust boundary on `pairKey`.

## Scope

In scope:

- Anything that lets a third party read or write into a pair without knowing its `pairKey`.
- Anything that lets a paired device escalate beyond the documented send / receive / acknowledge surface.
- Bypasses of the user-controlled toggles for critical alerts and sender-side acknowledgement banners.

Out of scope:

- App Store distribution issues (the app is TestFlight-only and is not intended for the App Store).
- Server-side CloudKit availability, rate-limiting, or quota issues — that's Apple's surface.
- Issues that require physical access to an unlocked device.
- Social-engineering attacks on the in-person QR exchange (the threat model assumes pairing happens between two trusted humans in the same room).
