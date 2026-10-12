"""Maakt CHANGELOG.md uit docs/changelog.json (de bron voor app-repo's en website).
Gebruik: python3 tools/make_changelog.py                     → CHANGELOG.md (Apple)
         python3 tools/make_changelog.py --android <pad>     → <pad>/CHANGELOG.md (Android-versies)
         python3 tools/make_changelog.py --site <map>        → <map>/assets/changelog.json"""
import json, sys, pathlib, shutil
root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "docs/changelog.json").read_text())
args = sys.argv[1:]
def arg(n): return args[args.index(n) + 1] if n in args else None
def md(platform, title, link):
    out = [f"# Changelog · {title}", "", f"Alle versies van Bingr {link}. Versie 1.0.0; het buildnummer loopt gelijk over alle platforms.", ""]
    for e in data:
        if platform not in e["platforms"]: continue
        out += [f"## Build {e['build']} · {e['date']}", ""] + [f"- {x}" for x in e["nl"]] + [""]
    return "\n".join(out)
if arg("--android"):
    p = pathlib.Path(arg("--android")) / "CHANGELOG.md"
    p.write_text(md("android", "Android", "voor Android, Android TV en Fire TV (iPhone, iPad, Apple TV en Mac: [iptv-ios-appletv](https://github.com/LRvdLinden/iptv-ios-appletv/blob/main/CHANGELOG.md))")); print(p)
elif arg("--site"):
    d = pathlib.Path(arg("--site")) / "assets"; d.mkdir(exist_ok=True)
    shutil.copy(root / "docs/changelog.json", d / "changelog.json"); print(d / "changelog.json")
else:
    (root / "CHANGELOG.md").write_text(md("apple", "iPhone, iPad, Apple TV en Mac", "voor iPhone, iPad, Apple TV en Mac (Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md))")); print(root / "CHANGELOG.md")
