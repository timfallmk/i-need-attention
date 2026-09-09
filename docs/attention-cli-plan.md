# AttentionCLI — Mac dev tool for solo testing

> **Status: predates 2.0.** `AttentionCLI` still speaks the pre-2.0 public-database protocol and cannot complete a 2.0 pairing, so the record shapes, subscription IDs (`incoming-alerts-v1`, `outgoing-status-v1`, `outgoing-ack-v2`, `pair-updates-v1`) and flows described below no longer match the app. Kept as the design record; the tool needs rewriting against private zones before it is useful again.

> **Note:** This document describes the original planned signing approach (provisioning profile + entitlements with `$(CLOUDKIT_ENV)` substitution). The implementation was changed: macOS `tool` targets cannot embed provisioning profiles, so the CLI uses ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) with no entitlements instead. CloudKit environment is no longer pinned by build config. See `SETUP.md` §12 for the actual build and verification steps.

Future reference for a signed macOS command-line tool that impersonates the second device of a pair so the alert + ack flow can be exercised solo, without a partner.

## Context

Day-to-day verification of alert flows currently requires both phones and a willing partner. That blocks iteration on the send/ack/NSE-banner/watch-complication paths whenever the partner isn't available.

A signed macOS command-line tool can impersonate the second device of a pair, talking to the same CloudKit container as the iOS app. With it, a developer running a Debug build on one phone pairs with the CLI on their Mac and exercises the full alert + ack loop end-to-end — real APNs delivery, real NSE rendering, real lock-screen and watch behavior — with no second phone or partner.

**Out of scope:** critical alerts. After Apple denied the Critical Alerts entitlement, the button's long-press affordance was repurposed from "Send as Critical" to the noun picker (see `App/Views/AttentionButton.swift` and the SETUP.md note in "Common operations"). The receiver-side toggle in `App/Views/SettingsView.swift` and the critical branches in `App/Views/StatusIndicatorView.swift` / `Watch/Watch/WatchStatusPill.swift` remain commented out so re-enabling is mechanical if the entitlement is ever granted. `AppState.sendAttention` is always called with `critical: false`. The `critical` wire field is preserved on records for forward-compat but the phone never renders critical even when set. The CLI will not expose a `--critical` flag — there's nothing on the phone side to test against.

**Security model:** The `pairKey` is the entire trust boundary in the existing app — anyone with it can read/write any pair record (sender/recipient device IDs are plaintext fields, no per-device signature). The CLI inherits that capability. Two layers protect against accidentally hitting the real production pair:

1. **CloudKit environment pinning via build config.** The CLI's entitlement uses a `$(CLOUDKIT_ENV)` substitution; `project.yml` sets `CLOUDKIT_ENV: Development` for Debug builds and `Production` for Release builds. The default workflow — `xcodebuild -scheme AttentionCLI -configuration Debug build` — resolves to Development with no extra flags, and Production requires switching the configuration explicitly (or, in a pinch, overriding the setting on the command line). The setting lives in the versioned `project.yml`, so the default-on-Development behavior is reproducible across machines without anyone needing to remember a flag.
2. **Apple's container ownership gating.** The container `iCloud.com.timfallmk.attention` is owned by the team configured as `DEVELOPMENT_TEAM` in `project.yml` (`T5VJ9JRCNB`). Only signed binaries from that team can claim the entitlement, so a stranger cannot snoop or impersonate.

## Approach

### 1. New target in `project.yml`

Add an `AttentionCLI` target alongside the four existing ones (after the existing `AttentionWatchWidget` target):

```yaml
AttentionCLI:
  type: tool
  platform: macOS
  deploymentTarget: "14.0"
  sources:
    - path: Tools/AttentionCLI/Sources
    - path: Shared
    - path: App/Models/PairState.swift
    - path: App/Models/AlertRecord.swift
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.timfallmk.attention.cli
      CODE_SIGN_STYLE: Automatic
      CODE_SIGN_ENTITLEMENTS: Tools/AttentionCLI/AttentionCLI.entitlements
      MACOSX_DEPLOYMENT_TARGET: "14.0"
    configs:
      Debug:
        CLOUDKIT_ENV: Development
      Release:
        CLOUDKIT_ENV: Production
```

`CLOUDKIT_ENV` is a custom build setting; Xcode substitutes `$(CLOUDKIT_ENV)` references in the entitlements file at build/sign time. The setting lives only on the AttentionCLI target so it doesn't affect the existing four targets.

Add a separate scheme for the CLI so it has its own run/archive entry. The existing `Attention` scheme already enumerates its build targets explicitly, so it won't pick up the new target on its own — the separate scheme is for convenience, not isolation:

```yaml
AttentionCLI:
  build:
    targets:
      AttentionCLI: all
  run:
    config: Debug
  archive:
    config: Release
```

