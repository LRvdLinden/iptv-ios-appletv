"""Maakt de screenshots uit docs/mockups/mockups.html, in het Nederlands (docs/screenshots) en Engels (docs/screenshots/en).
Echte posters uit docs/covers (vrij te gebruiken) worden gebruikt als ze er zijn.
Met --android <map> komen er Android-screenshots (telefoon + Android TV) in <map> en <map>/en, bv. voor de repo bingr-android."""
import json, sys, pathlib
from playwright.sync_api import sync_playwright
args = [a for a in sys.argv[1:]]
android = None
if "--android" in args:
    i = args.index("--android"); android = pathlib.Path(args[i + 1]).resolve(); del args[i:i + 2]
root = pathlib.Path(args[0] if args else ".").resolve()
html = (root / "docs/mockups/mockups.html").as_uri()
covers = root / "docs/covers/covers.json"
init = f"window.COVERS = {covers.read_text() if covers.exists() else '[]'};"
ios = ["ios_splash","ios_picker","ios_home","ios_detail","ios_detail2","ios_live","ios_add","ios_guide","ios_settings","ios_top10","ios_categories","ios_category"]
tv = ["tv_home","tv_picker","tv_detail","tv_live","tv_trakt","tv_multiview","tv_guide"]
with sync_playwright() as p:
    b = p.chromium.launch()
    if android:
        # Android: telefoon (Pixel-formaat) en Android TV; zelfde schermen, Android-statusbalk
        jobs = [(lang, out, ((ios, (412, 915), 3, "and_"), (tv, (1920, 1080), 1, "atv_")))
                for lang, out in (("nl", android), ("en", android / "en"))]
        q = "&platform=android"
    else:
        jobs = [(lang, out, ((ios, (430, 932), 3, ""), (tv, (1920, 1080), 1, ""), (["mac_home"], (1440, 900), 1, "")))
                for lang, out in (("nl", root / "docs/screenshots"), ("en", root / "docs/screenshots/en"))]
        q = ""
    for lang, out, groups in jobs:
        out.mkdir(parents=True, exist_ok=True)
        for names, vp, scale, prefix in groups:
            pg = b.new_page(viewport={"width": vp[0], "height": vp[1]}, device_scale_factor=scale)
            pg.add_init_script(init)
            for s in names:
                pg.goto(f"{html}?s={s}&lang={lang}{q}"); pg.wait_for_timeout(250)
                name = prefix + s.split("_", 1)[1] if prefix else s
                pg.screenshot(path=str(out / f"{name}.png"))
            pg.close()
    b.close()
print("ok")
