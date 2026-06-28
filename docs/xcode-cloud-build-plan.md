# Xcode Cloud Build Plan

**Status: live.** The **Release** workflow exists in App Store Connect → Xcode Cloud and is the active release mechanism — every release since 1.0.0 has shipped through it. This doc is the rationale and the reference for the workflow's configuration; the day-to-day release steps live in `SETUP.md` §10–11. The repo-side prerequisite (`ci_scripts/ci_post_clone.sh`) is in place.

## Why bother

The manual flow (Archive → Organizer → Distribute → Upload → wait for email) takes ~5 minutes of clicks per release. Xcode Cloud reduces that to a `git push`. Worth setting up once builds are happening regularly.

## Prerequisites

- Xcode Cloud is accessed via App Store Connect → Xcode Cloud. No extra cost beyond the Developer Program membership (limited free compute hours included; more available via paid tiers).
- The GitHub repo must be connected: App Store Connect → Xcode Cloud → Grant Access → authorize the GitHub app on `timfallmk/i-need-attention`.

## Repo-side: post-clone hook

`*.xcodeproj/` is gitignored, so Xcode Cloud has nothing to build immediately after clone. `ci_scripts/ci_post_clone.sh` runs automatically before the build action and regenerates the project:

```sh
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
```

Apple's runner picks the script up by convention — no workflow setting required. Keep the file at `ci_scripts/ci_post_clone.sh` and executable (`chmod +x`).

## Proposed workflow: semver tag → TestFlight

Trigger: push a semver tag like `1.0.3` (or publish a GitHub Release with that tag). `main` stays the working branch; tags mark the immutable points that actually ship.

Why tags over a `release` branch:

- Each TestFlight build maps to a single tag (`1.0.3`) — easy to point at "the build on your phone"
- No `release` branch to keep in sync with `main`
- By convention a tag points at one commit, so the version label round-trips back to a known SHA. (Tags _can_ be moved with `git push --force --tags`; turn on GitHub tag protection rules if you want that locked down.)
- Creating the tag is the explicit "ship this" gesture

### Release ritual

1. Update `MARKETING_VERSION` in `project.yml` if this is a user-visible version bump, run `xcodegen generate`, commit and push. (`CURRENT_PROJECT_VERSION` is managed automatically by Xcode Cloud — do not bump it manually.)
2. Create a GitHub Release: `gh release create 1.0.3 --notes "what changed"`. This creates the tag and pushes it in one step, and leaves a changelog entry on the Releases page.
3. Xcode Cloud picks up the tag, runs the workflow, posts to TestFlight.

GitHub Releases are preferred over bare `git tag` pushes because they attach release notes to each shipped build — useful for tracking what's on each phone. The underlying mechanism is identical from Xcode Cloud's perspective (both create a tag on the remote), so there's no functional difference.

### Workflow steps

1. **Build** — scheme `Attention`, configuration `Release`, platform iOS (Xcode Cloud builds the watch targets automatically since they're scheme dependencies)
2. **Archive** — Xcode Cloud archives automatically after a successful build when `Archive` is enabled in the workflow
3. **TestFlight (Internal)** — distribute to internal group immediately after archive, no review required
4. **Notify** — Xcode Cloud can send an email/Slack webhook on success/failure

### What to configure in App Store Connect

```
Xcode Cloud → Create Workflow:
  Name:        Release to TestFlight
  Start Condition:
    Tag Changes → Tag: *.*.*
    Clean: Yes
  Environment:
    Xcode: latest release
    macOS: latest compatible
  Actions:
    1. Build
       Scheme: Attention
       Platform: iOS
    2. Archive & Export (TestFlight & App Store)
       Export method: TestFlight
  Post-Actions:
    Notify: on failure → email
```

### Watch target note

Xcode Cloud builds the watch app automatically when it is a dependency of the `Attention` scheme. No separate workflow needed.

### Things that don't work in Xcode Cloud

- **CloudKit schema changes** — still manual via the CloudKit Console or `xcrun cktool`
- **Provisioning** — Xcode Cloud manages its own signing; the `DEVELOPMENT_TEAM` in `project.yml` must match, but profiles are created automatically
- **Simulator tests** — there are no tests in this project yet; if added, they can run as a separate Test action before Archive

## History

Enabled at 1.0.0 (May 2026) — the 1.0.0 release notes read "First automated release via Xcode Cloud," and PR #8 ("Use GitHub Releases as canonical release gesture for Xcode Cloud") settled on tags/Releases as the trigger. The "Release" workflow in App Store Connect was last modified Apr 30, 2026. Build numbers have been left to Xcode Cloud throughout (the `CURRENT_PROJECT_VERSION` in `project.yml` stayed at `1` from 1.1.0 onward).
