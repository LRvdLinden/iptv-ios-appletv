"""Haalt echte posters op van vrij te gebruiken films (publiek domein / Creative Commons, via Wikimedia Commons)
voor de mockups en de website. Draait in GitHub Actions (workflow 'Covers'); alleen afbeeldingen van
Wikimedia Commons worden gebruikt (geen 'fair use'-posters van Wikipedia zelf).
Resultaat: docs/covers/<slug>.jpg + docs/covers/covers.json (titel, jaar, bron, licentie-pagina)."""
import json, pathlib, re, time, urllib.parse, urllib.request
from io import BytesIO
from PIL import Image

root = pathlib.Path(__file__).resolve().parent.parent
out = root / "docs" / "covers"
out.mkdir(parents=True, exist_ok=True)
UA = {"User-Agent": "BingrMockups/1.0 (https://github.com/LRvdLinden/iptv-ios-appletv)"}

# (Wikipedia-artikel, weergavetitel, jaar)
TITLES = [
    ("Big Buck Bunny", "Big Buck Bunny", 2008), ("Sintel", "Sintel", 2010), ("Tears of Steel", "Tears of Steel", 2012),
    ("Elephants Dream", "Elephants Dream", 2006), ("Cosmos Laundromat", "Cosmos Laundromat", 2015),
    ("Spring (2019 film)", "Spring", 2019), ("Sprite Fright", "Sprite Fright", 2021), ("Charge (2022 film)", "Charge", 2022),
    ("Agent 327: Operation Barbershop", "Agent 327", 2017), ("Caminandes", "Caminandes", 2013),
    ("Nosferatu", "Nosferatu", 1922), ("Metropolis (1927 film)", "Metropolis", 1927), ("The General (1926 film)", "The General", 1926),
    ("Night of the Living Dead", "Night of the Living Dead", 1968), ("The Kid (1921 film)", "The Kid", 1921),
    ("Sherlock Jr.", "Sherlock Jr.", 1924), ("Safety Last!", "Safety Last!", 1923),
    ("The Phantom of the Opera (1925 film)", "The Phantom of the Opera", 1925),
    ("The Cabinet of Dr. Caligari", "The Cabinet of Dr. Caligari", 1920), ("A Trip to the Moon", "A Trip to the Moon", 1902),
    ("His Girl Friday", "His Girl Friday", 1940), ("Charade (1963 film)", "Charade", 1963), ("Carnival of Souls", "Carnival of Souls", 1962),
    ("Detour (1945 film)", "Detour", 1945), ("The Little Shop of Horrors", "The Little Shop of Horrors", 1960),
    ("Plan 9 from Outer Space", "Plan 9 from Outer Space", 1957), ("The Gold Rush", "The Gold Rush", 1925),
    ("Steamboat Bill, Jr.", "Steamboat Bill, Jr.", 1928), ("The Lost World (1925 film)", "The Lost World", 1925),
    ("Battleship Potemkin", "Battleship Potemkin", 1925), ("Sunrise: A Song of Two Humans", "Sunrise", 1927),
    ("The Hunchback of Notre Dame (1923 film)", "The Hunchback of Notre Dame", 1923), ("Häxan", "Häxan", 1922),
    ("The Last Man on Earth (1964 film)", "The Last Man on Earth", 1964), ("Reefer Madness", "Reefer Madness", 1936),
    ("D.O.A. (1949 film)", "D.O.A.", 1949), ("The Man with the Golden Arm", "The Man with the Golden Arm", 1955),
]

def get(url, raw=False):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
    return data if raw else json.loads(data)

def slug(t):
    return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")

meta = []
for article, title, year in TITLES:
    try:
        q = urllib.parse.urlencode({"action": "query", "titles": article, "prop": "pageimages", "piprop": "original",
                                    "format": "json", "redirects": 1})
        pages = get(f"https://en.wikipedia.org/w/api.php?{q}")["query"]["pages"]
        img = next(iter(pages.values())).get("original", {}).get("source")
        if not img or "/wikipedia/commons/" not in img:
            print(f"overgeslagen (geen vrije Commons-poster): {title} -> {img}")
            continue
        fname = urllib.parse.unquote(img.rsplit("/", 1)[1])
        info = get("https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode({
            "action": "query", "titles": f"File:{fname}", "prop": "imageinfo", "iiprop": "extmetadata|url",
            "iiurlwidth": 600, "format": "json"}))
        ii = next(iter(info["query"]["pages"].values()))["imageinfo"][0]
        lic = ii.get("extmetadata", {}).get("LicenseShortName", {}).get("value", "?")
        thumb = ii.get("thumburl") or img
        im = Image.open(BytesIO(get(thumb, raw=True))).convert("RGB")
        # naar 2:3 bijsnijden (posterformaat) en verkleinen
        w, h = im.size
        if w / h > 2 / 3:
            nw = int(h * 2 / 3); im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
        else:
            nh = int(w * 3 / 2); im = im.crop((0, 0, w, min(h, nh)))
        im = im.resize((360, 540), Image.LANCZOS)
        s = slug(title)
        im.save(out / f"{s}.jpg", quality=86, optimize=True, progressive=True)
        meta.append({"slug": s, "title": title, "year": year, "license": lic,
                     "source": ii.get("descriptionurl", img)})
        print(f"ok: {title} ({lic})")
        time.sleep(0.5)
    except Exception as e:
        print(f"fout bij {title}: {e}")

(out / "covers.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))
(out / "CREDITS.md").write_text("# Posters\n\nVrij te gebruiken posters via Wikimedia Commons (publiek domein of Creative Commons).\n\n" +
    "\n".join(f"- **{m['title']}** ({m['year']}) — {m['license']} — {m['source']}" for m in meta) + "\n")
print(f"{len(meta)} posters")
