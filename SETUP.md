# Setup Checklist

Exact step-by-step from zero to two paired phones running the app via TestFlight. Do these in order.

## 0. Prerequisites

- [ ] Mac with **Xcode 15+** installed
- [ ] **Apple Developer Program** membership ($99/yr) — required for CloudKit, push, App Groups, TestFlight
- [ ] Both target **iPhones on iOS 17+**, signed in to their own Apple IDs
- [ ] Both Apple IDs (or just yours, if you're inviting your partner as an external tester) accessible to add as TestFlight testers
- [ ] Optional: Apple Watch on watchOS 10+ paired to phone A and/or B
- [ ] Install XcodeGen: `brew install xcodegen`

## 1. Get the code and pick a bundle prefix

- [ ] `git clone <this repo>` and `cd i-need-attention`
- [ ] Decide on a bundle prefix you control. Example: `com.yourname.attention`
- [ ] Find/replace `com.example.attention` → your prefix in every file. The fastest way is a single global replace across the repo (it's safe — the string only appears in meaningful places):
  ```sh
  grep -rl "com.example.attention" . | xargs sed -i '' 's/com\.example\.attention/com.yourname.attention/g'
  ```
  Files it will touch:
  - `project.yml` (bundle ID prefix + all 4 `PRODUCT_BUNDLE_IDENTIFIER` entries)
  - `App/Attention.entitlements` (iCloud container + App Group)
  - `NotificationService/NotificationService.entitlements` (iCloud container + App Group)
  - `Shared/Constants.swift` (`cloudKitContainerID` + `AppGroup.identifier`)
  - `App/AppState.swift`, `App/Services/PushNotifications.swift`, `App/Services/CloudKitService.swift`, `App/Services/PairingService.swift`, `App/Services/WatchBridge.swift` (Logger subsystem strings — don't break anything if left as-is, but update for cleanliness)
  - `Watch/Watch/Info.plist` (`WKCompanionAppBundleIdentifier`)
- [ ] `xcodegen generate`
- [ ] `open Attention.xcodeproj`

## 2. Register identifiers in Apple Developer Portal

Go to <https://developer.apple.com/account/resources>.

**App IDs** → Identifiers → **+**:
- [ ] `com.yourname.attention` — enable: Push Notifications, iCloud (with CloudKit), App Groups, Communication Notifications, Time Sensitive Notifications
- [ ] `com.yourname.attention.notification-service` — enable: iCloud (with CloudKit), App Groups, Time Sensitive Notifications
- [ ] `com.yourname.attention.watchkitapp` — no extra capabilities
- [ ] `com.yourname.attention.watchkitapp.widget` — no extra capabilities (this is the watch face complication extension)

**iCloud Container** → Identifiers → iCloud Containers → **+**:
- [ ] Create `iCloud.com.yourname.attention`
- [ ] Edit the two App IDs above and assign this container to both

**App Group** → Identifiers → App Groups → **+**:
- [ ] Create `group.com.yourname.attention`
- [ ] Edit both App IDs (main app + notification service) and assign this App Group to both

## 3. Configure signing in Xcode

For **each** of the four targets (`Attention`, `AttentionNotificationService`, `AttentionWatch`, `AttentionWatchWidget`):
- [ ] Open the target → **Signing & Capabilities**
- [ ] Check **Automatically manage signing**
- [ ] Select your **Team**
- [ ] Verify the **Bundle Identifier** matches what you registered above
- [ ] Verify the right capabilities are present (Xcode usually pulls these from the entitlements file automatically)

## 4. Set up the CloudKit schema

The schema is defined in `cloudkit-schema.ckdb` at the repo root. Import it instead of creating record types by hand.

Go to <https://icloud.developer.apple.com/dashboard> → select your container → **Import Schema…** (left sidebar, bottom section).

- [ ] Click **Import Schema…** and upload or paste the contents of `cloudkit-schema.ckdb`
- [ ] If the import fails due to an existing schema conflict (e.g. you already created `Pair` manually), click **Reset Environment…** first (development only — no data loss since you haven't used the app yet), then import again

> **If it fails with "invalid attempt to delete cloudkit managed record type":** importing *replaces* the whole development environment, so any record type CloudKit manages for itself has to be in the file or the import reads as a request to delete it. `cloudkit-schema.ckdb` carries `Users` and `cloudkit.share` for exactly this reason. If CloudKit ever adds another one, don't guess at its declaration — click **Export Schema**, copy the managed blocks out of the export verbatim, and paste them into the file.
- [ ] Under **Record Types** you should see seven: `Alert`, `PairProfile`, `AlertStatus`, the two pre-2.0 leftovers `Pair` and `Ack`, and CloudKit's own `Users` and `cloudkit.share`
- [ ] Under **Indexes**, verify `Alert.recordName` shows `QUERYABLE` — from 2.0 both alert reads enumerate a whole zone rather than filtering on `pairKey`, and CloudKit refuses that without this index. Symptom if it's missing: pairing works, alerts are written fine, and the receiver shows **All quiet** forever
- [ ] Under **Indexes**, verify `AlertStatus.state` shows `QUERYABLE` — the subscription that delivers the "they got back to you" banner filters on it, and without the index that banner silently never arrives

### What 2.0 changed here, and what it means for this page

From 2.0 the app's records live in **per-user private database zones**, not in the public database. Each person owns one zone and shares it with their partner, so access is enforced by CloudKit per zone rather than by a lookup value everyone can read. Two consequences for setup:

- **Security roles barely matter any more.** They apply to the public database, and the app now writes nothing there. What remains is the one-time read of pre-2.0 history on first launch after upgrading, which needs `_icloud: Read` on `Alert` to keep working. Leave `_world` with **no permissions at all** — it was the hole that made every pair's `pairKey` readable by an unauthenticated client, and nothing needs it.
- **Private-zone record types still have to be deployed.** Development is what Xcode debug builds use; TestFlight and release builds use Production, which is schema-locked. Run a Debug build once, pair it, then deploy.

- [ ] Click **Deploy Schema Changes…** and promote to **Production** before shipping to TestFlight

> **Push on Debug builds:** `aps-environment` must match the CloudKit environment the build talks to — sandbox APNs for Development, production APNs for Production. `App/Attention.entitlements` takes it from `APS_ENVIRONMENT` in `project.yml` (`development` for Debug, `production` for Release), so this is handled. Don't hardcode it: a token minted for the wrong environment produces no error and no delivery, so pushes just never arrive while every in-app read keeps working.
>
> A consequence worth knowing before you go looking for a bug: development and production APNs are **two separate networks that don't interoperate**. Both work, but a Debug device on your desk will never see a push triggered by a TestFlight build, or vice versa. Test one pair of builds against each other, not a mix.

> **Unverified, and the most likely thing to bite you:** pre-2.0 the app carried a DEBUG-only seeder that made CloudKit auto-create a `_sub_trigger_<subscriptionID>` record for each subscription, because Production rejects schema mutations from devices and would otherwise refuse every new subscription ID with `BAD_REQUEST`. That seeder wrote to the public database and has been removed. Whether private-zone query subscriptions need the same Development-then-deploy dance is **not something this repo has confirmed**. If TestFlight builds come up with no pushes and Console shows `SubscriptionCreate` rejections, that is what happened: register the subscriptions once from a Debug build on a device, then **Deploy Schema Changes…** again.

### Recovering pre-2.0 history on one device

The migration is a one-shot, and it is scoped per CloudKit environment — a Debug build reads Development, where an upgrading user has no history, and a Release build reads Production, where they do. That scoping keeps the two from spending each other's turn, but it doesn't help a device whose capture already ran against the wrong one before the scoping existed.

For that device there's a Debug-only **Settings → Debug → Recover pre-2.0 history**:

- [ ] Read the pair key off the `Pair` record in CloudKit Dashboard (Production → Public Database)
- [ ] Point the build at the environment holding those records — for pre-2.0 history that's Production. The key is **not** in `App/Attention.entitlements` by default; **add** it:

      ```xml
      <key>com.apple.developer.icloud-container-environment</key>
      <string>Production</string>
      ```

- [ ] Run on the device, open **Settings** from the gear on the pairing screen, paste the key under **Debug**, tap the button
- [ ] **If the pair ever re-paired before 2.0, repeat with each key.** Each pre-2.0 pairing minted its own `pairKey` and the fetch filters on exactly one, so a history spanning several pairings needs one run per key. Recovery merges, so runs accumulate. To find the other keys: query `Alert` sorted by `createdTimestamp` **ASC** and read the `pairKey` off the oldest rows — it will differ from the newest ones. (The `Pair` record itself can't be listed: it has no sortable field and no `recordName` index, and Production schema is read-only.)
- [ ] `git restore App/Attention.entitlements` to remove the key again
- [ ] **Rebuild and re-run on the device.** Entitlements are baked into the binary, so the phone keeps talking to Production until you do — which looks like `Share not found` when it tries to accept a share minted in Development. Re-running from Xcode replaces the binary and keeps the app container, so the recovered archive survives; *deleting* the app is what would destroy it.

It reads and writes locally and deletes nothing; the archive is written to both the Development and Release paths so a later TestFlight build finds it too.

> While that override is in place the build is a mismatched pair: Production CloudKit data, but a **development** APNs token (`APS_ENVIRONMENT` follows the build configuration, not the container override). Reads and writes work, pushes don't. That is expected for this procedure — it only reads — so don't chase the silence. It also means such a build can't usefully pair: it would be writing into the Production container that your partner's TestFlight build uses, which is the last place you want a test pairing.

## 5. First build directly to a phone (sanity check before publishing)

- [ ] Plug **iPhone A** into the Mac, unlock it, tap **Trust** when prompted
- [ ] In Xcode device picker (top bar), select iPhone A
- [ ] Scheme: **Attention** → **Cmd-R** (build & run)
- [ ] On the phone: Settings → General → VPN & Device Management → trust your developer certificate (first time only)
- [ ] Reopen the app, grant notification permission when asked
- [ ] Repeat with **iPhone B**

If you hit "couldn't find provisioning profile" — go back to Signing & Capabilities, untick + retick "Automatically manage signing", then try again.

## 6. Pair the two phones

**In person (QR):**

- [ ] On phone A: tap **Show Code**, leave it on screen
- [ ] On phone B: tap **Scan Code**, point camera at phone A
- [ ] Both phones flip to the main button screen with "paired with \<name\>" at the bottom
- [ ] Smoke test: tap the button on A — B should buzz and show the alert; tap acknowledge on B; A's status pill should flip to ✅

**Remotely (shared link):** on phone A tap **Show Code** → **Or share the link** and send it via iMessage or AirDrop. Phone B taps the link (or copies it and uses **Got an invite link? Paste it** on the pairing screen) and confirms in the "Pair with…" sheet. Phone A completes automatically — via silent push if the app is alive, or the next time it's opened. The invite survives closing the app; an unaccepted one can be re-shared or cancelled from the pairing screen.

> Transport note: the link *is* the pairing secret. iMessage and AirDrop are end-to-end/peer encrypted — effectively as safe as the in-person QR. Plain SMS is cleartext over carrier infrastructure; avoid it.

**What "Finishing setup" means.** From 2.0 pairing is two shares, not one. Scanning gets phone B into phone A's zone immediately, and B's own share travels back over that channel with no second scan — but that return trip takes a moment, and until it lands A cannot send. So the phone that *showed* the code may sit on a "Finishing setup" screen briefly, and the phone that *scanned* may show a banner saying it can reach its partner but not yet the other way round. Both clear themselves; both offer a manual re-check. If one persists, backgrounding and reopening the app is the whole remedy.

## 6a. (Optional) Add the watch complication

- [ ] On the watch: long-press the watch face → **Edit** → swipe to **Complications** (or pick a different face that supports them)
- [ ] Tap a slot → scroll to **Attention** → done. Tapping the complication launches the watch app and immediately fires a press.

## 7. Publish privately via TestFlight

- [ ] Bump build number: in `project.yml` change `CURRENT_PROJECT_VERSION` (or edit in Xcode → target → General → Build), re-run `xcodegen generate` if you edited the YAML
- [ ] Xcode device picker → **Any iOS Device (arm64)**
- [ ] **Product → Archive**
- [ ] When the Organizer opens: **Distribute App** → **App Store Connect** → **Upload** → accept defaults → **Upload**
- [ ] Wait for the processing email (~10 min)
- [ ] Go to <https://appstoreconnect.apple.com> → **My Apps**. If "Attention" doesn't exist yet, click **+** → **New App** and fill in name, primary language, bundle ID, SKU
- [ ] Click your app → **TestFlight** tab
- [ ] Wait until the build status is **Ready to Test** (resolve any "Missing Compliance" by clicking the build → answering "No" to encryption export)
- [ ] **Internal Testing**: + group → add yourself + partner (must be added under **Users and Access** as a member of your team first), assign the build. They get an email to install via the **TestFlight** app.
- [ ] **Or External Testing**: add by email, requires a one-time short Beta App Review (~24h), then unlimited installs

## 8. Install on the phones

- [ ] Both phones: install **TestFlight** from the App Store (free)
- [ ] Open the email invite or the public link → **Accept** in TestFlight → **Install**
- [ ] Open Attention, go through pairing again (different bundle ID = fresh install, so the dev-build pairing is gone)

## 9. Optional polish (any time)

- [ ] **App icon**: drop a 1024×1024 PNG named `AppIcon-1024.png` into `App/Assets.xcassets/AppIcon.appiconset/` and update `Contents.json` to reference it (and the same for the watch asset catalog)
- [ ] **Custom sound**: a `needs-attention.caf` is already bundled in `App/Resources/` (derived from *Chord2_Rev.wav* by Aarni Koskela (akx), CC BY 3.0 Unported — see `App/Resources/SOUND_PLACEHOLDER.md` for full attribution and re-derivation steps). To replace it, drop a new `needs-attention.caf` (≤30s) in that directory and re-run `xcodegen generate`; XcodeGen includes the whole `App/Resources/` folder automatically so no manual Xcode target step is needed. If the file is absent while Custom sound is enabled in Settings, notifications will be silent (not system default) — turn Custom sound off in Settings to restore the system sound.
- [ ] **Noun presets**: edit `App/Resources/nouns.json` to change the list shown in the long-press noun picker. Format: `{ "presets": ["Hugs", "Kisses", "Some of your time"] }`. The picker also offers a **Custom…** row that takes free-form text up to 30 characters. The notification body is always `"needs <noun>"`. Title-cased presets are first-letter-lowercased before being spliced into the body so the message reads naturally.
- [ ] **Critical Alerts entitlement** *(currently disabled)*: the long-press → "Send as Critical" path was replaced with the noun picker after Apple denied the entitlement request. The wire format and `acceptCriticalAlerts` setting are kept in source (commented out in the views) so re-enabling takes only restoring those blocks. To request the entitlement again: email Apple via <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.

## 10. Updating the app later

Releases are automated via Xcode Cloud (set up in §11) — shipping is a tag push, not a manual Archive:

- [ ] Make changes, merge to `main`
- [ ] Bump `MARKETING_VERSION` in `project.yml` if this is a user-visible version bump (leave `CURRENT_PROJECT_VERSION` alone — see §11)
- [ ] `gh release create 1.2.3 --generate-notes` → Xcode Cloud archives and ships to TestFlight, which auto-notifies your testers within minutes

The manual fallback (for when Xcode Cloud is unavailable) is the §7 flow: bump the build number yourself, Xcode device picker → **Any iOS Device**, **Product → Archive**, then **Distribute App → App Store Connect → Upload**.

## 11. Releasing via Xcode Cloud (active)

**This is the live release mechanism** — every release since 1.0.0 has shipped this way. Pushing a tag fires the **Release** workflow in App Store Connect → Xcode Cloud, which regenerates the project, archives, and distributes to TestFlight. The repo ships the post-clone hook (`ci_scripts/ci_post_clone.sh`) that runs `xcodegen generate` on the build runner — without it Xcode Cloud has no project to open, since `*.xcodeproj/` is gitignored.

To ship a release:

- [ ] Merge your changes to `main`
- [ ] Bump `MARKETING_VERSION` in `project.yml` if this is a user-visible version bump
- [ ] `gh release create <version> --generate-notes` (e.g. `gh release create 1.2.3 --generate-notes`). This creates the tag and pushes it, which fires the Xcode Cloud trigger and leaves an auto-generated changelog entry on the Releases page.

Notes:

- **Release notes are auto-generated** with `--generate-notes` — the "What's Changed" PR list, as used by every release since 1.0.0. No hand-written notes needed; pass `--notes "…"` instead only for a custom one-liner. The notes are just the GitHub changelog — Xcode Cloud triggers on the tag and ignores them.

- **TestFlight's "What to Test" comes from a tracked file**, not only from the App Store Connect field. Xcode Cloud picks up `TestFlight/WhatToTest.en-US.txt` from the project root and shows it as the build's tester notes, so it is reviewed in a pull request like anything else. Editing the field in App Store Connect by hand still works and overrides nothing — the file is simply the version that travels with the code.

- **You do not need to run `xcodegen generate` locally for a release.** The build runner regenerates the project from `project.yml` on every build via the post-clone hook. Local `xcodegen` is only for building in Xcode yourself.
- **You do not bump `CURRENT_PROJECT_VERSION` (the build number).** Xcode Cloud assigns the build number at archive time; the value in `project.yml` is ignored at distribution. It sat at `1` across 1.1.0–1.2.2 without issue.
- The workflow's start condition is **Any Tags**, so any tag push triggers a build — keep tags semver (`1.2.3`) by convention.

See `docs/xcode-cloud-build-plan.md` for the full rationale and the App Store Connect workflow configuration.

## 12. Solo testing with AttentionCLI

> **Superseded by 2.0.** `pair invite` and `pair join` now fail with an explanation rather than minting invites no phone can act on. Joining means accepting a `CKShare`, which needs an iCloud entitlement a macOS `tool` target cannot embed — the same limitation tracked in issue #60, which already stopped this tool reaching CloudKit at all. The rest of this section describes the pre-2.0 tool and is kept for whoever picks up #60.

`AttentionCLI` is a macOS command-line tool that impersonates the second device of a pair. It talks to the same CloudKit container as the iOS app so the full alert → APNs → NSE → ack → status-flip loop is end-to-end real — no second phone or partner needed.

### Build

```sh
xcodegen generate
xcodebuild -scheme AttentionCLI -configuration Debug build
```

(`-configuration Debug` controls compiler optimizations and debug symbols only — it no longer affects the CloudKit environment, which is not pinned by the build.)

The binary is built with ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) — no provisioning profile or Developer Portal setup required. The CLI uses the **public** CloudKit database (same as the iOS app), so reads and writes are keyed by `pairKey` and do not require per-user iCloud authentication or container-identifier entitlements. The CloudKit environment (Development vs Production) is not explicitly pinned and can vary — confirm it using the steps below before sending alerts.

**Verify the environment before use** — Production writes trigger real push notifications to paired phones:

1. Run `attention-cli pair invite` (or `attention-cli pair status` if already paired)
2. Open [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard) → your container
3. Check **Development** first: if the Pair record appears there, the CLI is using Development. If it only appears under **Production**, it is hitting Production and any alerts will reach real devices.

The binary lands in DerivedData. To find and symlink it:

```sh
sudo ln -s "$(find ~/Library/Developer/Xcode/DerivedData -name AttentionCLI -type f -not -path '*/Build/Intermediates*' | head -1)" /usr/local/bin/attention-cli
# or without sudo into a user-writable directory:
# mkdir -p ~/bin && ln -s "$(find ...)" ~/bin/attention-cli  # add ~/bin to PATH if needed
```

### Pairing directions

**CLI as inviter, phone as joiner:**
```sh
attention-cli pair invite --name "MacPartner"
```
The CLI writes a Pair record, opens a QR PNG at `~/.attention-cli/invite.png`, and prints the payload URL. On the Debug-build phone tap **Scan Code** and point the camera at the QR. The CLI prints `Joined by <name>` within ~2 s and writes `~/.attention-cli/state.json`.

**Phone as inviter, CLI as joiner:**

On a Debug build of the app tap **Show Code**. Below the QR image a `#if DEBUG` "Copy payload" button appears. Tap it, then paste:
```sh
attention-cli pair join --payload "attention://pair?k=…"
```

### Common workflows

```sh
# Show current pair state
attention-cli pair status

# Watch for incoming alerts and acks (Ctrl+C to stop)
attention-cli watch

# Send an alert from the Mac to the phone
attention-cli send --message "needs attention"

# Acknowledge the most recent incoming alert
attention-cli ack --emoji ❤️

# Dump pair record + last 10 alerts + last 10 acks
attention-cli inspect

# Tear down the pair
attention-cli pair forget
```

---

## Common gotchas

- **"No matching subscription found" or pushes don't arrive**: forgot to add the **Queryable** index on `pairKey`/`senderDeviceID` in CloudKit Dashboard. Go fix it, then re-pair (the app re-creates subscriptions on pair).
- **CloudKit works in debug but not in TestFlight**: you forgot to **Deploy Schema to Production**.
- **Settings → Diagnostics shows "Acknowledgement push: Unavailable" after a clean schema import**: the `_sub_trigger_<subscriptionID>` index is missing from Production. These aren't in `cloudkit-schema.ckdb` — CloudKit auto-creates them the first time a Debug build saves the subscription against Development. Run a Debug build on a real device once, then **Deploy Schema Changes…** again (the diff will now include the trigger). The captured CKError shown beneath the row should clear on next launch.
- **Long-press menu doesn't show "Send as Critical" anymore**: intentional — the long-press now opens the noun picker (Apple denied the Critical Alerts entitlement, so the option no longer functioned). The Critical Alerts toggle in Settings is also commented out for the same reason. To re-enable, restore the commented-out blocks in `App/Views/SettingsView.swift`, `App/Views/AttentionButton.swift`, `App/Views/StatusIndicatorView.swift`, `Watch/Watch/WatchStatusPill.swift`, and `App/AttentionApp.swift`.
- **Pairing QR scan does nothing**: camera permission was denied. Settings → Attention → Camera → On.
- **Watch button does nothing when phone is off**: the watch queues the press via `transferUserInfo` and the iPhone sends the alert when it next wakes. Expected.
