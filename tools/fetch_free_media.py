#!/usr/bin/env python3
"""Vrije film-afbeeldingen voor de App Store-screenshots (workflow appstore-screenshots.yml).

Alleen afbeeldingen van Wikimedia Commons met een vrije licentie die wereldwijd geldt: CC BY / CC BY-SA (Blender open
movies) of publiek domein (films en posters van vóór 1931 waarvan alle makers meer dan 70 jaar dood zijn). De lijst met
bestanden staat in docs/appstore/free_media.json; dit script controleert per bestand via de Commons-API de licentie op
de bestandspagina (LicenseShortName) en stopt bij alles wat niet op de toegestane lijst staat (geen NC, geen ND, geen
fair use, geen "PD-US" alleen).

  fetch_free_media.py fetch  <uitvoermap>          downloadt (verkleind, JPEG) + credits.json
  fetch_free_media.py search <uitvoerbestand> ...  zoekt kandidaten (alleen om de lijst samen te stellen)
"""
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
from io import BytesIO

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://commons.wikimedia.org/w/api.php"
UA = "BingrAppStoreScreenshots/1.0 (https://github.com/LRvdLinden/iptv-ios-appletv)"

# toegestane licenties (LicenseShortName op Commons), hoofdletterongevoelig
ALLOWED = [
    r"^cc by(-sa)? (2\.0|2\.5|3\.0|4\.0)$",
    r"^cc by(-sa)? (2\.0|2\.5|3\.0|4\.0) [a-z]{2}$",
    r"^public domain$",
    r"^pd$",
    r"^pd-old.*$",
    r"^pd-1923$",
    r"^cc0$",
]
# deze PD-varianten gelden NIET wereldwijd (alleen VS of alleen het land van herkomst)
DENIED = [r"pd-us", r"pd-usgov", r"non-free", r"fair use", r"\bnc\b", r"\bnd\b", r"noncommercial", r"noderiv"]


def api(**q):
    q.update(format="json", formatversion="2")
    url = API + "?" + urllib.parse.urlencode(q)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
                return json.loads(r.read())
        except Exception as e:  # noqa: BLE001
            if attempt == 3:
                raise
            print(f"  opnieuw ({e})")
            time.sleep(3 + attempt * 3)


def plain(html: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html or "")).strip()


def info(titles, width=None):
    q = dict(action="query", titles="|".join(titles), prop="imageinfo|categories", cllimit="max",
             iiprop="url|size|mime|extmetadata",
             iiextmetadatafilter="LicenseShortName|License|LicenseUrl|Artist|Credit|UsageTerms|Copyrighted|DateTimeOriginal|ObjectName|ImageDescription")
    if width:
        q["iiurlwidth"] = str(width)
    return api(**q).get("query", {}).get("pages", [])


def licence_ok(lic: str) -> bool:
    l = lic.strip().lower()
    if any(re.search(d, l) for d in DENIED):
        return False
    return any(re.match(a, l) for a in ALLOWED)


def search(out: pathlib.Path, queries):
    lines = []
    for q in queries:
        lines.append(f"### {q}")
        if q.startswith("Category:"):
            res = api(action="query", list="categorymembers", cmtitle=q, cmtype="file", cmlimit="60")
            titles = [m["title"] for m in res.get("query", {}).get("categorymembers", [])]
        else:
            res = api(action="query", list="search", srsearch=q, srnamespace="6", srlimit="40")
            titles = [m["title"] for m in res.get("query", {}).get("search", [])]
        for i in range(0, len(titles), 40):
            for p in info(titles[i:i + 40], width=360):
                ii = (p.get("imageinfo") or [{}])[0]
                md = ii.get("extmetadata", {})
                lic = md.get("LicenseShortName", {}).get("value", "")
                cats = [c["title"].replace("Category:", "") for c in p.get("categories", [])]
                lines.append("\t".join([p["title"], f"{ii.get('width')}x{ii.get('height')}", ii.get("mime", ""), lic,
                                        "OK" if licence_ok(lic) else "--",
                                        plain(md.get("Artist", {}).get("value", ""))[:80],
                                        plain(md.get("ImageDescription", {}).get("value", ""))[:120],
                                        "; ".join(cats)[:300], ii.get("thumburl", "")]))
        time.sleep(1)
    out.write_text("\n".join(lines) + "\n")
    print(f"{len(lines)} regels → {out}")


def fetch(out: pathlib.Path):
    from PIL import Image  # alleen hier nodig

    spec = json.loads((ROOT / "docs/appstore/free_media.json").read_text())
    out.mkdir(parents=True, exist_ok=True)
    credits, bad = [], []
    for item in spec["images"]:
        f = item["file"] if item["file"].startswith("File:") else "File:" + item["file"]
        width = item.get("width", 1280)
        pages = info([f], width=width)
        if not pages or pages[0].get("missing") or not pages[0].get("imageinfo"):
            bad.append(f"{f}: niet gevonden")
            continue
        ii = pages[0]["imageinfo"][0]
        md = ii.get("extmetadata", {})
        lic = md.get("LicenseShortName", {}).get("value", "")
        if not licence_ok(lic):
            bad.append(f"{f}: licentie '{lic}' niet toegestaan")
            continue
        if item.get("license") and item["license"].lower() != lic.lower():
            print(f"  let op: {f}: verwacht '{item['license']}', Commons zegt '{lic}'")
        src = ii.get("thumburl") or ii["url"]
        req = urllib.request.Request(src, headers={"User-Agent": UA})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = r.read()
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 3:
                    raise
                print(f"  opnieuw {f} ({e})")
                time.sleep(5 + attempt * 5)
        im = Image.open(BytesIO(data)).convert("RGB")
        if im.width > width:
            im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
        name = item["id"] + ".jpg"
        im.save(out / name, "JPEG", quality=86, optimize=True, progressive=True)
        credits.append({
            "id": item["id"], "film": item["film"], "role": item.get("role", ""),
            "file": f, "page": ii.get("descriptionurl", ""), "license": lic,
            "licenseUrl": md.get("LicenseUrl", {}).get("value", ""),
            "artist": plain(md.get("Artist", {}).get("value", "")) or item.get("author", ""),
            "credit": item.get("credit", ""), "size": f"{im.width}x{im.height}",
        })
        print(f"{item['id']}: {f} [{lic}] {im.width}x{im.height}")
        time.sleep(0.5)
    if bad:
        print("\n".join("FOUT " + b for b in bad))
        raise SystemExit(1)
    (out / "credits.json").write_text(json.dumps(credits, indent=1, ensure_ascii=False))
    print(f"{len(credits)} afbeeldingen, licenties gecontroleerd")


if __name__ == "__main__":
    mode, target = sys.argv[1], pathlib.Path(sys.argv[2])
    if mode == "search":
        search(target, sys.argv[3:])
    else:
        fetch(target)
