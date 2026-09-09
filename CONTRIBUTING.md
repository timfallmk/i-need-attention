# Contributing

Thanks for your interest in this project.

A few things to know up front:

- **This is a small two-person app.** 2.1.1 was submitted to the App Store on 9 Sep 2026 and is awaiting review; TestFlight remains the pre-release channel. It has no roadmap and is maintained on a hobby basis.
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

## Licensing of contributions

This project is under the [Mozilla Public License 2.0](LICENSE), and contributions are
accepted under the same terms. There is no CLA to sign: MPL defines a Modification of a
covered file as Covered Software in its own right (§1.10), so a patch to a file here is
already MPL by the licence's own definitions rather than by an agreement on the side.

MPL's copyleft is per-file, which is worth knowing before you open a PR: modifications to
these files stay open, and a larger work that merely includes them does not have to be.

**Don't add a licence header to a file you write.** The root LICENSE covers the repo, and
a header that restates it only drifts. The exception is the case a header actually
resolves: **if you bring in a file under terms other than MPL-2.0, it must carry its own
notice** naming those terms, and — if it ships to users rather than just living in the
repo — an entry in `App/Models/OpenSourceLicenses.swift` so Settings → Open Source shows
it. Several licences require that attribution reach end users, not just readers of the
source tree, and the in-app screen is how this project satisfies it.

## Code of conduct

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please don't open public issues for security problems.
