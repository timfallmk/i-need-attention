# Xcode Cloud Build Plan

Future reference for when manual Archive → Upload becomes tedious. Not currently configured.

## Why bother

The manual flow (Archive → Organizer → Distribute → Upload → wait for email) takes ~5 minutes of clicks per release. Xcode Cloud reduces that to a `git push`. Worth setting up once builds are happening regularly.

## Prerequisites

- Xcode Cloud is accessed via App Store Connect → Xcode Cloud. No extra cost beyond the Developer Program membership (limited free compute hours included; more available via paid tiers).
- The GitHub repo must be connected: App Store Connect → Xcode Cloud → Grant Access → authorize the GitHub app on `timfallmk/i-need-attention`.

## Proposed workflow: `release` branch → TestFlight

Trigger: push to `release` branch (keep `main` for development; only promote to `release` when ready to ship).

### Workflow steps

1. **Build** — scheme `Attention`, configuration `Release`, platform `iOS + watchOS` (Xcode Cloud builds both automatically when the scheme includes watch targets)
2. **Archive** — Xcode Cloud archives automatically after a successful build when `Archive` is enabled in the workflow
3. **TestFlight (Internal)** — distribute to internal group immediately after archive, no review required
4. **Notify** — Xcode Cloud can send an email/Slack webhook on success/failure

### What to configure in App Store Connect

```
Xcode Cloud → Create Workflow:
  Name:        Release to TestFlight
  Start Condition:
    Branch Changes → Branch: release
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

## When to set this up

When the app is stable and releases happen more than once a month. Until then, manual Archive → Upload is faster to manage than configuring and maintaining the workflow.
