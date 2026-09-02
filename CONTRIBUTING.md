# Contributing

Thanks for your interest in this project.

A few things to know up front:

- **This is a personal-use app distributed via TestFlight only.** It is not on the App Store, has no roadmap, and is maintained on a hobby basis.
- **Contributions are welcome but may not be merged.** I might decline a PR if it adds maintenance burden, conflicts with the personal-use scope, or just doesn't fit what I want from this project. Please don't take it personally.

## Before you start

- Read [SETUP.md](SETUP.md) end-to-end. It's the canonical guide for getting a working build (Apple Developer portal, CloudKit Dashboard, signing, TestFlight).
- Skim [CLAUDE.md](CLAUDE.md) for architecture, conventions, and the gotchas you'll hit.

## Local development

1. Fork the repo.
2. Follow SETUP.md for the one-time setup. You'll need to substitute your own bundle-ID prefix and Team ID.
3. Generate the Xcode project and open it:

   ```sh
   brew install xcodegen
   xcodegen generate
   open Attention.xcodeproj
   ```

## Pull requests

- Keep changes focused — one concern per PR.
- Match the existing code style (Swift 5.10, SwiftUI for iOS 17+, minimal comments — see CLAUDE.md).
- If you change CloudKit schema, capabilities, or App ID configuration, update [SETUP.md](SETUP.md) in the same commit.
- Test on a real device. The simulator can't deliver push or run CloudKit subscriptions reliably.
- Run the unit tests locally (⌘U) before pushing. CI builds with code signing disabled, so a green CI run is not evidence that the test bundle builds and signs on a real machine.
- Reference any related issue in the PR description.

## Code of conduct

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please don't open public issues for security problems.
