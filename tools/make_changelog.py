"""Maakt CHANGELOG.md uit docs/changelog.json (bron voor app-repo's en website).

Formaat docs/changelog.json: lijst van builds (nieuwste eerst):
  {"build": 51, "version": "1.0.0", "date": "2026-10-12",
   "items": [{"type": "new"|"improved"|"fixed",
              "platforms": ["ios","ipados","tvos","macos","android","androidtv","web"],
              "nl": "…", "en": "…"}]}
"androidtv" staat voor Android TV, Google TV en Fire TV.

Gebruik: python3 tools/make_changelog.py                   → CHANGELOG.md (Apple + web)
         python3 tools/make_changelog.py --android <pad>   → <pad>/CHANGELOG.md (Android)
         python3 tools/make_changelog.py --site <map>      → <map>/assets/changelog.json"""
import json, sys, pathlib, shutil
root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "docs/changelog.json").read_text())
args = sys.argv[1:]
def arg(n): return args[args.index(n) + 1] if n in args else None

LABEL = {"ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "macos": "macOS", "android": "Android", "androidtv": "Android TV", "web": "Web"}
ORDER = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "web"]
APPS = {"ios", "ipados", "tvos", "macos", "android", "androidtv"}
TYPES = [("new", "✨ Nieuw"), ("improved", "⚡ Verbeterd"), ("fixed", "🛠 Opgelost")]
MONTHS = ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"]
def nl_date(iso):
    y, m, d = iso.split("-"); return f"{int(d)} {MONTHS[int(m) - 1]} {y}"

def md(keep, title, intro):
    out = [f"# Changelog · {title}", "", intro, "",
           "Per build: **✨ Nieuw**, **⚡ Verbeterd** en **🛠 Opgelost**, met per punt de platforms waarvoor het geldt.", ""]
    for e in data:
        items = [i for i in e["items"] if set(i["platforms"]) & keep]
        if not items: continue
        out += [f"## Versie {e.get('version', '1.0.0')} · Build {e['build']}", f"_{nl_date(e['date'])}_", ""]
        for t, head in TYPES:
            rows = [i for i in items if i["type"] == t]
            if not rows: continue
            out += [f"### {head}", ""]
            for i in rows:
                pl = i["platforms"]
                if APPS <= set(pl):  # alle apps: één label in plaats van zes
                    tags = "`Alle apps`" + (" `Web`" if "web" in pl else "")
                else:
                    tags = " ".join(f"`{LABEL[p]}`" for p in ORDER if p in pl)
                out.append(f"- {i['nl']} {tags}")
            out.append("")
    return "\n".join(out)

if arg("--android"):
    p = pathlib.Path(arg("--android")) / "CHANGELOG.md"
    p.write_text(md({"android", "androidtv"}, "Android",
        "Alle versies van Bingr voor Android-telefoon en -tablet, Android TV, Google TV en Fire TV. iPhone, iPad, Apple TV en Mac: [iptv-ios-appletv](https://github.com/LRvdLinden/iptv-ios-appletv/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/)."))
    print(p)
elif arg("--site"):
    d = pathlib.Path(arg("--site")) / "assets"; d.mkdir(exist_ok=True)
    shutil.copy(root / "docs/changelog.json", d / "changelog.json"); print(d / "changelog.json")
else:
    p = root / "CHANGELOG.md"
    p.write_text(md({"ios", "ipados", "tvos", "macos", "web"}, "iPhone, iPad, Apple TV, Mac en web",
        "Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/)."))
    print(p)
