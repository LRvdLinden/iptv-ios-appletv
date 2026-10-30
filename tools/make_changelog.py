"""Maakt CHANGELOG.md uit docs/changelog.json (bron voor app-repo's en website).

Formaat docs/changelog.json: lijst van builds (nieuwste eerst):
  {"build": 51, "version": "1.0.0", "date": "2026-10-12",
   "items": [{"type": "new"|"improved"|"fixed",
              "platforms": ["ios","ipados","tvos","macos","android","androidtv","windows","web","server"],
              "nl": "…", "en": "…"}]}
"androidtv" staat voor Android TV, Google TV en Fire TV; "windows" voor Bingr voor Windows
(repo bingr-windows, vanaf build 140). Samsung TV (Tizen) en LG-tv (webOS) worden niet meer
ondersteund: die platforms staan niet meer in de changelog.

"Alle apps" = alle apps in APPS die bij die build al bestonden (SINCE): vóór build 140 de zes
Apple- en Android-apps, vanaf build 140 ook windows. Oudere builds komen niet in de Windows-changelog.

Gebruik: python3 tools/make_changelog.py                   → CHANGELOG.md (Apple + web)
         python3 tools/make_changelog.py --android <pad>   → <pad>/CHANGELOG.md (Android)
         python3 tools/make_changelog.py --windows <pad>   → <pad>/CHANGELOG.md (Windows, repo bingr-windows)
         python3 tools/make_changelog.py --site <map>      → <map>/assets/changelog.json"""
import json, sys, pathlib, shutil
root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "docs/changelog.json").read_text())
args = sys.argv[1:]
def arg(n): return args[args.index(n) + 1] if n in args else None

LABEL = {"ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "macos": "macOS", "android": "Android", "androidtv": "Android TV",
         "windows": "Windows", "web": "Website", "server": "Server"}
ORDER = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "windows", "web", "server"]
APPS = {"ios", "ipados", "tvos", "macos", "android", "androidtv", "windows"}
WINDOWS_FROM = 140  # eerste build met de Windows-app
SINCE = {"windows": WINDOWS_FROM}
DROPPED = {"tizen", "webos"}  # vervallen platforms (Samsung TV, LG-tv): worden genegeerd als ze nog ergens staan

def apps_at(build):
    """De apps die bij deze build al bestonden ("Alle apps" van toen)."""
    return {p for p in APPS if build >= SINCE.get(p, 0)}

def platforms(i, build):
    """Platforms van een punt, zonder de vervallen platforms."""
    return set(i["platforms"]) - DROPPED
TYPES = [("new", "Nieuw"), ("improved", "Verbeterd"), ("fixed", "Opgelost")]
MONTHS = ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"]
def nl_date(iso):
    y, m, d = iso.split("-"); return f"{int(d)} {MONTHS[int(m) - 1]} {y}"

def set_label(k, build):
    if apps_at(build) <= set(k):
        extra = [n for p, n in (("web", "de website"), ("server", "de server")) if p in k]
        if not extra: return "Alle apps"
        return "Alle apps en " + extra[0] if len(extra) == 1 else "Alle apps, " + extra[0] + " en " + extra[1]
    names = [LABEL[p] for p in k]
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " en " + names[-1]

def md(keep, title, intro, core=None):
    # core: een build komt alleen in dit bestand als hij voor één van deze platforms is (elk platform heeft zijn eigen build);
    # serverpunten verschijnen dan alleen bij builds van die apps.
    core = core or keep
    out = [f"# Changelog · {title}", "", intro, "",
           "Per build, ingedeeld per apparaatsoort: **Nieuw**, **Verbeterd** en **Opgelost**.", ""]
    for e in data:
        items = [i for i in e["items"] if platforms(i, e["build"]) & keep]
        if not items or not any(platforms(i, e["build"]) & core for i in items): continue
        out += [f"## Versie {e.get('version', '1.0.0')} · Build {e['build']}", f"_{nl_date(e['date'])}_", ""]
        # per apparaatsoort (zelfde set platforms), daarbinnen Nieuw / Verbeterd / Opgelost
        groups = {}
        for i in items:
            ps = platforms(i, e["build"])
            groups.setdefault(tuple(p for p in ORDER if p in ps), []).append(i)
        def rank(k): return 0 if apps_at(e["build"]) <= set(k) else 1 + min(ORDER.index(p) for p in k) * 10 + len(k) * 0.1
        for k in sorted(groups, key=rank):
            out += [f"### {set_label(k, e['build'])}", ""]
            for t, head in TYPES:
                rows = [i for i in groups[k] if i["type"] == t]
                if not rows: continue
                out += [f"**{head}**", ""] + [f"- {i['nl']}" for i in rows] + [""]
    return "\n".join(out)

if arg("--android"):
    p = pathlib.Path(arg("--android")) / "CHANGELOG.md"
    p.write_text(md({"android", "androidtv", "server"}, "Android en Android TV",
        "Alle versies van Bingr voor Android-telefoon en -tablet, Android TV, Google TV en Fire TV. iPhone, iPad, Apple TV en Mac: [iptv-ios-appletv](https://github.com/LRvdLinden/iptv-ios-appletv/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/).", core={"android", "androidtv"}))
    print(p)
elif arg("--windows"):
    p = pathlib.Path(arg("--windows")) / "CHANGELOG.md"
    p.write_text(md({"windows", "server"}, "Windows",
        "Alle versies van Bingr voor Windows (installer voor Windows 10 en 11). De app toont de webspeler van bingr.online: verbeteringen daaraan staan bij de website op [bingr.online/changelog](https://bingr.online/changelog/). iPhone, iPad, Apple TV en Mac: [iptv-ios-appletv](https://github.com/LRvdLinden/iptv-ios-appletv/blob/main/CHANGELOG.md) · Android en Android TV: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md).", core={"windows"}))
    print(p)
elif arg("--site"):
    d = pathlib.Path(arg("--site")) / "assets"; d.mkdir(exist_ok=True)
    shutil.copy(root / "docs/changelog.json", d / "changelog.json"); print(d / "changelog.json")
else:
    p = root / "CHANGELOG.md"
    p.write_text(md({"ios", "ipados", "tvos", "macos", "web", "server"}, "iPhone, iPad, Apple TV, Mac, website en server",
        "Alle versies van Bingr voor iPhone, iPad, Apple TV en Mac, plus de website en de server. Android: [bingr-android](https://github.com/LRvdLinden/bingr-android/blob/main/CHANGELOG.md) · alles: [bingr.online/changelog](https://bingr.online/changelog/)."))
    print(p)
