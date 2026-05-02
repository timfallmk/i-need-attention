# Emoji Catalog Maintenance Plan

Forward-looking reference for keeping `App/Helpers/EmojiCatalog.swift` from going stale as Unicode adds new emoji.

## Why

The in-app acknowledgement picker (`EmojiPickerView` + `EmojiCatalog`) is backed by a hand-curated Swift literal: ~1000 codepoints across 9 categories, plus a keyword index for search. Apple ships no public API that vends categorized emoji or English keywords (the system keyboard is a private input view), and the available Swift packages are middling — so we authored the dataset ourselves.

Unicode adds roughly 50–100 emoji per year (Unicode 15.0 → 15.1 → 16.0 → …), each tied to an iOS release. Without a maintenance step, those new emoji render correctly anywhere the system handles them but never appear in our picker. The system keyboard, being part of iOS, picks them up automatically; our static list does not.

Acceptable as-is for a personal-use app — the existing entries keep working forever, and missing the newest 50 emoji per year only matters if a user specifically reaches for one. If/when staleness becomes a real annoyance, here are the two cleanest paths.

## Option 1 — Generator script

Mirror the pattern used by `Tools/generate_icons.py`: a one-shot Python script that reads an upstream emoji dataset and rewrites `App/Resources/EmojiCatalog.swift`. Run it once a year (or whenever Apple ships a new emoji set in iOS).

**Source data:**

- [emojibase](https://github.com/milesj/emojibase) — MIT, npm-published JSON. Most ergonomic; ships English shortcodes, keywords, and group/subgroup metadata in a single file.
- Unicode CLDR (`common/annotations/en.xml`) — canonical, but XML and slightly less convenient.
- Unicode `emoji-test.txt` — minimal source-of-truth list of every codepoint and its category, but no keywords.

**Sketch:**

```
Tools/generate_emoji_catalog.py
  ├── fetch emojibase JSON (or commit a vendored snapshot under Tools/data/)
  ├── filter to fully-qualified emoji
  ├── group by primary category, drop ones we don't want (e.g. country flags can stay or split into a Flags subcategory)
  ├── write App/Helpers/EmojiCatalog.swift with categories, keywords, fitzpatrickBase, and a deterministic header comment showing the upstream version
```

**Trade-offs:**

- The script + a vendored data snapshot are committed; the regenerated `.swift` is committed. Diffs at upgrade time are reviewable.
- Choice of categories and which subset to ship is still a manual call.
- Keyword index quality matches whatever upstream provides. Emojibase is solid.
- One commit per yearly bump is predictable maintenance.

## Option 2 — Defer to the system keyboard

Drop the in-app grid entirely. Replace `EmojiPickerView` with a sheet that auto-focuses an empty `TextField` and prompts the user to tap an emoji on the system emoji keyboard. Take the first emoji grapheme cluster from the field's contents as the ack.

**Sketch:**

```swift
struct EmojiPickerView: View {
    let onPick: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            TextField("Tap an emoji", text: $text)
                .focused($focused)
                .onChange(of: text) { _, new in
                    if let emoji = new.first(where: { $0.unicodeScalars.first?.properties.isEmoji == true }) {
                        onPick(String(emoji))
                    }
                }
        }
        .onAppear { focused = true }
    }
}
```

(`UITextInputMode` lets us nudge the keyboard to start in emoji mode if we want; otherwise the user toggles it.)

**Trade-offs:**

- "Any emoji" becomes literally any emoji the user's iOS supports. No catalog. No staleness.
- Zero data maintenance forever.
- UX is plainer — no categorized grid, no in-app search. Users with the system emoji keyboard hidden behind ABC have an extra tap.
- Loses a bit of the Tapback-like polish the curated row plus grid implies.

## Recommendation

Stick with the hand-rolled catalog until two things are true: (a) we notice we're missing emoji users actually want, and (b) updating the literal feels annoying. At that point pick Option 1 if the categorized grid still earns its keep, or Option 2 if we're happy to trade visual polish for zero maintenance.
