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
- [ ] `com.yourname.attention.notification-service` — enable: iCloud (with CloudKit), App Groups
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
- [ ] After import, click **Security Roles** in the left sidebar and verify:
  - `_world`: **Read** only for `Pair` and `Alert` (CloudKit does not allow World Write — this is correct)
  - `_icloud`: **Create + Read + Write** for `Pair` and `Alert` — set manually if missing (both phones are always signed into iCloud so this is the effective write gate; the pairKey is the access secret)
- [ ] Click **Deploy Schema Changes…** and promote to **Production** when you're ready to ship to TestFlight (development environment is what Xcode debug builds use; TestFlight/release builds use production).

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
- [ ] **Custom sound**: drop a `needs-attention.caf` (≤30s) into `App/Resources/` and add it to the Attention target. See `App/Resources/SOUND_PLACEHOLDER.md` for `afconvert` usage.
- [ ] **Critical Alerts entitlement**: only needed if you want pings flagged via long-press → "Send as Critical" to actually pierce silent mode. Email Apple via <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>, expect a few days. Until granted, criticals fall back to Time-Sensitive (which still bypasses Focus).

## 10. Updating the app later

- [ ] Make changes
- [ ] Bump build number
- [ ] Archive → upload → TestFlight auto-notifies your testers within minutes

---

## Common gotchas

- **"No matching subscription found" or pushes don't arrive**: forgot to add the **Queryable** index on `pairKey`/`senderDeviceID` in CloudKit Dashboard. Go fix it, then re-pair (the app re-creates subscriptions on pair).
- **CloudKit works in debug but not in TestFlight**: you forgot to **Deploy Schema to Production**.
- **"Accept Critical Alerts" toggle does nothing**: either Apple hasn't granted the entitlement yet, or the receiver phone never actually granted Critical Alert permission in the iOS notification permission dialog. Settings → Notifications → Attention → toggle Critical Alerts.
- **Pairing QR scan does nothing**: camera permission was denied. Settings → Attention → Camera → On.
- **Watch button does nothing when phone is off**: the watch queues the press via `transferUserInfo` and the iPhone sends the alert when it next wakes. Expected.
