#!/usr/bin/env python3
"""
Regenerate App/Helpers/EmojiCatalog.swift from Unicode emoji-test.txt.

Usage:
    python3 Tools/generate_emoji_catalog.py
    python3 Tools/generate_emoji_catalog.py --data Tools/data/emoji-test.txt
    python3 Tools/generate_emoji_catalog.py --dry-run

Without --data the script fetches the latest emoji-test.txt from unicode.org.
Pass --data to use a vendored snapshot (good for reproducibility; commit it
alongside the generated .swift so diffs are reviewable at upgrade time).

Vendor a snapshot:
    curl -o Tools/data/emoji-test.txt https://unicode.org/Public/emoji/latest/emoji-test.txt
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

EMOJI_TEST_URL = "https://unicode.org/Public/emoji/latest/emoji-test.txt"

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT    = REPO_ROOT / "App" / "Helpers" / "EmojiCatalog.swift"

SKIN_TONES = {"1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"}

# Our 9 display categories in picker order.
CATEGORY_ORDER = [
    "Smileys & People",
    "Animals & Nature",
    "Food & Drink",
    "Activity",
    "Travel & Places",
    "Objects",
    "Symbols",
    "Hearts & Sparkles",
    "Flags",
]

# Unicode subgroup → our category.  "heart" subgroup goes to Hearts & Sparkles;
# Component subgroups map to None (skipped entirely).
SUBGROUP_CATEGORY: dict[str, str | None] = {
    # Smileys & Emotion
    "face-smiling":           "Smileys & People",
    "face-affection":         "Smileys & People",
    "face-tongue":            "Smileys & People",
    "face-hand":              "Smileys & People",
    "face-neutral-skeptical": "Smileys & People",
    "face-sleepy":            "Smileys & People",
    "face-unwell":            "Smileys & People",
    "face-hat":               "Smileys & People",
    "face-glasses":           "Smileys & People",
    "face-concerned":         "Smileys & People",
    "face-negative":          "Smileys & People",
    "face-costume":           "Smileys & People",
    "cat-face":               "Smileys & People",
    "monkey-face":            "Smileys & People",
    "heart":                  "Hearts & Sparkles",
    "emotion":                "Smileys & People",
    # People & Body
    "hand-fingers-open":      "Smileys & People",
    "hand-fingers-partial":   "Smileys & People",
    "hand-single-finger":     "Smileys & People",
    "hand-fingers-closed":    "Smileys & People",
    "hands":                  "Smileys & People",
    "hand-prop":              "Smileys & People",
    "body-parts":             "Smileys & People",
    "person":                 "Smileys & People",
    "person-gesture":         "Smileys & People",
    "person-role":            "Smileys & People",
    "person-fantasy":         "Smileys & People",
    "person-activity":        "Smileys & People",
    "person-sport":           "Smileys & People",
    "person-resting":         "Smileys & People",
    "family":                 "Smileys & People",
    "person-symbol":          "Smileys & People",
    # Component — omit
    "skin-tone":              None,
    "hair-style":             None,
    # Animals & Nature
    "animal-mammal":          "Animals & Nature",
    "animal-bird":            "Animals & Nature",
    "animal-amphibian":       "Animals & Nature",
    "animal-reptile":         "Animals & Nature",
    "animal-marine":          "Animals & Nature",
    "animal-bug":             "Animals & Nature",
    "plant-flower":           "Animals & Nature",
    "plant-other":            "Animals & Nature",
    # Food & Drink
    "food-fruit":             "Food & Drink",
    "food-vegetable":         "Food & Drink",
    "food-prepared":          "Food & Drink",
    "food-asian":             "Food & Drink",
    "food-sweet":             "Food & Drink",
    "drink":                  "Food & Drink",
    "dishware":               "Food & Drink",
    # Travel & Places
    "place-map":              "Travel & Places",
    "place-geographic":       "Travel & Places",
    "place-building":         "Travel & Places",
    "place-religious":        "Travel & Places",
    "place-other":            "Travel & Places",
    "transport-ground":       "Travel & Places",
    "transport-water":        "Travel & Places",
    "transport-air":          "Travel & Places",
    "hotel":                  "Travel & Places",
    "time":                   "Travel & Places",
    "sky & weather":          "Travel & Places",
    # Activities
    "event":                  "Activity",
    "award-medal":            "Activity",
    "sport":                  "Activity",
    "game":                   "Activity",
    "arts & crafts":          "Activity",
    # Objects
    "clothing":               "Objects",
    "sound":                  "Objects",
    "music":                  "Objects",
    "musical-instrument":     "Objects",
    "phone":                  "Objects",
    "computer":               "Objects",
    "light & video":          "Objects",
    "book-paper":             "Objects",
    "money":                  "Objects",
    "mail":                   "Objects",
    "writing":                "Objects",
    "office":                 "Objects",
    "lock":                   "Objects",
    "tool":                   "Objects",
    "science":                "Objects",
    "medical":                "Objects",
    "household":              "Objects",
    "other-object":           "Objects",
    # Symbols
    "transport-sign":         "Symbols",
    "warning":                "Symbols",
    "arrow":                  "Symbols",
    "religion":               "Symbols",
    "zodiac":                 "Symbols",
    "av-symbol":              "Symbols",
    "gender":                 "Symbols",
    "math":                   "Symbols",
    "punctuation":            "Symbols",
    "currency":               "Symbols",
    "other-symbol":           "Symbols",
    "keycap":                 "Symbols",
    "alphanum":               "Symbols",
    "geometric":              "Symbols",
    # Flags
    "flag":                   "Flags",
    "country-flag":           "Flags",
    "subdivision-flag":       "Flags",
}

# These specific lead codepoints are reclassified to "Hearts & Sparkles"
# regardless of their Unicode subgroup.
HEARTS_OVERRIDES: set[str] = {
    "1F48B",  # 💋 kiss mark         (emotion)
    "1F48D",  # 💍 ring               (clothing in Objects)
    "1F48E",  # 💎 gem stone          (clothing in Objects)
    "1F4AB",  # 💫 dizzy              (emotion)
    "1F4A5",  # 💥 collision          (emotion)
    "2728",   # ✨ sparkles           (event)
    "1F31F",  # 🌟 glowing star       (sky & weather)
    "1F525",  # 🔥 fire               (other-object)
    "1F388",  # 🎈 balloon            (event)
    "1F389",  # 🎉 party popper       (event)
    "1F38A",  # 🎊 confetti ball      (event)
    "1F381",  # 🎁 wrapped gift       (event)
}


def hexlist_to_swift(parts: list[str]) -> str:
    """['1F468', '200D', '1F4BB'] -> '\"\\u{1F468}\\u{200D}\\u{1F4BB}\"'"""
    return '"' + "".join(f"\\u{{{p}}}" for p in parts) + '"'


def name_to_keywords(name: str) -> list[str]:
    """'grinning face with smiling eyes' -> ['grinning', 'face', 'smiling', 'eyes', ...]"""
    words = re.split(r"[\s\-&]+", name.lower())
    seen: set[str] = set()
    out: list[str] = []
    for w in words:
        w = w.strip(".,:")
        if w and len(w) > 1 and w not in seen:
            seen.add(w)
            out.append(w)
    return out[:6]


def fetch_text(url: str) -> str:
    print(f"  GET {url}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "generate_emoji_catalog/2.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode()


def load_emoji_test(data_path: str | None) -> tuple[str, str]:
    if data_path:
        text = Path(data_path).read_text(encoding="utf-8")
        # Version from the header comment e.g. "# Version: 17.0"
        m = re.search(r"# Version:\s+(\S+)", text)
        version = m.group(1) if m else "local"
        return text, version
    text = fetch_text(EMOJI_TEST_URL)
    m = re.search(r"# Version:\s+(\S+)", text)
    version = m.group(1) if m else "unknown"
    return text, version


def parse_emoji_test(text: str) -> list[dict]:
    """Parse emoji-test.txt into a list of emoji dicts with keys:
    hexparts (list[str]), subgroup (str), name (str).
    Only fully-qualified entries are included; components (skin tones) are skipped.
    """
    entries: list[dict] = []
    cur_subgroup = ""

    for line in text.splitlines():
        if line.startswith("# subgroup:"):
            cur_subgroup = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#"):
            continue
        # Data line: "1F600 ; fully-qualified # 😀 E1.0 grinning face"
        if "; fully-qualified" not in line:
            continue
        code_part, comment_part = line.split(";", 1)
        hexparts = code_part.strip().upper().split()
        # Skip skin-tone-only component lines (they're not fully-qualified in Unicode 17,
        # but guard just in case)
        if all(h in SKIN_TONES for h in hexparts):
            continue
        # Parse name from comment after the version tag "E\d+"
        comment = comment_part.split("#", 1)[1].strip() if "#" in comment_part else ""
        m = re.search(r"E[\d.]+\s+(.*)", comment)
        name = m.group(1).strip() if m else ""
        entries.append({"hexparts": hexparts, "subgroup": cur_subgroup, "name": name})

    return entries


def classify(entry: dict) -> str | None:
    lead = entry["hexparts"][0]
    if lead in HEARTS_OVERRIDES:
        return "Hearts & Sparkles"
    return SUBGROUP_CATEGORY.get(entry["subgroup"])


def build_fitzpatrick(entries: list[dict]) -> set[str]:
    """Emoji that support a single skin tone: find fully-qualified entries that
    contain exactly one skin-tone modifier, strip it, and return the base literals.

    Multi-person ZWJ sequences (e.g. people holding hands) require two modifiers
    and are excluded because toned() can only apply one modifier.

    Unicode's toned sequences often omit VS16 (FE0F) even though the canonical
    base in emoji-test.txt is fully-qualified (e.g. base is '261D FE0F' but
    toned variant is '261D 1F3FB'). We resolve each stripped base against the
    known fully-qualified entries so the literals here match those in categories.
    """
    fq_keys: set[tuple[str, ...]] = {tuple(e["hexparts"]) for e in entries}

    bases: set[str] = set()
    for e in entries:
        parts = e["hexparts"]
        skin = [p for p in parts if p in SKIN_TONES]
        if len(skin) != 1:
            continue
        base_parts = [p for p in parts if p not in SKIN_TONES]
        if not base_parts:
            continue
        # Try the stripped base as-is; if not in the FQ set, try inserting FE0F
        # after the first codepoint (the common omission in toned sequences).
        key = tuple(base_parts)
        if key not in fq_keys:
            candidate = (base_parts[0], "FE0F") + tuple(base_parts[1:])
            if candidate in fq_keys:
                key = candidate
        bases.add(hexlist_to_swift(list(key)))
    return bases


def format_rows(items: list[str], inner_indent: str = "            ") -> list[str]:
    rows: list[str] = []
    for i in range(0, len(items), 6):
        chunk = items[i : i + 6]
        sep   = "," if i + 6 < len(items) else ""
        rows.append(inner_indent + ", ".join(chunk) + sep)
    return rows


def render_swift(
    categories: dict[str, list[str]],
    kw_pairs:   list[tuple[str, list[str]]],
    fitz:       set[str],
    version:    str,
) -> str:
    out: list[str] = []

    out.append(f"// Generated by Tools/generate_emoji_catalog.py — Unicode Emoji {version}")
    out.append("import Foundation")
    out.append("")
    out.append("enum SkinTone: String, CaseIterable, Identifiable {")
    for case_, raw in [
        ("light",        "1F3FB"),
        ("mediumLight",  "1F3FC"),
        ("medium",       "1F3FD"),
        ("mediumDark",   "1F3FE"),
        ("dark",         "1F3FF"),
    ]:
        out.append(f'    case {case_} = "\\u{{{raw}}}"')
    out.append("")
    out.append("    var id: String { rawValue }")
    out.append("")
    out.append("    var accessibilityName: String {")
    out.append("        switch self {")
    for case_, label in [
        ("light",        "Light skin tone"),
        ("mediumLight",  "Medium-light skin tone"),
        ("medium",       "Medium skin tone"),
        ("mediumDark",   "Medium-dark skin tone"),
        ("dark",         "Dark skin tone"),
    ]:
        out.append(f'        case .{case_}: return "{label}"')
    out.append("        }")
    out.append("    }")
    out.append("}")
    out.append("")
    out.append("enum EmojiCatalog {")
    out.append("    static let categories: [(name: String, emojis: [String])] = [")
    for cat in CATEGORY_ORDER:
        emojis = categories.get(cat, [])
        if not emojis:
            continue
        out.append(f'        ("{cat}", [')
        out.extend(format_rows(emojis))
        out.append("        ]),")
    out.append("    ]")
    out.append("")
    out.append("    static let keywords: [(emoji: String, terms: [String])] = [")
    for emoji_lit, terms in kw_pairs:
        if not terms:
            continue
        terms_s = ", ".join(f'"{t}"' for t in terms)
        out.append(f"        ({emoji_lit}, [{terms_s}]),")
    out.append("    ]")
    out.append("")
    out.append("    static let fitzpatrickBase: Set<String> = [")
    fitz_sorted = sorted(fitz)
    out.extend(format_rows(fitz_sorted, inner_indent="        "))
    out.append("    ]")
    out.append("")
    out.append("    static func toned(_ base: String, _ tone: SkinTone) -> String {")
    out.append("        let modifier = tone.rawValue")
    out.append("        guard let scalar = base.unicodeScalars.first else { return base }")
    out.append("        let head = String(scalar)")
    out.append("        let tail = base.unicodeScalars.dropFirst()")
    out.append("        var rebuilt = head + modifier")
    out.append("        var droppedLeadFE0F = false")
    out.append("        for s in tail {")
    out.append('            if !droppedLeadFE0F && s == "\\u{FE0F}" {')
    out.append("                droppedLeadFE0F = true")
    out.append("                continue")
    out.append("            }")
    out.append("            rebuilt.unicodeScalars.append(s)")
    out.append("        }")
    out.append("        return rebuilt")
    out.append("    }")
    out.append("")
    out.append("    static func search(_ query: String) -> [String] {")
    out.append("        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)")
    out.append("        guard !normalized.isEmpty else { return [] }")
    out.append("        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)")
    out.append("        guard !tokens.isEmpty else { return [] }")
    out.append("")
    out.append("        var seen = Set<String>()")
    out.append("        var results: [String] = []")
    out.append("")
    out.append("        for (emoji, terms) in keywords {")
    out.append("            let allMatch = tokens.allSatisfy { token in")
    out.append('                terms.contains { $0.hasPrefix(token) }')
    out.append("            }")
    out.append("            if allMatch && seen.insert(emoji).inserted {")
    out.append("                results.append(emoji)")
    out.append("            }")
    out.append("        }")
    out.append("")
    out.append("        guard results.isEmpty else { return results }")
    out.append("")
    out.append("        for (name, emojis) in categories {")
    out.append("            let cat = name.lowercased()")
    out.append("            guard tokens.allSatisfy({ cat.contains($0) }) else { continue }")
    out.append("            for emoji in emojis where seen.insert(emoji).inserted {")
    out.append("                results.append(emoji)")
    out.append("            }")
    out.append("        }")
    out.append("")
    out.append("        return results")
    out.append("    }")
    out.append("}")
    out.append("")

    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--data", metavar="PATH",
        help="Local emoji-test.txt (skips network fetch)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print generated Swift to stdout; don't write the file",
    )
    args = parser.parse_args()

    print("Loading emoji-test.txt...")
    try:
        text, version = load_emoji_test(args.data)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    entries = parse_emoji_test(text)
    print(f"Parsed {len(entries)} fully-qualified emoji (Unicode Emoji {version})\n")

    # Deduplicate: same hexparts sequence may appear under multiple subgroups
    # (e.g. minimally-qualified variants share the same sequence). Track by
    # the frozen tuple of hexparts.
    seen_seq: set[tuple[str, ...]] = set()
    fitz = build_fitzpatrick(entries)

    categories: dict[str, list[str]]        = {c: [] for c in CATEGORY_ORDER}
    kw_pairs:   list[tuple[str, list[str]]] = []

    for entry in entries:
        key = tuple(entry["hexparts"])
        if key in seen_seq:
            continue
        # Skip entries that contain a skin-tone modifier (they're variants, not base emoji)
        if any(p in SKIN_TONES for p in entry["hexparts"]):
            continue
        cat = classify(entry)
        if cat is None:
            continue
        seen_seq.add(key)
        lit  = hexlist_to_swift(entry["hexparts"])
        categories[cat].append(lit)
        kws = name_to_keywords(entry["name"])
        if kws:
            kw_pairs.append((lit, kws))

    swift = render_swift(categories, kw_pairs, fitz, version)

    if args.dry_run:
        print(swift)
        return

    OUTPUT.write_text(swift, encoding="utf-8")

    total = sum(len(v) for v in categories.values())
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)}")
    print(f"Total: {total} emoji\n")
    for cat in CATEGORY_ORDER:
        n = len(categories.get(cat, []))
        if n:
            print(f"  {cat}: {n}")
    print(f"\nfitzpatrickBase: {len(fitz)} entries")


if __name__ == "__main__":
    main()
