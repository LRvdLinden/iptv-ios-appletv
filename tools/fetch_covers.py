"""Haalt echte covers van populaire films en series op via TMDB (met TMDB_API_KEY of TMDB_ACCESS_TOKEN)
voor de mockups, screenshots en de website. Draait in GitHub Actions (workflow 'Covers').
Resultaat: docs/covers/<slug>.jpg + docs/covers/covers.json (titel, jaar, soort, bron)."""
import json, os, pathlib, re, urllib.parse, urllib.request
from io import BytesIO
from PIL import Image

root = pathlib.Path(__file__).resolve().parent.parent
out = root / "docs" / "covers"
out.mkdir(parents=True, exist_ok=True)
key = os.environ.get("TMDB_API_KEY", "").strip()
if not key:
    raise SystemExit("Geen TMDB_API_KEY / TMDB_ACCESS_TOKEN — covers niet opgehaald.")

def get(path, **q):
    headers = {"Accept": "application/json", "User-Agent": "BingrMockups/1.0"}
    if key.startswith("eyJ"):          # v4-token
        headers["Authorization"] = f"Bearer {key}"
    else:
        q["api_key"] = key
    url = f"https://api.themoviedb.org/3{path}?{urllib.parse.urlencode(q)}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return json.loads(r.read())

def slug(t):
    return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")[:60]

items, seen = [], set()
for kind, path in (("movie", "/trending/movie/week"), ("tv", "/trending/tv/week"), ("movie", "/movie/popular"), ("tv", "/tv/popular")):
    for page in (1, 2):
        for r in get(path, page=page, language="en-US").get("results", []):
            if not r.get("poster_path") or r.get("adult"):
                continue
            title = r.get("title") or r.get("name") or ""
            s = slug(f"{kind}-{title}")
            if s in seen:
                continue
            seen.add(s)
            items.append((kind, title, (r.get("release_date") or r.get("first_air_date") or "")[:4], r["poster_path"], s))

# om en om film en serie, maximaal 48
movies = [i for i in items if i[0] == "movie"][:24]
shows = [i for i in items if i[0] == "tv"][:24]
mixed = [x for pair in zip(movies, shows) for x in pair]

meta = []
for kind, title, year, poster, s in mixed:
    try:
        req = urllib.request.Request(f"https://image.tmdb.org/t/p/w342{poster}", headers={"User-Agent": "BingrMockups/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            im = Image.open(BytesIO(r.read())).convert("RGB").resize((342, 513), Image.LANCZOS)
        im.save(out / f"{s}.jpg", quality=86, optimize=True, progressive=True)
        meta.append({"slug": s, "title": title, "year": year, "kind": kind, "source": "TMDB"})
    except Exception as e:
        print(f"fout bij {title}: {e}")

for old in out.glob("*.jpg"):
    if old.stem not in {m["slug"] for m in meta}:
        old.unlink()
(out / "covers.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))
(out / "CREDITS.md").write_text("# Covers\n\nFilm- en serieposters via The Movie Database (TMDB). "
                                "This product uses the TMDB API but is not endorsed or certified by TMDB.\n")
print(f"{len(meta)} covers")