### 2. Entitlements at `Tools/AttentionCLI/AttentionCLI.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.timfallmk.attention</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.icloud-container-environment</key>
    <string>$(CLOUDKIT_ENV)</string>
</dict>
</plist>
```

The `$(CLOUDKIT_ENV)` placeholder is resolved by Xcode at build time from the per-config build setting in `project.yml` above. Debug → `Development`, Release → `Production`. The file itself never needs editing. No App Group — the CLI doesn't share state with an NSE.

**App Sandbox is intentionally not enabled.** macOS CloudKit works for non-sandboxed binaries signed by the team that owns the container, which is what automatic signing produces here. Leaving the tool unsandboxed lets it write its state to `~/.attention-cli/` directly — inspectable from a regular shell rather than buried under `~/Library/Containers/...`. App Store distribution would force enabling `com.apple.security.app-sandbox` and relocating state into `applicationSupportDirectory`, but App Store distribution is explicitly out of scope per `CLAUDE.md`.

### 3. CLI implementation under `Tools/AttentionCLI/Sources/`

Files:

- `main.swift` — argv parsing + subcommand dispatch. Hand-rolled (matches: zero existing SwiftPM deps; project is XcodeGen-only).
- `CLIState.swift` — JSON-backed state at `~/.attention-cli/state.json` storing `{pairKey, myDeviceID, myName, partnerDeviceID, partnerName}`. Same shape as `PairState` in `App/Models/PairState.swift` but persisted to a file rather than UserDefaults so it doesn't surprise the Mac. The path assumes the unsandboxed entitlements above; if the CLI is ever sandboxed for distribution, switch to `FileManager.default.url(for: .applicationSupportDirectory, ...)`.
- `CLIClient.swift` — slim CloudKit wrapper. Mirrors the relevant methods of `App/Services/CloudKitService.swift` (which only imports CloudKit + Foundation + os.log — Mac-compatible) but cuts subscription registration. Methods:
  - `createPair(invite:)` — write Pair (mirror existing `CloudKitService.createPair`)
  - `fetchPair(pairKey:)` — query Pair (mirror existing)
  - `joinPair(record:joinerDeviceID:joinerName:)` — fill `deviceB`/`nameB` with `ifServerRecordUnchanged` save policy (mirror existing)
  - `sendAlert(pairKey:senderDeviceID:senderName:message:)` — mirror existing minus the `critical` parameter (always writes `critical: 0`)
  - `markAlertSeen(recordID:)` — mirror existing
  - `acknowledgeAlert(recordID:emoji:)` — write Alert state + Ack record (mirror existing two-write behavior)
  - `pollIncomingAlerts(pairKey:myDeviceID:since:)` — query Alert with predicate `pairKey == X AND senderDeviceID != Y AND creationDate > since`, sorted desc
  - `pollIncomingAcks(pairKey:myDeviceID:since:)` — query Ack with predicate `pairKey == X AND recipientDeviceID == Y AND creationDate > since`, sorted desc
- `Commands/` — one file per subcommand below.

**Subcommands:**

| Command | Behavior |
|---|---|
| `attention-cli pair invite [--name NAME]` | Generate pairKey via `PairingInvite.generate` (`App/Models/PairState.swift`), write Pair, render QR PNG using `CIFilter.qrCodeGenerator()` (built into CoreImage — no dep) to `~/.attention-cli/invite.png`, `open` it so the phone can scan, also print payload text to stdout. Poll `fetchPair` every 2s until `deviceB` fills (mirror `PairingService.waitForJoiner`'s 120s timeout). Save state. |
| `attention-cli pair join --payload <attention://...> [--name NAME]` | Decode via `PairingInvite.from(qrPayload:)` (`App/Models/PairState.swift`), `fetchPair`, `joinPair`. Save state. |
| `attention-cli pair status` | Pretty-print state. |
| `attention-cli pair forget` | Delete state file. |
| `attention-cli send [--message TEXT]` | `sendAlert` using state. (No `--critical` flag — the entitlement is denied and the phone always falls back to time-sensitive.) |
| `attention-cli watch [--interval N]` | Loop: `pollIncomingAlerts` + `pollIncomingAcks`, print new records, sleep N (default 3) seconds. Prints-only — does not auto-mark-seen or auto-ack, so the operator drives flow explicitly. |
| `attention-cli ack [--emoji ❤️]` | `fetchMostRecentAlert` for incoming, `acknowledgeAlert`. |
| `attention-cli inspect` | Dump Pair record + last 10 Alerts + last 10 Acks for the local pairKey. |

### 4. Phone-side change (one file)

`App/Views/PairingFlowView.swift` — add a `#if DEBUG` block on the **inviter** screen: a `Text(invite.qrPayload)` (selectable) and a "Copy payload" button writing to `UIPasteboard.general`. This unblocks the phone-as-inviter, CLI-as-joiner direction without OCR'ing the QR. The reverse direction (CLI-as-inviter, phone-as-joiner) needs no phone change — the CLI generates a real QR PNG that the existing `QRScannerView` reads via camera.

