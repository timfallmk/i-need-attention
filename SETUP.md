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
- [ ] If you previously imported an older schema, re-import to pick up the **`Ack`** record type (used by the `outgoing-ack-v2` subscription that delivers a banner to the sender when the partner acknowledges). Under **Record Types** you should see three: `Pair`, `Alert`, `Ack`. Under **Indexes** verify `Ack.pairKey` and `Ack.recipientDeviceID` both show `QUERYABLE`; add them manually if not.
- [ ] After import, click **Security Roles** in the left sidebar and verify:
  - `_world`: **Read** only for `Pair`, `Alert`, and `Ack` (CloudKit does not allow World Write — this is correct)
  - `_icloud`: **Create + Read + Write** for `Pair`, `Alert`, and `Ack` — set manually if missing (both phones are always signed into iCloud so this is the effective write gate; the pairKey is the access secret)
- [ ] **Seed subscription triggers**: in Xcode, select the **Attention** scheme + a real iPhone signed into your personal iCloud account (not the simulator), then **Cmd-R** to run. There's no separate "Debug" scheme — the Attention scheme's Run action is configured for the Debug build configuration (see `project.yml:33-34`), so Cmd-R is a Debug launch. The `#if DEBUG` block in `AppState.bootstrap()` calls `registerSubscriptions` against Development, and CloudKit auto-creates a `_sub_trigger_<subscriptionID>` record per subscription as a side effect. These aren't in `cloudkit-schema.ckdb`; they're created on first save and must exist in Production before TestFlight builds can register subscriptions (without them, `SubscriptionCreate` is rejected with `BAD_REQUEST` because Production is schema-locked). The seeded subs use placeholder predicates and are inert — they get purged automatically on the next paired Debug launch (see `CloudKitService.purgeSeededSubscriptions`), so paired Dev testing on the same device still works.
- [ ] Click **Deploy Schema Changes…** and promote to **Production** when you're ready to ship to TestFlight (development environment is what Xcode debug builds use; TestFlight/release builds use production). The first deploy after a fresh import covers the user-visible record types; the deploy *after seeding* covers the new `_sub_trigger_*` rows. Both deploys are normal — re-run **Deploy Schema Changes…** any time you add a new subscription type.

## 5. First build directly to a phone (sanity check before publishing)

- [ ] Plug **iPhone A** into the Mac, unlock it, tap **Trust** when prompted
- [ ] In Xcode device picker (top bar), select iPhone A
- [ ] Scheme: **Attention** → **Cmd-R** (build & run)
- [ ] On the phone: Settings → General → VPN & Device Management → trust your developer certificate (first time only)
- [ ] Reopen the app, grant notification permission when asked
- [ ] Repeat with **iPhone B**

If you hit "couldn't find provisioning profile" — go back to Signing & Capabilities, untick + retick "Automatically manage signing", then try again.

## 6. Pair the two phones

- [ ] On phone A: tap **Show Code**, leave it on screen
- [ ] On phone B: tap **Scan Code**, point camera at phone A
- [ ] Both phones flip to the main button screen with "paired with \<name\>" at the bottom
- [ ] Smoke test: tap the button on A — B should buzz and show the alert; tap acknowledge on B; A's status pill should flip to ✅

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

- **Release notes are auto-generated** with `--generate-notes` — the "What's Changed" PR list, as used by every release since 1.0.0. No hand-written notes needed; pass `--notes "…"` instead only for a custom one-liner. The notes are just the GitHub changelog — Xcode Cloud triggers on the tag and ignores them. TestFlight's "What to Test" is a separate, optional field in App Store Connect.

- **You do not need to run `xcodegen generate` locally for a release.** The build runner regenerates the project from `project.yml` on every build via the post-clone hook. Local `xcodegen` is only for building in Xcode yourself.
- **You do not bump `CURRENT_PROJECT_VERSION` (the build number).** Xcode Cloud assigns the build number at archive time; the value in `project.yml` is ignored at distribution. It sat at `1` across 1.1.0–1.2.2 without issue.
- The workflow's start condition is **Any Tags**, so any tag push triggers a build — keep tags semver (`1.2.3`) by convention.

See `docs/xcode-cloud-build-plan.md` for the full rationale and the App Store Connect workflow configuration.

## 12. Solo testing with AttentionCLI

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
