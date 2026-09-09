# Per-Configuration Entitlements Plan

**Status: shipped, but not as planned.** Splitting the file was rejected — two entitlements files identical apart from one key is a silent drift hazard. `aps-environment` is `$(APS_ENVIRONMENT)` instead, with the value set per configuration in `project.yml` (`development` for Debug, `production` for Release). One file, no fork. This doc records the original plan and why the shipped approach differs.

**Everything below this line is the original plan, written before any of it shipped.** Its present tense describes the repository as it was — in particular `App/Attention.entitlements` no longer hardcodes `production`. Read it as history; the shipped arrangement is the paragraph above.

Original framing: splitting `App/Attention.entitlements` into Debug and Release variants so local Xcode builds and TestFlight builds use the correct APNs environment.

## Why

Apple's APNs has two separate networks: `development` (used by Xcode-signed debug builds) and `production` (used by TestFlight and App Store builds). The push token a device registers depends on the `aps-environment` entitlement. The two networks don't interoperate, so a single entitlement value will only work for one build type.

Currently `App/Attention.entitlements` has `aps-environment = production`, which means TestFlight works but local Xcode debug builds on a real device get a production token from a development-signed binary — APNs accepts the registration but pushes won't deliver.

## Plan

### 1. Create two entitlements files

- `App/Attention.entitlements` — keep as-is, with `aps-environment = production` (used for Release/TestFlight)
- `App/Attention.Debug.entitlements` — new, identical to above except `aps-environment = development` (used for Debug)

Same approach for `NotificationService/NotificationService.entitlements` (it doesn't currently set `aps-environment`, so this only matters if/when we add capabilities that differ between dev and release).

### 2. Wire build-configuration-specific entitlements in `project.yml`

XcodeGen supports per-config settings via `configs:`. The Attention target's `settings` becomes:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.timfallmk.attention
        TARGETED_DEVICE_FAMILY: "1"
        SUPPORTS_MACCATALYST: NO
        CODE_SIGN_STYLE: Automatic
        INFOPLIST_KEY_UISupportedInterfaceOrientations: UIInterfaceOrientationPortrait
        INFOPLIST_KEY_UIStatusBarStyle: UIStatusBarStyleDefault
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
      configs:
        Debug:
          CODE_SIGN_ENTITLEMENTS: App/Attention.Debug.entitlements
        Release:
          CODE_SIGN_ENTITLEMENTS: App/Attention.entitlements
```

Note: `CODE_SIGN_ENTITLEMENTS` moves out of `base` into `configs.Debug` and `configs.Release`.

### 3. Verify

After `xcodegen generate`:

- Debug build → check the resolved entitlement in **Build Settings → Code Signing Entitlements** for the Debug config — should be `App/Attention.Debug.entitlements`
- Archive (Release) → same check for Release config — should be `App/Attention.entitlements`

### 4. Maintenance gotcha

Any new entitlement (App Group changes, new capabilities, etc.) must be added to **both** files. Easy to drift. Mitigations:

- Comment in each file: `<!-- Keep in sync with Attention.Debug.entitlements / Attention.entitlements -->`
- Or generate one from the other with a small script in `Tools/`

## When to do this

When local-device push testing becomes useful. For now, the simulator (which doesn't get real pushes anyway) plus TestFlight covers the development loop.
