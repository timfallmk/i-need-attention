# Setup Checklist

Exact step-by-step from zero to two paired devices running the app. Do these in
order. The walkthrough says "phones" throughout because that is the ordinary case and the
steps read better for it — but from 2.2.0 either end can be an iPad, or a Mac or Vision Pro
running the iPad build, and nothing in the pairing steps changes. See §7d for which
destinations are offered.

## 0. Prerequisites

- [ ] Mac with **Xcode 15+** installed
- [ ] **Apple Developer Program** membership ($99/yr) — required for CloudKit, push, App Groups, TestFlight
- [ ] Both target devices on **iOS 17+ / iPadOS 17+**, signed in to their own Apple IDs — two
      iPhones, or an iPhone and an iPad. An Apple Silicon Mac or Vision Pro counts as well:
      both run that same iPad build and need nothing extra here, but push delivery on them is
      unverified, so read §7d before either is somebody's only device. Several devices on
      *one* Apple Account pair once and are then all paired, so "both" here means two people
      rather than two pieces of hardware
- [ ] Both Apple IDs (or just yours, if you're inviting your partner as an external tester) accessible to add as TestFlight testers
- [ ] Optional: Apple Watch on watchOS 10+ paired to phone A and/or B. Genuinely phone-only —
      a watch pairs to an iPhone, and the app degrades quietly on a device that has none
- [ ] Install XcodeGen: `brew install xcodegen`

## 1. Get the code and pick a bundle prefix

- [ ] `git clone <this repo>` and `cd i-need-attention`
- [ ] Decide on a bundle prefix you control. Example: `com.yourname.attention`
- [ ] Find/replace `com.timfallmk.attention` → your prefix in every file. The fastest way is a single global replace across the repo (it's safe — the string only appears in meaningful places):
  ```sh
  grep -rl "com.timfallmk.attention" . | xargs sed -i '' 's/com\.timfallmk\.attention/com.yourname.attention/g'
  ```
  Files it will touch:
  - `project.yml` (bundle ID prefix, all 4 `PRODUCT_BUNDLE_IDENTIFIER` entries, and `WKCompanionAppBundleIdentifier` — the generated Info.plists pick these up automatically)
  - `App/Attention.entitlements` (iCloud container + App Group)
  - `NotificationService/NotificationService.entitlements` (iCloud container + App Group)
  - `Shared/Constants.swift` (`cloudKitContainerID` + `AppGroup.identifier`)
  - `App/AppState.swift`, `App/Services/PushNotifications.swift`, `App/Services/CloudKitService.swift`, `App/Services/PairingService.swift`, `App/Services/WatchBridge.swift` (Logger subsystem strings — don't break anything if left as-is, but update for cleanliness)
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

**Change `DEVELOPMENT_TEAM` in `project.yml`** to your own Team ID (developer portal →
Membership), then re-run `xcodegen generate`. The committed value belongs to the original
author and will not sign for you.

Setting the team per target in Xcode also works, but it does not survive: `*.xcodeproj/` is
gitignored and regenerated from `project.yml`, including by Xcode Cloud's
`ci_scripts/ci_post_clone.sh`. `project.yml` is the only place it stays put.


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

> **Upgrading an existing container — deploy the schema *before* anyone runs the new build.** Two fields were added for multi-device support: `Alert.senderUserID` and `PairProfile.userID`, both `String` and neither indexed. Re-import `cloudkit-schema.ckdb` into Development, then **Deploy Schema Changes…** to Production.
>
> This is a hard prerequisite rather than a nice-to-have, and it is worth being exact about why. Development infers a missing field from the first record that carries one; **Production does not — its schema is locked, and a save naming a field it does not know is rejected.** From 2.2.0 the app writes `senderUserID` on every alert and `userID` on every profile, so against an undeployed Production container the failure is not "multi-device doesn't work": it is sending and pairing failing outright, with a CloudKit error the user sees as the alert not going through.
>
> Additive is still true in the direction that matters once the fields exist: records written before them simply lack the field, readers fall back to the per-install `senderDeviceID`, and an old build and a new one interoperate in both directions. Nothing filters on either field, so no index is needed and none should be added — the zone is the filter, which is what 2.0 made it.

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

## 7. Upload a build (TestFlight)

- [ ] Bump build number: in `project.yml` change `CURRENT_PROJECT_VERSION` (or edit in Xcode → target → General → Build), re-run `xcodegen generate` if you edited the YAML
- [ ] Xcode device picker → **Any iOS Device (arm64)**
- [ ] **Product → Archive**
- [ ] When the Organizer opens: **Distribute App** → **App Store Connect** → **Upload** → accept defaults → **Upload**
- [ ] Wait for the processing email (~10 min)
- [ ] Go to <https://appstoreconnect.apple.com> → **My Apps**. If the app doesn't exist yet, click **+** → **New App** and fill in name, primary language, bundle ID, SKU. The **App Name** there is the App Store listing name and is independent of `CFBundleDisplayName` in `project.yml`, which is only the home-screen label — they are "Please Give Me Attention" and "Attention" respectively, and that is deliberate: iOS truncates a 24-character name to "PleaseGive…" under the icon
- [ ] Click your app → **TestFlight** tab
- [ ] Wait until the build status is **Ready to Test**. `ITSAppUsesNonExemptEncryption: false` in `project.yml` should stop "Missing Compliance" appearing at all — see §7a before changing that answer
- [ ] **Internal Testing**: + group → add yourself + partner (must be added under **Users and Access** as a member of your team first), assign the build. They get an email to install via the **TestFlight** app.
- [ ] **Or External Testing**: add by email, requires a one-time short Beta App Review (~24h), then unlimited installs

## 7a. Encryption export compliance

`project.yml` sets `ITSAppUsesNonExemptEncryption: false`, which bypasses the
export-compliance questions App Store Connect otherwise asks on every submission.
That answer is still correct, but **not for the reason it was originally set** —
it predates the app having any encryption at all, and 2.0 added some. The current
justification, so nobody has to re-derive it:

- Apple: *"Set the value to `NO` if your app — including any third-party libraries
  it links against — doesn't use encryption, or if it only uses forms of encryption
  that are exempt from export compliance documentation requirements."*
- All of this app's cryptography is CryptoKit: `ChaChaPoly` and `HKDF<SHA256>` in
  `Shared/PairCrypto.swift`, and `SHA256` for the diagnostics fingerprints. Nothing
  is hand-rolled and no crypto library is vendored.
- App Store Connect's own table classifies **"Apple OS encryption only"** as
  requiring *no documentation in App Store Connect*. The rows that do require
  paperwork are non-Apple industry-standard algorithms (French declaration, if you
  ship to France) and proprietary algorithms (US CCATS as well). Neither applies.

**What would invalidate this**, and therefore means re-reading this section:

- Vendoring or linking any crypto library rather than calling CryptoKit
- Implementing a cipher, KDF or protocol by hand
- Adding any third-party dependency at all — the exemption covers what the app
  links against, not just what it writes

**One open item that is not a code question.** Apple notes that apps using *exempt*
encryption "might alternatively be required to submit a year-end self-classification
report to the U.S. government" — the exempt path carries the reporting duty, not the
documented one, which is the opposite of the intuition. Against that: a March 2021
amendment to the EAR removed annual self-classification reporting for most
mass-market items under ECCN 5A992.c / 5D992.c, the classification a consumer iOS
app on the App Store would ordinarily fall under. So there is probably nothing to
file. That is an export-control question rather than an engineering one, and worth
confirming with someone qualified before the first public release rather than after.

References: [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
· [Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
· [BIS annual self-classification](https://www.bis.gov/learn-support/encryption-controls/annual-self-classification)

## 7a-ii. App Privacy answers

App Store Connect → your app → **App Privacy**: answer **Data Not Collected**.

Apple defines "collect" as transmitting data off the device *in a way that allows you or
your third-party partners to access it*. This app has no server. Everything goes to the
user's own CloudKit private database and their partner's, neither of which the developer
holds credentials for, and since 2.0 the contents are sealed under a key that never leaves
the two phones. Reading the definition the other way round would make every CloudKit app
on the store a collector, which is plainly not the intent — and a label reading "Name,
Messages collected" would misinform users in the direction that matters most here.

**`App/Resources/PrivacyInfo.xcprivacy` must agree**, and this is the part that is easy to
miss: it is the same declaration in a second place, and Xcode's *Generate Privacy Report*
exists to reconcile the two. It previously listed Name, OtherUserContent and DeviceID —
written before this decision — and now carries an empty `NSPrivacyCollectedDataTypes`.
Change one, change the other, or the archive's privacy report will contradict the
questionnaire.

`NSPrivacyAccessedAPITypes` is unrelated and stays: it declares *API access* (UserDefaults,
reason `CA92.1`), not collection, and is still required.

## 7b. App Review notes

A reviewer has **one device**, and this app is two screens of wall without a second one:
the iCloud gate if they aren't signed in, then the pairing screen. Apps get rejected under
Guideline 2.1 for exactly this.

Don't try to solve it with a live invite link. `PairingInvite` expires in 24 hours and
reviews take longer, the share is single-use so a re-review after a rejection gets nothing,
and it pairs a stranger to your actual phone.

The app answers it itself: **Try it without a partner** on the pairing screen, and
**See how it works without signing in** on the iCloud gate. Both start a self-contained
demo — scripted partner, no network, nothing stored. Say so in the App Review Notes field:

> This app pairs two phones and has no accounts or servers, so a single device cannot use
> its main flow. Tap **Try it without a partner** on the first screen (or **See how it
> works without signing in** if the device isn't signed in to iCloud) to see the whole app
> on one device: press the button, watch the status go Sent → Seen → Acknowledged, then
> wait a few seconds for a simulated incoming alert and tap an emoji to answer it. Nothing
> in the demo is sent or stored.

The demo is a normal user-facing feature, not a review carve-out — Guideline 2.3.1
prohibits hidden or undocumented features, and a door only Apple can find would be one.
It is also worth having on its own: without it, anyone who installs the app before
convincing their partner to install it can't see what they'd be signing up for.

## 7c. Digital Services Act trader status

App Store Connect → **App Information** → **App Store Regulations & Permits** →
**Digital Services Act**. Declared **non-trader**.

The DSA requires anyone distributing in the EU to say whether they are a *trader* —
someone acting for purposes relating to a trade, business, craft or profession. This app
is free, has no in-app purchases, no subscriptions, no advertising and no revenue of any
kind, and exists as a personal project. That is the clearest case for non-trader. It is a
self-assessment rather than a determination Apple makes for you.

**What declaring trader would have cost.** Apple publishes a trader's name, physical
address, phone number and email address on the EU App Store listing, by design — the DSA
exists to make sellers contactable. For an individual developer that means a home address
on a public page, which is a poor trade for an app that earns nothing.

**What would change this answer.** Any monetisation at all: a paid tier, in-app purchases,
subscriptions, advertising, sponsorship. Re-read this section before the next submission if
any of those arrive. Note the declaration is per **account**, not per app, so it also
covers anything else ever shipped under the same Apple ID.

**How it fails.** Getting this wrong toward non-trader means removal from EU storefronts
rather than a rejected build, so it surfaces after release rather than during review. The
third option, if the question ever becomes uncomfortable, is simply declining EU
territories under **Pricing and Availability** — a large market to give up, but it removes
the question rather than answering it.

Unrelated and on the same page, for the avoidance of a future hunt: **App Encryption
Documentation** needs no upload. Apple asks for it only for proprietary or non-standard
algorithms, or for standard algorithms used instead of or in addition to the encryption in
Apple's OS. Everything here is CryptoKit, which *is* that encryption — see §7a.

## 7d. Which devices the app is offered to

One binary covers all of it. `TARGETED_DEVICE_FAMILY: "1,2"` in `project.yml` builds for iPhone
and iPad, and the Apple Silicon Mac and Apple Vision Pro options run *that same iPad build* in
compatibility mode — there is no separate macOS or visionOS target to make, which is why all
three are checkboxes rather than work.

- [ ] **App Store Connect → your app → Pricing and Availability**, and tick the destinations you
      want: **Apple Silicon Mac** and **Apple Vision Pro** are separate checkboxes there
- [ ] **Screenshots: iPad is its own required set.** Submission blocks on an empty iPad tab even
      though the binary is ready, and the phone screenshots do not carry over

**Push on Mac and Vision Pro is unverified.** The app has never been confirmed to actually ring
on either — see #72, which names the specific risk: a Mac that says "paired" and never rings is
worse than a Mac that cannot pair. Both checkboxes are reversible without a new build, so the
safe order is to ship iPhone and iPad, verify delivery on a real Mac, and tick that box after.

Orientation is split by idiom rather than shared: iPhone stays portrait-locked, iPad rotates and
multitasks. `UISupportedInterfaceOrientations~ipad` in `project.yml` is where that lives.

## 7e. Submitting a build to the App Store

**A tag is not a submission.** Pushing a tag fires the Xcode Cloud workflow, which archives and
delivers to TestFlight — and stops. Getting that same build in front of App Review is a separate
gesture in App Store Connect that no workflow performs for you. This section exists because the
gap between those two things is invisible from the repo: `main` is green, the tag is pushed, the
build is processed, and nothing says the release has not been submitted.

The build you submit is the archive TestFlight already has. There is no second build and no
second tag — *provided the tag you shipped is the commit you mean to release*. Check that first,
because it is the easy mistake:

```sh
git fetch --tags
git log --oneline <version>..origin/main    # must be empty
```

Anything listed there is in `main` and **not** in the build, so submitting ships without it.

- [ ] **App Store Connect → your app → the version in the sidebar** (create it with **+** if this
      version has no page yet — the version number must exceed the last released one)
- [ ] **Build** section → **+** → pick the processed build
- [ ] **What's New in This Version** → paste from `AppStore/WhatsNew.en-US.txt`. Unlike
      TestFlight's tester notes, Xcode Cloud does **not** upload this — the file is tracked so the
      copy gets reviewed in a PR, but a human still pastes it
- [ ] **Promotional Text** → paste from `AppStore/PromotionalText.en-US.txt` (170 characters, sits
      above the description on the product page). A new version starts this empty, which is the
      only reason it appears here — see below for why it is otherwise the odd one out
- [ ] Confirm the §7d destinations and that every required screenshot set is filled — **iPad is its
      own set and submission blocks on an empty tab**
- [ ] **Add for Review** → status becomes *Ready for Review*. This does not send anything
- [ ] **Submit for Review** → status becomes *Waiting for Review*. It flips to *In Review* only
      when Apple actually picks it up, which can be hours or days later — so the first status is
      what a successful submission looks like, not a stuck one. Apple's own help page skips
      straight to *In Review*, which is where the wrong expectation comes from

Set **Release version** before submitting, not after: *Automatically release this version* (and
optionally *Phased Release*) removes the post-approval step entirely. 2.1.1 was set to manual
release, which meant approval arrived and nothing shipped until someone noticed.

**Promotional text is the one field you can change without any of this.** It is the only piece of
App Store copy that needs neither a review nor a build: edit it in App Store Connect and it is
live. So while the tracked file exists to keep the copy under review like everything else, it is
not bound to a release — if a sentence there stops being true between versions, fix it that
afternoon rather than waiting for the next submission.

### Why this is not automated

It could be. Xcode Cloud cannot do it — its post-actions cover TestFlight distribution and Mac
notarization, and the "App Store" export option only prepares the archive, landing it in exactly
the place it already lands. But the [App Store Connect
API](https://developer.apple.com/documentation/appstoreconnectapi/review-submissions) mirrors the
two buttons above in three calls: `POST /v1/reviewSubmissions` opens a submission,
`POST /v1/reviewSubmissionItems` puts the version in it, and `PATCH /v1/reviewSubmissions/{id}`
with `submitted: true` hands it to Apple. That would run from `ci_scripts/ci_post_xcodebuild.sh`,
which the runner picks up by the same convention as the post-clone hook.

Declined, for three reasons in ascending order of weight. It needs an API key with release-level
write stored as an Xcode Cloud secret, and that key can submit or release anything on the account.
The script has to ES256-sign its own JWTs, which is real code to maintain for something that
happens a few times a year. And submission is gated on metadata completeness, so automating the
button press does not automate the blocker — for 2.2.0 the blocker was an empty iPad screenshot
set, which no API call fixes.

Revisit if releases ever become frequent enough that the manual step is the bottleneck. They are
not close.

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
- **Scan Code shows "Attention can't use the camera"**: camera permission was denied. Tap **Open Settings** on that screen, turn Camera on, and come back — the screen re-checks on foreground. The **Paste it** button on the same screen pairs without the camera at all, from an invite link your partner shared.
- **Settings → Diagnostics shows "Inbox zones: 2 (2 in use) — EXPECTED 1, RE-PAIR TO FIX"**: two installs signed into this Apple Account each minted their own inbox zone before 2.2.0 and are still retiring each other's subscriptions — one of them looks perfectly paired and is never pushed to (#68). From 2.2.0 the state cannot arise: a second device discovers the zone the account already owns instead of minting a rival. It is not repaired automatically, because that means moving a live pairing onto a different zone and deciding which of the two is the real one. **Pair again once** and both devices settle on the single zone the new pairing mints.
  - **"(1 in use, rest abandoned)"** is a different thing and needs no action: a zone left behind by a teardown whose CloudKit delete failed, or by a pairing that was started and replaced. Nobody can reach it — the share was revoked first — and re-pairing would not clear it, only add another. iCloud storage you can tidy from the CloudKit Dashboard if it bothers you.
  - **"unknown"** means the listing or the pair key was unavailable, which is not the same as none.
- **Watch button does nothing when phone is off**: the watch queues the press via `transferUserInfo` and the iPhone sends the alert when it next wakes. Expected.