### 5. Documentation

- `SETUP.md` — new "Solo testing with AttentionCLI" section: build steps, the Dev/Prod switch (`-configuration Debug` vs `-configuration Release`), the two pairing directions, common workflows, and an explicit warning that Release-config + a real pairKey will hit the real partner's phone.
- `CLAUDE.md` — one-line addition to the repo-layout block: `Tools/AttentionCLI/    macOS dev tool impersonating the second pair device for solo testing`.

## Critical files

**New:**
- `Tools/AttentionCLI/AttentionCLI.entitlements`
- `Tools/AttentionCLI/Sources/main.swift`
- `Tools/AttentionCLI/Sources/CLIState.swift`
- `Tools/AttentionCLI/Sources/CLIClient.swift`
- `Tools/AttentionCLI/Sources/Commands/*.swift` (one per subcommand)

**Modified:**
- `project.yml` — add `AttentionCLI` target + scheme
- `App/Views/PairingFlowView.swift` — `#if DEBUG` payload-as-text + copy button on inviter screen
- `SETUP.md` — new CLI section
- `CLAUDE.md` — repo-layout one-liner

## Reused functions

- `PairingInvite.generate(myDeviceID:myName:)`, `.from(qrPayload:)`, `.qrPayload` getter — `App/Models/PairState.swift`
- `PairState` Codable conformance for in-memory shape — `App/Models/PairState.swift` (CLI uses the struct but persists to its own JSON file, not UserDefaults)
- `AlertRecord.init?(record:)` for parsing fetched Alerts — `App/Models/AlertRecord.swift`
- All record types, field names, AlertState enum — `Shared/Constants.swift`
- Predicate shapes — model on existing `CloudKitService.fetchMostRecentAlert` and the four subscription predicates registered by `CloudKitService.registerSubscriptions` (incoming-alerts-v1, outgoing-status-v1, outgoing-ack-v2, pair-updates-v1)

## Verification

Prerequisites: a Mac signed into iCloud with the team's Apple ID, an iPhone running a Debug build of the app on the same iCloud account (or a paired tester account that has dev access), Xcode 15+ with provisioning set up.

1. **Build:** `xcodegen generate` succeeds without warnings. The new `AttentionCLI` scheme appears. `xcodebuild -scheme AttentionCLI -configuration Debug build` succeeds. The binary lands in DerivedData; symlink or alias it for convenience.
2. **CLI as inviter, phone as joiner:** Run `attention-cli pair invite --name "MacPartner"`. The CLI writes a Pair record, opens a QR PNG, prints the payload text. On the Debug-build phone, scan the QR. Within ~2s the CLI prints `joined by <PhoneName>` and writes `~/.attention-cli/state.json`.
3. **Phone → CLI alert:** Run `attention-cli watch` on the Mac. Press the red button on the phone. Within `--interval` seconds the CLI prints the incoming Alert (sender name, timestamp, message, critical flag).
4. **Ack from CLI:** `attention-cli ack --emoji ❤️`. The phone displays the existing "Got back to you ❤️" NSE banner (rendered by `outgoing-ack-v2` subscription firing on the Ack record write). The phone's `StatusIndicatorView` flips to ❤️.
5. **CLI → Phone alert:** `attention-cli send --message "needs attention"`. The phone receives the push, NSE rewrites the banner with the CLI's display name, ack actions appear. Tap an emoji. The CLI's `watch` prints the Ack record within the poll interval.
6. **Watch complication:** With watch paired, send from Mac. Watch face complication updates via the existing `WatchSnapshot` push from the phone.
7. **Phone as inviter, CLI as joiner:** `attention-cli pair forget`. On the Debug phone, tap Invite, use the new `#if DEBUG` "Copy payload" button. `attention-cli pair join --payload <pasted>`. State file populates; phone's pair status flips to "paired with MacPartner".
8. **Production escape hatch (handle with care):** Rebuild with `xcodebuild -scheme AttentionCLI -configuration Release` so `CLOUDKIT_ENV` resolves to `Production` and the entitlement is signed accordingly. Repeat steps 2-3 against a TestFlight build of the phone using a fresh test pair. Confirm isolation: a Debug-built CLI cannot see Pair records created by a TestFlight phone (and vice versa).
9. **`inspect`:** `attention-cli inspect` prints the Pair record and last 10 Alerts/Acks — sanity-check that field mappings match what `AlertRecord.init?(record:)` expects.

If any of 2-8 fail, common suspects: missing or stale provisioning profile for the Mac CLI bundle ID; entitlement environment mismatch between CLI and phone (e.g., Debug CLI talking to TestFlight phone); pairKey copy-paste lost a character; iCloud account mismatch between Mac and phone.
