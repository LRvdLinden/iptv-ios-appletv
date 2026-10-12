"""Werkt de website bij met de nieuwste screenshots, figuurtjes en het buildnummer.
Gebruik: python3 tools/sync_website.py [--site <map>] [--zip [pad]]
De site staat in de repo LRvdLinden/bingr-website; standaard ../bingr-website naast deze repo (of BINGR_SITE)."""
import os
import re, sys, pathlib, zipfile
from PIL import Image

root = pathlib.Path(__file__).resolve().parent.parent
def _arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv and len(sys.argv) > sys.argv.index(name) + 1 else None
site = pathlib.Path(_arg("--site") or os.environ.get("BINGR_SITE") or root.parent / "bingr-website").resolve()
if not (site / "index.html").exists():
    sys.exit(f"website niet gevonden in {site} — clone LRvdLinden/bingr-website of geef --site <map>")
img = site / "assets" / "img"
img.mkdir(parents=True, exist_ok=True)

build = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', (root / "project.yml").read_text()).group(1)
version = re.search(r'MARKETING_VERSION:\s*"([\d.]+)"', (root / "project.yml").read_text()).group(1)

shots = {"ios_categories": 600, "ios_home": 600, "ios_live": 600, "ios_detail": 600, "ios_top10": 600, "ios_picker": 600,
         "tv_home": 1400, "tv_detail": 1400, "tv_guide": 1400, "tv_multiview": 1400, "tv_live": 1400,
         "tv_picker": 1400, "tv_trakt": 1400, "mac_home": 1440}
# Nederlandse en Engelse screenshots (docs/screenshots en docs/screenshots/en)
for lang, src in (("nl", root / "docs/screenshots"), ("en", root / "docs/screenshots/en")):
    (img / lang).mkdir(exist_ok=True)
    for name, w in shots.items():
        im = Image.open(src / f"{name}.png").convert("RGB")
        im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
        im.save(img / lang / f"{name}.jpg", quality=84, optimize=True, progressive=True)
# oude losse screenshots opruimen
for old in img.glob("*.jpg"):
    old.unlink()

for p in sorted((root / "Shared/Resources/Avatars").glob("kid*.png")):
    Image.open(p).resize((160, 160), Image.LANCZOS).save(img / p.name, optimize=True)

icon = Image.open(root / "macOS/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png")
icon.resize((180, 180), Image.LANCZOS).save(site / "apple-touch-icon.png")
icon.resize((64, 64), Image.LANCZOS).save(site / "favicon.png")

# changelog (bron: docs/changelog.json)
import shutil
(site / "assets").mkdir(exist_ok=True)
shutil.copy(root / "docs/changelog.json", site / "assets/changelog.json")

for page in site.glob("*.html"):
    t = page.read_text()
    t = re.sub(r'(<span data-build>)[^<]*(</span>)', rf'\g<1>{version} (build {build})\g<2>', t)
    page.write_text(t)

if "--zip" in sys.argv:
    out = pathlib.Path(_arg("--zip") or root / f"Bingr-website-build{build}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(site.rglob("*")):
            rel = f.relative_to(site)
            if f.is_file() and f.name != ".DS_Store" and rel.parts[0] not in (".git", ".github") and f.name not in ("README.md", ".gitignore"):
                z.write(f, pathlib.Path("bingr.online") / rel)
    print(out)
print(f"website bijgewerkt: {version} (build {build})")
