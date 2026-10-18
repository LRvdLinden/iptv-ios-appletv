#!/usr/bin/env python3
"""Maakt de Top Shelf-afbeeldingen voor Apple TV (build 129); het app-icoon blijft ongewijzigd.

    python3 tools/fetch_free_media.py fetch /tmp/media     # vrije posters (licentie per bestand gecontroleerd)
    python3 tools/make_tvos_icon.py /tmp/media [previewmap]

Beeldtaal = het inlogscherm van het beheer (bingr-beheer/web/admin.css, .login-wall): een schuine, donkere muur van
filmposters (2:3, hoeken 10px, kolommen om-en-om verschoven, perspective rotateX(8deg) rotate(-11deg)), een donker
vignet met een rode gloed in het midden en daarvoor het woordmerk BINGR met de rode balk.

Alleen vrije posters: Blender open movies (CC BY) en films die in de EU en de VS publiek domein zijn, uit
docs/appstore/free_media.json (Wikimedia Commons). Nooit TMDB/IMDb-posters (docs/covers e.d.): het icoon gaat de
App Store in. De naamsvermelding komt in docs/appstore/tvos-icon-credits.txt.

Uitvoer (tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets): Top Shelf Image (1920x720, 3840x1440) en
Top Shelf Image Wide (2320x720, 4640x1440). tvOS toont de Top Shelf schermvullend achter de iconenrij, die over de
onderste ~35% valt: het logo (en de rode gloed) staan daarom in het bovenste deel, de muur vult het hele vlak.
"""
import json
import math
import pathlib
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from fetch_free_media import licence_ok  # noqa: E402

