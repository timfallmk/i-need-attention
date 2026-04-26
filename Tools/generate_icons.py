#!/usr/bin/env python3
"""Generate the iOS and watchOS app icons.

Produces:
  App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png      (1024x1024)
  Watch/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (1024x1024)

iOS 14+ and watchOS 10+ accept a single 1024px master icon and the system
generates every smaller size automatically. No need for the old multi-size set.

Run:
    python3 Tools/generate_icons.py
"""
from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path

SIZE = 1024

# Match the in-app button gradient (AttentionButton.swift)
TOP    = (255,  92,  92)   # #FF5C5C
MID    = (230,  41,  51)   # #E62933
BOTTOM = (169,  16,  25)   # #A91019


def vertical_gradient(size, top, mid, bottom):
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    half = size / 2
    for y in range(size):
        t = y / (size - 1)
        if t < 0.5:
            k = t / 0.5
            r = int(top[0] + (mid[0] - top[0]) * k)
            g = int(top[1] + (mid[1] - top[1]) * k)
            b = int(top[2] + (mid[2] - top[2]) * k)
        else:
            k = (t - 0.5) / 0.5
            r = int(mid[0] + (bottom[0] - mid[0]) * k)
            g = int(mid[1] + (bottom[1] - mid[1]) * k)
            b = int(mid[2] + (bottom[2] - mid[2]) * k)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def add_glossy_highlight(img):
    """Subtle radial white in the upper-left for depth."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    cx, cy = SIZE * 0.30, SIZE * 0.25
    max_r = SIZE * 0.55
    # Cheap radial: stack soft circles with decreasing alpha
    steps = 60
    for i in range(steps):
        r = max_r * (i + 1) / steps
        alpha = int(60 * (1 - (i / steps) ** 0.6))
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, alpha))
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=24))
    img.paste(overlay, (0, 0), overlay)
    return img


def draw_exclamation(img):
    """Bold white exclamation mark, centered."""
    draw = ImageDraw.Draw(img, "RGBA")

    stem_w = 150
    stem_h = 500
    stem_x = (SIZE - stem_w) // 2
    stem_y = (SIZE - stem_h) // 2 - 70
    draw.rounded_rectangle(
        [stem_x, stem_y, stem_x + stem_w, stem_y + stem_h],
        radius=stem_w // 2,
        fill=(255, 255, 255, 255),
    )

    dot_d = 150
    dot_x = (SIZE - dot_d) // 2
    dot_y = stem_y + stem_h + 56
    draw.ellipse(
        [dot_x, dot_y, dot_x + dot_d, dot_y + dot_d],
        fill=(255, 255, 255, 255),
    )

    # Soft drop shadow under the mark
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sdraw.rounded_rectangle(
        [stem_x, stem_y + 8, stem_x + stem_w, stem_y + stem_h + 8],
        radius=stem_w // 2,
        fill=(0, 0, 0, 40),
    )
    sdraw.ellipse(
        [dot_x, dot_y + 8, dot_x + dot_d, dot_y + dot_d + 8],
        fill=(0, 0, 0, 40),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=12))
    img.paste(shadow, (0, 0), shadow)

    # Re-draw the white shape on top so it's crisp
    draw.rounded_rectangle(
        [stem_x, stem_y, stem_x + stem_w, stem_y + stem_h],
        radius=stem_w // 2,
        fill=(255, 255, 255, 255),
    )
    draw.ellipse(
        [dot_x, dot_y, dot_x + dot_d, dot_y + dot_d],
        fill=(255, 255, 255, 255),
    )
    return img


def make_icon():
    img = vertical_gradient(SIZE, TOP, MID, BOTTOM)
    img = add_glossy_highlight(img)
    img = draw_exclamation(img)
    return img


def main():
    repo_root = Path(__file__).resolve().parent.parent
    targets = [
        repo_root / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png",
        repo_root / "Watch" / "Watch" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png",
    ]
    icon = make_icon()
    for path in targets:
        path.parent.mkdir(parents=True, exist_ok=True)
        icon.save(path, "PNG", optimize=True)
        print(f"wrote {path.relative_to(repo_root)}")


if __name__ == "__main__":
    main()
