#!/usr/bin/env python3
"""Maakt de alternatieve app-iconen (build 52) uit het bestaande icoon.

    python3 tools/make_icons.py

Uitvoer:
- iOS/Assets.xcassets/AppIcon-<Naam>.appiconset (1024 px, alternatieve app-iconen voor iPhone/iPad)
- iOS/Assets.xcassets/IconPreview-<Naam>.imageset en macOS/Assets.xcassets/IconPreview-<Naam>.imageset
  (voorbeeld in Mijn Bingr → Uiterlijk; op de Mac ook het Dock-icoon)

Werkwijze: elke pixel wordt ingedeeld als letter (wit), streep (verzadigd rood) of achtergrond
(donkerrood verloop) en per variant opnieuw ingekleurd; randen blijven zacht door te mengen.
"""
import json, pathlib
import numpy as np
from PIL import Image

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

# naam: (achtergrond-midden, achtergrond-rand, letter, streep)
VARIANTS = {
    "Dark":  ((0x16, 0x16, 0x16), (0x00, 0x00, 0x00), (0xFF, 0xFF, 0xFF), (0xE5, 0x09, 0x14)),
    "Light": ((0xFF, 0xFF, 0xFF), (0xE6, 0xE6, 0xE6), (0x11, 0x11, 0x11), (0xE5, 0x09, 0x14)),
    "Blue":  ((0x0B, 0x2A, 0x6B), (0x02, 0x08, 0x1F), (0xFF, 0xFF, 0xFF), (0x3B, 0x82, 0xF6)),
    "Gold":  ((0x2A, 0x1F, 0x05), (0x08, 0x06, 0x00), (0xFF, 0xF4, 0xD6), (0xF5, 0xB3, 0x0B)),
}


def recolor(img: Image.Image, bg_mid, bg_edge, letter, bar) -> Image.Image:
    a = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(axis=2), a.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    # letter: helder en onverzadigd
    w_letter = np.clip((mn - 0.35) / 0.5, 0, 1)
    # streep: helder rood en verzadigd
    w_bar = np.clip((r - 0.45) / 0.4, 0, 1) * np.clip((sat - 0.6) / 0.3, 0, 1) * (1 - w_letter)
    w_bg = np.clip(1 - w_letter - w_bar, 0, 1)
    # achtergrond: radiaal verloop zoals het origineel
    h, w = r.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.sqrt((xx - w / 2) ** 2 + (yy - h / 2) ** 2) / (w / 2 * 1.42)
    d = np.clip(d, 0, 1)[..., None]
    mid = np.array(bg_mid, np.float32) / 255
    edge = np.array(bg_edge, np.float32) / 255
    bg = mid * (1 - d) + edge * d
    out = (bg * w_bg[..., None]
           + np.array(letter, np.float32) / 255 * w_letter[..., None]
           + np.array(bar, np.float32) / 255 * w_bar[..., None])
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGB")


def write_json(path: pathlib.Path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def main():
    base = Image.open(src)
    for name, colors in VARIANTS.items():
        icon = recolor(base, *colors)
        # alternatief app-icoon (iOS/iPadOS)
        d = root / f"iOS/Assets.xcassets/AppIcon-{name}.appiconset"
        d.mkdir(parents=True, exist_ok=True)
        icon.save(d / "icon-1024.png")
        write_json(d / "Contents.json", {
            "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        })
        # voorbeeld (en Dock-icoon op de Mac)
        for cat in ("iOS", "macOS"):
            p = root / f"{cat}/Assets.xcassets/IconPreview-{name}.imageset"
            p.mkdir(parents=True, exist_ok=True)
            icon.resize((512, 512), Image.LANCZOS).save(p / "preview.png")
            write_json(p / "Contents.json", {
                "images": [{"filename": "preview.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            })
    # voorbeeld van het standaardicoon
    for cat in ("iOS", "macOS"):
        p = root / f"{cat}/Assets.xcassets/IconPreview-Default.imageset"
        p.mkdir(parents=True, exist_ok=True)
        base.convert("RGB").resize((512, 512), Image.LANCZOS).save(p / "preview.png")
        write_json(p / "Contents.json", {
            "images": [{"filename": "preview.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        })
    print("Iconen gemaakt:", ", ".join(VARIANTS))


if __name__ == "__main__":
    main()