BRAND = ROOT / "tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
CREDITS = ROOT / "docs/appstore/tvos-icon-credits.txt"
RED = (0xE5, 0x09, 0x14)
FONTS = ["/usr/share/fonts/opentype/inter/InterDisplay-Black.otf", "/usr/share/fonts/opentype/inter/Inter-Black.otf",
         "/System/Library/Fonts/SFNS.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]

# vrije posters (ids uit docs/appstore/free_media.json); m13-keyart (videostil) bewust niet
POSTERS = ["m01-poster", "m02-poster", "m03-poster", "m04-poster", "m05-poster", "m06-poster", "m07-poster",
           "m08-poster", "m01-keyart", "m09-keyart", "m11-keyart", "m12-keyart", "m13-poster", "s01-poster",
           "s01-keyart", "s02-keyart"]

SS = 2  # supersampling voor zachte randen


# ---------------------------------------------------------------- posters

def load_posters(media: pathlib.Path):
    credits = {c["id"]: c for c in json.loads((media / "credits.json").read_text())}
    out, used = [], []
    for pid in POSTERS:
        c = credits.get(pid)
        if not c or not licence_ok(c["license"]):
            raise SystemExit(f"{pid}: ontbreekt of licentie niet toegestaan")
        im = Image.open(media / f"{pid}.jpg").convert("RGB")
        # iets minder verzadigd en donkerder: de posters zijn sfeer, het logo is de blikvanger
        im = ImageEnhance.Color(im).enhance(0.8)
        # lichte posters (wit papier, witte achtergrond) net zo donker als de rest: gemiddelde helderheid hoogstens ~0.27
        mean = np.asarray(im.convert("L"), np.float32).mean() / 255
        im = ImageEnhance.Contrast(im).enhance(0.9 if mean > 0.45 else 1.0)
        im = ImageEnhance.Brightness(im).enhance(min(0.72, 0.27 / max(mean, 1e-3)))
        out.append(im)
        used.append(c)
    return out, used


def cover(im: Image.Image, w: int, h: int) -> Image.Image:
    r = max(w / im.width, h / im.height)
    im = im.resize((max(w, round(im.width * r)), max(h, round(im.height * r))), Image.LANCZOS)
    l, t = (im.width - w) // 2, (im.height - h) // 2
    return im.crop((l, t, l + w, t + h))


def flat_wall(posters, pw: int, cols: int, rows: int, seed: int):
    """Platte muur: kolommen posters 2:3, even kolommen omhoog geschoven, met schaduw en dunne lichte rand."""
    ph = round(pw * 1.5)
    gap = round(pw * 0.084)
    rad = max(2, round(pw * 0.06))
    shift = round(ph * 0.36)
    W = cols * pw + (cols - 1) * gap
    H = rows * ph + (rows - 1) * gap
    wall = Image.new("RGB", (W, H), (6, 6, 7))
    shadow = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shadow)
    mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, pw - 1, ph - 1), rad, fill=255)
    rim = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(rim).rounded_rectangle((0, 0, pw - 1, ph - 1), rad, outline=30, width=max(1, pw // 160))
    tiles = [cover(p, pw, ph) for p in posters]
    rnd = random.Random(seed)
    grid = {}
    places = []
    for c in range(cols):
        y0 = -shift if c % 2 else 0
        for r in range(-1, rows + 1):
            # geen gelijke poster naast of boven elkaar
            bad = {grid.get((cc, rr)) for cc in (c - 2, c - 1, c) for rr in range(r - 2, r + 3)}
            choice = rnd.choice([i for i in range(len(tiles)) if i not in bad])
            grid[(c, r)] = choice
            x, y = c * (pw + gap), y0 + r * (ph + gap)
            places.append((choice, x, y))
            off = round(ph * 0.04)
            sd.rounded_rectangle((x, y + off, x + pw, y + ph + off), rad, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(pw * 0.12))
    wall.paste((0, 0, 0), (0, 0), shadow)
    white = Image.new("RGB", (pw, ph), (255, 255, 255))
    for i, x, y in places:
        wall.paste(tiles[i], (x, y), mask)
        wall.paste(white, (x, y), rim)
    return wall


def homography(src, dst):
    """Coëfficiënten voor Image.PERSPECTIVE: uitvoerpunt (dst) → bronpunt (src)."""
    A, b = [], []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return np.linalg.solve(np.array(A, float), np.array(b, float)).tolist()


def tilted_wall(posters, W: int, H: int, pw_frac: float, seed: int, drift=(0.0, 0.0)):
    """Covermuur zoals .login-wall: rotate(-11deg) en daarna perspective(d) rotateX(8deg), rond het midden."""
    W2, H2 = W * SS, H * SS
    pw = round(H2 * pw_frac)
    ph = round(pw * 1.5)
    gap = round(pw * 0.084)
    diag = math.hypot(W2, H2) * 1.25
    cols = math.ceil(diag / (pw + gap)) + 2
    rows = math.ceil(diag / (ph + gap)) + 2
    flat = flat_wall(posters, pw, cols, rows, seed)
    cx, cy = flat.width / 2 + drift[0] * pw, flat.height / 2 + drift[1] * ph
    a = math.radians(-11)
    t = math.radians(8)
    d = 1.0 * max(W2, H2 * 1.6)  # perspective, ongeveer de breedte van het beeld

    def fwd(u, v):
        x = u * math.cos(a) - v * math.sin(a)
        y = u * math.sin(a) + v * math.cos(a)
        z = y * math.sin(t)
        s = d / (d - z)
        return W2 / 2 + x * s, H2 / 2 + y * math.cos(t) * s

    R = diag / 2
    src = [(-R, -R), (R, -R), (R, R), (-R, R)]
    dst = [fwd(u, v) for u, v in src]
    coeffs = homography([(u + cx, v + cy) for u, v in src], dst)
    out = flat.transform((W2, H2), Image.PERSPECTIVE, coeffs, Image.BICUBIC, fillcolor=(6, 6, 7))
    return out.resize((W, H), Image.LANCZOS)


# ---------------------------------------------------------------- vignet en gloed

def radial(W, H, rx, ry, stops, cy=0.5):
    """Radiaal verloop (ellips rx, ry als fractie) met stops [(positie, waarde)] → float-array."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    r = np.sqrt(((xx + .5 - W / 2) / (W * rx)) ** 2 + ((yy + .5 - H * cy) / (H * ry)) ** 2)
    pos = [p for p, _ in stops]
    val = [v for _, v in stops]
    return np.interp(r, pos, val).astype(np.float32)


def middle_layer(W, H, wide=False, strength=1.0, cy=0.5):
    """Donker vignet (midden donker achter het logo, randen weer donkerder) + rode gloed: transparante PNG."""
    yy = (np.mgrid[0:H, 0:W][0].astype(np.float32) + .5) / H
    rx = 0.62 if wide else 0.75
    dark = radial(W, H, rx, 0.75, [(0, .74), (.45, .60), (.8, .36), (1.15, .55), (1.6, .80)], cy)
    lin = np.interp(yy, [0, .22, .75, 1], [.55, .0, .0, .62]).astype(np.float32)
    a_dark = 1 - (1 - dark * strength) * (1 - lin * strength)
    glow = radial(W, H, 0.30 if wide else 0.42, 0.42, [(0, .34), (.5, .2), (1, 0)], cy) * strength
    # rood over zwart (alpha-compositie van twee lagen in één)
    a = 1 - (1 - a_dark) * (1 - glow)
    rgb = np.zeros((H, W, 3), np.float32)
    rgb[...] = np.array(RED, np.float32)[None, None, :] * (glow / np.maximum(a, 1e-6))[..., None]
    out = np.dstack([np.clip(rgb, 0, 255), np.clip(a * 255, 0, 255)]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


# ---------------------------------------------------------------- logo

def font(size):
    for f in FONTS:
        if pathlib.Path(f).exists():
            return ImageFont.truetype(f, size)
    raise SystemExit("geen lettertype gevonden")


def logo_layer(W, H, text_w_frac, cy_frac=0.5):
    """Woordmerk BINGR (zwaarste gewicht, letter-spacing .02em) met de rode balk (.11em, 4% ingesprongen)."""
    W2, H2 = W * SS, H * SS
    # lettergrootte zo kiezen dat de tekst text_w_frac van de breedte is
    size = 100
    f = font(size)
    width = lambda f, s: f.getlength("BINGR") + 4 * 0.02 * s
    size = int(size * (W2 * text_w_frac) / width(f, size))
    f = font(size)
    tw = width(f, size)
    asc = f.getbbox("BINGR", anchor="ls")
    cap = -asc[1]  # hoogte boven de basislijn
    bar_gap, bar_h = 0.19 * size, 0.11 * size
    total = cap + bar_gap + bar_h
    base_y = H2 * cy_frac - total / 2 + cap
    x0 = (W2 - tw) / 2

    def draw_logo(img, fill_txt, fill_bar):
        dr = ImageDraw.Draw(img)
        x = x0
        for i, ch in enumerate("BINGR"):
            # kerning behouden: positie = lengte van het voorvoegsel + letter-spacing
            x = x0 + f.getlength("BINGR"[:i]) + i * 0.02 * size
            dr.text((x, base_y), ch, font=f, fill=fill_txt, anchor="ls")
        bx0, bx1 = x0 + tw * 0.04, x0 + tw * 0.96
        by = base_y + bar_gap
        dr.rounded_rectangle((bx0, by, bx1, by + bar_h), bar_h / 2, fill=fill_bar)

    # zachte schaduw (los van de achtergrond bij parallax) en een rode gloed onder de balk
    sh = Image.new("L", (W2, H2), 0)
    draw_logo(sh, 170, 170)
    sh = sh.filter(ImageFilter.GaussianBlur(size * 0.07))
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -size * 0.04))
    out = Image.new("RGBA", (W2, H2), (0, 0, 0, 0))
    out.paste((0, 0, 0, 255), (0, 0), sh)
    rg = Image.new("L", (W2, H2), 0)
    ImageDraw.Draw(rg).rounded_rectangle((x0 + tw * 0.04, base_y + bar_gap, x0 + tw * 0.96, base_y + bar_gap + bar_h),
                                         bar_h / 2, fill=150)
    rg = rg.filter(ImageFilter.GaussianBlur(size * 0.12))
    glow = Image.new("RGBA", (W2, H2), RED + (0,))
    glow.putalpha(rg)
    out = Image.alpha_composite(out, glow)
    fg = Image.new("RGBA", (W2, H2), (0, 0, 0, 0))
    draw_logo(fg, (255, 255, 255, 255), RED + (255,))
    out = Image.alpha_composite(out, fg)
    return out.resize((W, H), Image.LANCZOS)


# ---------------------------------------------------------------- schrijven

def write_json(p: pathlib.Path, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}


def write_stack(name: str, sizes, layers):
    """sizes = [(scale, W, H)], layers = {laagnaam: functie(W, H) → Image}; volgorde Front, Middle, Back."""
    stack = BRAND / name
    write_json(stack / "Contents.json", {"layers": [{"filename": f"{n}.imagestacklayer"} for n in layers], "info": INFO})
    for n, make in layers.items():
        d = stack / f"{n}.imagestacklayer"
        for old in (d / "Content.imageset").glob("*.png"):
            old.unlink()
        write_json(d / "Contents.json", {"info": INFO})
        imgs = []
        for scale, W, H in sizes:
            fn = f"{n.lower()}@{scale}.png"
            im = make(W, H)
            if n == "Back":
                im = im.convert("RGB")
            (d / "Content.imageset").mkdir(parents=True, exist_ok=True)
            im.save(d / "Content.imageset" / fn, optimize=True)
            imgs.append({"filename": fn, "idiom": "tv", "scale": scale})
        write_json(d / "Content.imageset/Contents.json", {"images": imgs, "info": INFO})


def flatten(back, middle, front):
    return Image.alpha_composite(Image.alpha_composite(back.convert("RGBA"), middle), front).convert("RGB")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    media = pathlib.Path(sys.argv[1])
    preview = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
    posters, used = load_posters(media)

    LOGO_Y = 0.34  # middelpunt van het logo (fractie van de hoogte), ruim boven de iconenrij
    for name, sizes in (("Top Shelf Image.imageset", [("1x", 1920, 720), ("2x", 3840, 1440)]),
                        ("Top Shelf Image Wide.imageset", [("1x", 2320, 720), ("2x", 4640, 1440)])):
        d = BRAND / name
        for old in d.glob("*.png"):
            old.unlink()
        imgs = []
        for scale, W, H in sizes:
            fn = f"topshelf@{scale}.png"
            img = flatten(tilted_wall(posters, W, H, 0.24, seed=7),
                          middle_layer(W, H, wide=True, cy=LOGO_Y),
                          logo_layer(W, H, 0.25 * 1920 * H / (720 * W), cy_frac=LOGO_Y))
            img.save(d / fn, optimize=True)
            imgs.append({"filename": fn, "idiom": "tv", "scale": scale})
        write_json(d / "Contents.json", {"images": imgs, "info": INFO})

    # naamsvermelding (CC BY vraagt dat)
    lines = ["Bingr - Top Shelf-afbeeldingen voor Apple TV (tools/make_tvos_icon.py)",
             "",
             "De covermuur op de achtergrond gebruikt alleen vrij te gebruiken filmposters van Wikimedia Commons:",
             "Blender open movies (Creative Commons Naamsvermelding) en films die in de EU en de VS publiek domein zijn.",
             "Geen posters van commerciële films. Verkleind, bijgesneden, donkerder gemaakt en schuin geplaatst.",
             ""]
    for c in used:
        artist = c["artist"] or c.get("credit", "")
        half = len(artist) // 2
        if len(artist) % 2 == 0 and artist[:half] == artist[half:]:  # Commons herhaalt soms de naam
            artist = artist[:half]
        lines += [f"- {c['film']} ({c['year']}): {c['file'].replace('File:', '')}",
                  f"  Maker: {artist}".rstrip(),
                  f"  Licentie: {c['license']}" + (f" ({c['licenseUrl']})" if c.get("licenseUrl") else ""),
                  f"  Bron: {c['page']}"]
    CREDITS.write_text("\n".join(lines) + "\n")

    if preview:
        make_previews(preview, posters)
    print(f"Top Shelf gemaakt met {len(used)} vrije posters; credits in {CREDITS.relative_to(ROOT)}")


def make_previews(out: pathlib.Path, posters):
    """Top Shelf (gewoon en breed) met een gesimuleerde iconenrij over de onderste 35%, alleen om te bekijken."""
    out.mkdir(parents=True, exist_ok=True)

    def with_dock(im):
        im = im.convert("RGBA")
        W, H = im.size
        dock = Image.new("RGBA", im.size, (0, 0, 0, 0))
        dr = ImageDraw.Draw(dock)
        top = round(H * 0.65)
        iw, ih, g = round(H * 0.42), round(H * 0.25), round(H * 0.04)
        n = W // (iw + g) + 1
        x0 = (W - (n * iw + (n - 1) * g)) // 2
        for i in range(n):
            x = x0 + i * (iw + g)
            dr.rounded_rectangle((x, top + g, x + iw, top + g + ih), round(H * 0.02),
                                 fill=(255, 255, 255, 40), outline=(255, 255, 255, 120), width=2)
        return Image.alpha_composite(im, dock).convert("RGB")

    ts = Image.open(BRAND / "Top Shelf Image.imageset/topshelf@1x.png")
    tw = Image.open(BRAND / "Top Shelf Image Wide.imageset/topshelf@1x.png")
    sheet = Image.new("RGB", (tw.width, ts.height + tw.height + 40), (40, 40, 44))
    sheet.paste(with_dock(ts), ((tw.width - ts.width) // 2, 0))
    sheet.paste(with_dock(tw), (0, ts.height + 40))
    sheet.save(out / "tvos-topshelf-preview.png")


if __name__ == "__main__":
    main()
