#!/usr/bin/env python3
"""App Store-afbeeldingen voor Bingr 1.0.5 (nl-NL en en-US), nagebouwd naar de SwiftUI-code.

Getrouwe recreatie (geen simulatoropnames): page.html + ui.js + art.js tekenen de schermen met alleen fictieve titels,
zenders en zelfgetekende beelden (geen posters, logo's of namen van echte films, series, zenders of merken).
Gebruik: python3 AppStore/generator/render.py   (schrijft naar AppStore/screenshots en AppStore/marketing)
"""
import pathlib
from playwright.sync_api import sync_playwright
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
PAGE = (HERE / "page.html").as_uri()

PHONE = ["home", "guide", "detail", "profiles", "categories", "devices"]
TVS = ["home", "guide", "detail", "profiles", "categories", "login"]
MAC = ["home", "guide", "detail", "categories", "devices"]
LOCALES = {"nl": "nl-NL", "en": "en-US"}

JOBS = []  # (set, shot, w, h, variant, path)
for lang, loc in LOCALES.items():
    s = ROOT / "screenshots" / loc
    for i, k in enumerate(PHONE, 1):
        JOBS += [("iphone", k, 1206, 2622, "a", s / "iphone-6.3" / f"{i:02d}_{k}_1206x2622.png", lang),
                 ("iphone", k, 1179, 2556, "a", s / "iphone-6.1" / f"{i:02d}_{k}_1179x2556.png", lang),
                 ("ipad", k, 2064, 2752, "a", s / "ipad-13" / f"{i:02d}_{k}_2064x2752.png", lang)]
    for i, k in enumerate(TVS, 1):
        JOBS += [("tv", k, 3840, 2160, "a", s / "appletv" / f"{i:02d}_{k}_3840x2160.png", lang),
                 ("tv", k, 1920, 1080, "a", s / "appletv" / f"{i:02d}_{k}_1920x1080.png", lang)]
    for i, k in enumerate(MAC, 1):
        JOBS += [("mac", k, 2880, 1800, "a", s / "mac" / f"{i:02d}_{k}_2880x1800.png", lang),
                 ("mac", k, 1440, 900, "a", s / "mac" / f"{i:02d}_{k}_1440x900.png", lang)]
    m = ROOT / "marketing" / loc
    JOBS += [("banner", "home", 5244, 2950, "a", m / "header_5244x2950.png", lang),
             ("banner", "home", 3840, 1646, "a", m / "header_3840x1646.png", lang),
             ("banner", "home", 5244, 2950, "b", m / "search_5244x2950.png", lang),
             ("banner", "home", 3840, 2560, "b", m / "search_3840x2560.png", lang),
             ("banner", "home", 1920, 1280, "b", m / "search_1920x1280.png", lang)]


def main():
    import sys
    only = sys.argv[1:]  # optioneel: filter op deel van het pad
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        for st, shot, w, h, v, path, lang in JOBS:
            if only and not any(o in str(path) for o in only):
                continue
            pg = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            pg.goto(f"{PAGE}?set={st}&shot={shot}&lang={lang}&w={w}&h={h}&v={v}")
            pg.wait_for_function("document.title === 'ready'")
            pg.wait_for_load_state("networkidle")
            pg.evaluate("document.fonts.ready")
            pg.wait_for_timeout(250)
            path.parent.mkdir(parents=True, exist_ok=True)
            pg.screenshot(path=str(path))
            pg.close()
            im = Image.open(path).convert("RGB")
            assert im.size == (w, h), (path, im.size)
            im.save(path, optimize=True)
            print(path.relative_to(ROOT))
        b.close()


if __name__ == "__main__":
    main()
