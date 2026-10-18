#!/usr/bin/env python3
"""App Store-screenshots in Bingr-stijl (workflow appstore-screenshots.yml).

Gebruik: make_appstore_shots.py <kale screenshots> <map met Inter-*.ttf> <uitvoermap>

Leest de kale screenshots van de screenshotmodus (iphone69/, iphone63/, ipad13/, appletv/, mac/) en maakt per set de
marketingversies op de exacte App Store-maten: zwart met een rode gloed, Engelse kop en ondertitel, de echte screenshot
met afgeronde hoeken. Alles RGB zonder alfakanaal. Daarnaast AppIcon-1024.png, de Top Shelf-afbeeldingen en README.txt.
"""
import json
import pathlib
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
RED = (229, 9, 20)

SCREENS = [  # volgorde in de App Store
    ("home", "Your own TV, beautifully organised", "Movies, series and live TV from your own playlist."),
    ("detail", "Pick up right where you left off", "Seasons, episodes and your progress, on every screen."),
    ("live", "All your channels, neatly sorted", "See what's on now and next on every channel."),
    ("guide", "Live TV with a real TV guide", "Scroll through today's programmes at a glance."),
    ("top10", "Always something to watch", "Top 10, My List and picks for you."),
    ("picker", "A profile for everyone", "Own lists, progress and settings for every viewer."),
    ("categories", "Only the channels you want", "Switch whole categories on or off in one tap."),
    ("multiview", "Four streams at once", "Watch up to four live channels side by side."),
]
DISCLAIMER = "Bring your own IPTV subscription. Bingr does not provide any channels, movies or series."

# map van de kale screenshots → (uitvoermap, maten [(breedte, hoogte, submap)], liggend?)
SETS = [
    ("iphone69", "iPhone-6.9in", [(1320, 2868, "")], False),
    ("iphone63", "iPhone-6.3in", [(1206, 2622, "")], False),
    ("ipad13", "iPad-13in", [(2064, 2752, "")], False),
    ("appletv", "AppleTV", [(1920, 1080, ""), (3840, 2160, "3840x2160")], True),
    ("mac", "Mac", [(2880, 1800, "")], True),
]


def font(fonts: pathlib.Path, weight: str, size: int) -> ImageFont.FreeTypeFont:
    for name in (f"Inter-{weight}.ttf", f"Inter{weight}.ttf"):
        hits = sorted(fonts.rglob(name))
        if hits:
            return ImageFont.truetype(str(hits[0]), size)
    var = sorted(fonts.rglob("InterVariable.ttf"))
    if var:
        f = ImageFont.truetype(str(var[0]), size)
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
        return f
    return ImageFont.truetype("DejaVuSans-Bold.ttf" if weight in ("Bold", "ExtraBold") else "DejaVuSans.ttf", size)


def rgb(img: Image.Image) -> Image.Image:
    """Zonder alfakanaal (transparant → zwart)."""
    if img.mode == "RGB":
        return img
    img = img.convert("RGBA")
    bg = Image.new("RGB", img.size, (0, 0, 0))
    bg.paste(img, mask=img.split()[3])
    return bg


def background(w: int, h: int, landscape: bool) -> Image.Image:
    """Zwart met een rode gloed (Bingr-stijl)."""
    small = (max(64, w // 8), max(64, h // 8))
    glow = Image.new("RGB", small, (0, 0, 0))
    d = ImageDraw.Draw(glow)
    sw, sh = small
    cx, cy = sw / 2, sh * (0.05 if not landscape else 0.0)
    rx, ry = sw * (0.75 if not landscape else 0.55), sh * (0.42 if not landscape else 0.75)
    d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=(150, 6, 14))
    d.ellipse([cx - rx * 0.55, cy - ry * 0.55, cx + rx * 0.55, cy + ry * 0.55], fill=RED)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=max(sw, sh) * 0.12))
    glow = glow.resize((w, h), Image.LANCZOS)
    # zacht naar zwart onderaan
    fade = Image.linear_gradient("L").resize((w, h))
    return Image.composite(Image.new("RGB", (w, h), (0, 0, 0)), glow, fade.point(lambda v: min(255, int(v * 1.25))))


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def wrap(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if draw.textlength(t, font=f) <= max_w or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = wd
    if cur:
        lines.append(cur)
    return lines


def fit_font(draw, text, fonts, weight, size, max_w, max_lines):
    while size > 10:
        f = font(fonts, weight, size)
        lines = wrap(draw, text, f, max_w)
        if len(lines) <= max_lines and all(draw.textlength(l, font=f) <= max_w for l in lines):
            return f, lines
        size = int(size * 0.94)
    f = font(fonts, weight, size)
    return f, wrap(draw, text, f, max_w)


def compose(shot: Image.Image, w: int, h: int, landscape: bool, title: str, subtitle: str, disclaimer: bool,
            fonts: pathlib.Path, credit: str = "") -> Image.Image:
    canvas = background(w, h, landscape)
    draw = ImageDraw.Draw(canvas)
    u = min(w, h)
    margin = int(w * 0.07)
    max_w = w - 2 * margin if not landscape else int(w * 0.8)
    title_size = int(u * (0.075 if not landscape else 0.06))
    tf, tlines = fit_font(draw, title, fonts, "ExtraBold", title_size, max_w, 2)
    sf, slines = fit_font(draw, subtitle, fonts, "Medium", int(title_size * 0.46), max_w, 2)
    df, dlines = fit_font(draw, DISCLAIMER, fonts, "Regular", int(title_size * 0.27), max_w, 2)

    def line_h(f):
        a, d = f.getmetrics()
        return a + d

    top = int(h * (0.045 if not landscape else 0.05))
    y = top
    for l in tlines:
        tw = draw.textlength(l, font=tf)
        draw.text(((w - tw) / 2, y), l, font=tf, fill=(255, 255, 255))
        y += int(line_h(tf) * 1.02)
    y += int(line_h(sf) * 0.25)
    for l in slines:
        tw = draw.textlength(l, font=sf)
        draw.text(((w - tw) / 2, y), l, font=sf, fill=(225, 225, 225))
        y += int(line_h(sf) * 1.1)
    # ruimte voor de disclaimer altijd reserveren (zelfde opmaak in de hele set); alleen op de eerste tekenen
    dy = y + int(line_h(df) * 0.3)
    if disclaimer:
        for l in dlines:
            tw = draw.textlength(l, font=df)
            draw.text(((w - tw) / 2, dy), l, font=df, fill=(170, 170, 170))
            dy += int(line_h(df) * 1.15)
    y += int(line_h(df) * (1.15 * max(1, len(dlines)) + 0.3)) + int(h * 0.02)

    # naamsvermelding (CC BY) klein onderaan
    cf, clines = fit_font(draw, credit, fonts, "Medium", max(14, int(u * (0.0125 if not landscape else 0.016))),
                          int(w * 0.92), 2) if credit else (None, [])
    credit_h = int(line_h(cf) * 1.15 * len(clines)) + int(u * 0.012) if clines else 0
    if clines:
        cy = h - credit_h
        for l in clines:
            tw = draw.textlength(l, font=cf)
            draw.text(((w - tw) / 2, cy), l, font=cf, fill=(190, 190, 190))
            cy += int(line_h(cf) * 1.15)

    # de screenshot: zo groot als past onder de tekst
    bottom_margin = int(h * (0.035 if not landscape else 0.05)) + credit_h
    avail_h = h - y - bottom_margin
    avail_w = int(w * (0.86 if not landscape else 0.86))
    sw, sh = shot.size
    scale = min(avail_w / sw, avail_h / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    img = shot.resize((nw, nh), Image.LANCZOS)
    radius = int(min(nw, nh) * (0.055 if not landscape else 0.025))
    img = rounded(img, radius)
    x0 = (w - nw) // 2
    y0 = y + (avail_h - nh) // 2 if landscape else y
    # rand en schaduw
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([x0, y0 + int(u * 0.01), x0 + nw, y0 + nh + int(u * 0.01)], radius=radius, fill=(0, 0, 0, 200))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=u * 0.02))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    canvas.alpha_composite(img, (x0, y0))
    border = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([x0, y0, x0 + nw - 1, y0 + nh - 1], radius=radius,
                                             outline=(255, 255, 255, 46), width=max(2, u // 500))
    canvas = Image.alpha_composite(canvas, border)
    return rgb(canvas)


def trim_black(img: Image.Image) -> Image.Image:
    """Mac-venster: zwarte/transparante randen eraf (screencapture zonder schaduw)."""
    im = rgb(img)
    bbox = ImageChops.difference(im, Image.new("RGB", im.size, (0, 0, 0))).getbbox()
    return im.crop(bbox) if bbox else im


# ---------------------------------------------------------------------------------------------------------------
# naamsvermelding (vrije film-afbeeldingen, zie docs/appstore/free_media.json en tools/fetch_free_media.py)

def load_credits(src: pathlib.Path) -> list[dict]:
    p = src / "_credits.json"
    return json.loads(p.read_text()) if p.exists() else []


def films_on(screen: str, credits: list[dict]) -> list[dict]:
    """Films waarvan beeld op dit scherm kan staan (zie SCREEN_FILMS), in vaste volgorde, één per film."""
    wanted = SCREEN_FILMS.get(screen)
    seen, out = set(), []
    for c in credits:
        if c["film"] in seen or (wanted is not None and c["film"] not in wanted):
            continue
        seen.add(c["film"])
        out.append(c)
    return out


def credit_line(items: list[dict]) -> str:
    """Bv. "Film images: Sintel, Spring © Blender Foundation | blender.org | CC BY · Nosferatu (1922): public domain"."""
    cc = [c for c in items if c["license"].lower().startswith("cc by")]
    pd = [c for c in items if not c["license"].lower().startswith("cc by")]
    parts = []
    if cc:
        lic = sorted({c["license"] for c in cc})
        parts.append(", ".join(c["film"] for c in cc) + " © Blender Foundation | blender.org | " + " / ".join(lic))
    if pd:
        parts.append(", ".join(f'{c["film"]} ({c["year"]})' if c.get("year") else c["film"] for c in pd) + ": public domain")
    return ("Film images: " + " · ".join(parts)) if parts else ""


def write_credits(out: pathlib.Path, credits: list[dict]) -> None:
    lines = [
        "Bingr - App Store images: credits",
        "=================================",
        "",
        "The movie and series artwork in these screenshots and promotional images comes from films that are free",
        "to use worldwide: Blender open movies (Creative Commons Attribution, (c) Blender Foundation | blender.org)",
        "and silent films that are in the public domain in the EU and the US (published before 1931, all authors",
        "died more than 70 years ago). Channels, TV guide, channel logos and profile names are made up.",
        "",
        "Changes: images were resized and cropped to fit the app layout; on posters made from a film frame the",
        "title was added by the app. Frames from videos were extracted at the stated time.",
        "",
    ]
    for c in credits:
        lines += [
            f'{c["id"]}  -  {c["film"]}' + (f' ({c["year"]})' if c.get("year") else ""),
            f'  Image:   {c["file"]}' + (f' (frame at {c["seek"]} s)' if c.get("seek") is not None else ""),
            f'  Author:  {c["artist"]}',
            f'  Licence: {c["license"]}' + (f' - {c["licenseUrl"]}' if c.get("licenseUrl") else ""),
            f'  Source:  {c["page"]}',
            "",
        ]
    (out / "CREDITS.txt").write_text("\n".join(lines))


# ---------------------------------------------------------------------------------------------------------------
# promo-afbeeldingen voor App Store Connect (Header en Search Results)

PROMO_TITLE = "Your own TV, beautifully organised"
PROMO_SUB = "Movies, series and live TV from your own playlist."
PROMO_PLATFORMS = "iPhone \u00b7 iPad \u00b7 Mac \u00b7 Apple TV"


def device(shot: Image.Image, width: int, kind: str) -> Image.Image:
    """Screenshot in een eenvoudig, donker apparaatkader (RGBA)."""
    sw, sh = shot.size
    bez = {"phone": 0.045, "pad": 0.035, "tv": 0.012}[kind]
    b = int(width * bez)
    inner_w = width - 2 * b
    inner_h = round(sh * inner_w / sw)
    img = shot.resize((inner_w, inner_h), Image.LANCZOS)
    r_out = int(width * {"phone": 0.16, "pad": 0.07, "tv": 0.015}[kind])
    r_in = max(2, r_out - b)
    frame = Image.new("RGBA", (width, inner_h + 2 * b), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle([0, 0, width - 1, inner_h + 2 * b - 1], radius=r_out, fill=(22, 22, 24, 255),
                        outline=(70, 70, 76, 255), width=max(2, b // 6))
    frame.alpha_composite(rounded(img, r_in), (b, b))
    if kind == "tv":  # voet onder het scherm
        stand_w, stand_h = int(width * 0.18), int(width * 0.03)
        full = Image.new("RGBA", (width, frame.size[1] + stand_h), (0, 0, 0, 0))
        ImageDraw.Draw(full).rounded_rectangle([(width - stand_w) // 2, frame.size[1] - 4, (width + stand_w) // 2,
                                                frame.size[1] + stand_h], radius=stand_h // 3, fill=(40, 40, 44, 255))
        full.alpha_composite(frame, (0, 0))
        frame = full
    return frame


def paste_shadow(canvas: Image.Image, img: Image.Image, x: int, y: int, blur: int) -> None:
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = img.split()[3].point(lambda v: int(v * 0.75))
    sh.paste((0, 0, 0, 255), (x, y + blur // 3), a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(sh)
    canvas.alpha_composite(img, (x, y))


def logo(fonts: pathlib.Path, size: int) -> Image.Image:
    """BINGR met de rode streep over de hele breedte van het woord eronder."""
    f = font(fonts, "Black", size)
    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    l, t, r, b = tmp.textbbox((0, 0), "BINGR", font=f)
    bar = max(4, int(size * 0.09))
    gap = int(size * 0.1)
    img = Image.new("RGBA", (r - l, b - t + gap + bar), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((-l, -t), "BINGR", font=f, fill=(255, 255, 255, 255))
    d.rectangle([0, b - t + gap, r - l - 1, b - t + gap + bar - 1], fill=RED + (255,))
    return img


def promo(w: int, h: int, safe: tuple[int, int], shots: dict, fonts: pathlib.Path, credit: str) -> Image.Image:
    """Zwart met rode gloed; links logo + boodschap, rechts een collage (Apple TV, iPad, iPhone). Alles binnen `safe`."""
    sw, sh = safe
    sx, sy = (w - sw) // 2, (h - sh) // 2
    inset = int(min(sw, sh) * 0.05)  # wat lucht binnen de veilige zone
    sx, sy, sw, sh = sx + inset, sy + inset, sw - 2 * inset, sh - 2 * inset
    canvas = background(w, h, True).convert("RGBA")
    # extra gloed achter de collage
    glow = Image.new("RGB", (w // 8, h // 8), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse([w // 8 * 0.45, h // 8 * 0.1, w // 8 * 1.05, h // 8 * 0.95], fill=(120, 4, 10))
    glow = glow.filter(ImageFilter.GaussianBlur(w // 8 * 0.08)).resize((w, h), Image.LANCZOS)
    canvas = Image.composite(canvas, Image.merge("RGBA", (*glow.split(), Image.new("L", (w, h), 255))),
                             Image.new("L", (w, h), 150))
    draw = ImageDraw.Draw(canvas)
    u = sh
    # tekstkolom
    text_w = int(sw * 0.36)
    tx = sx + int(sw * 0.02)
    lg = logo(fonts, int(u * 0.085))
    tf, tl = fit_font(draw, PROMO_TITLE, fonts, "ExtraBold", int(u * 0.095), text_w, 3)
    sf, sl = fit_font(draw, PROMO_SUB, fonts, "Medium", int(u * 0.042), text_w, 3)
    pf = font(fonts, "SemiBold", int(u * 0.034))

    def lh(f):
        a, d = f.getmetrics()
        return a + d

    block = lg.size[1] + int(u * 0.07) + len(tl) * int(lh(tf) * 1.02) + int(u * 0.03) + len(sl) * int(lh(sf) * 1.12) \
        + int(u * 0.05) + lh(pf)
    y = sy + (sh - block) // 2
    canvas.alpha_composite(lg, (tx, y))
    y += lg.size[1] + int(u * 0.07)
    for l in tl:
        draw.text((tx, y), l, font=tf, fill=(255, 255, 255))
        y += int(lh(tf) * 1.02)
    y += int(u * 0.03)
    for l in sl:
        draw.text((tx, y), l, font=sf, fill=(225, 225, 225))
        y += int(lh(sf) * 1.12)
    y += int(u * 0.05)
    draw.text((tx, y), PROMO_PLATFORMS, font=pf, fill=(229, 9, 20))

    # collage rechts: Apple TV groot, iPad links ervoor, iPhone rechts ervoor
    cx0 = sx + int(sw * 0.41)
    cw = sx + sw - cx0
    tv = device(shots["tv"], int(cw * 0.86), "tv")
    pad = device(shots["pad"], int(cw * 0.30), "pad")
    phone = device(shots["phone"], int(cw * 0.17), "phone")
    # hoogte begrenzen tot de veilige zone
    total_h = int(tv.size[1] * 0.62 + pad.size[1])
    if total_h > sh * 0.94:
        f = sh * 0.94 / total_h
        tv = device(shots["tv"], int(tv.size[0] * f), "tv")
        pad = device(shots["pad"], int(pad.size[0] * f), "pad")
        phone = device(shots["phone"], int(phone.size[0] * f), "phone")
        total_h = int(tv.size[1] * 0.62 + pad.size[1])
    top = sy + (sh - total_h) // 2
    tvx = cx0 + (cw - tv.size[0]) // 2 + int(cw * 0.04)
    blur = int(u * 0.02)
    paste_shadow(canvas, tv, tvx, top, blur)
    paste_shadow(canvas, pad, cx0 + int(cw * 0.02), top + int(tv.size[1] * 0.62) + pad.size[1] - pad.size[1], blur)
    paste_shadow(canvas, phone, cx0 + cw - phone.size[0] - int(cw * 0.01), top + total_h - phone.size[1], blur)
    out = rgb(canvas)
    if credit:
        d = ImageDraw.Draw(out)
        cf, cl = fit_font(d, credit, fonts, "Medium", max(14, int(u * 0.016)), int(sw * 0.62), 2)
        yy = sy + sh - int(lh(cf) * 1.15 * len(cl)) - int(u * 0.004)
        for l in cl:
            tw = d.textlength(l, font=cf)
            d.text((sx + sw - tw - int(sw * 0.005), yy), l, font=cf, fill=(170, 170, 170))
            yy += int(lh(cf) * 1.15)
    return out


def make_promos(src: pathlib.Path, out: pathlib.Path, fonts: pathlib.Path, credits: list[dict]) -> list[str]:
    def raw(key, name):
        p = src / key / f"{name}.png"
        return rgb(Image.open(p)) if p.exists() else None
    shots = {"tv": raw("appletv", "home"), "pad": raw("ipad13", "detail") or raw("ipad13", "home"),
             "phone": raw("iphone69", "home") or raw("iphone63", "home")}
    if any(v is None for v in shots.values()):
        return ["Promo: screenshots ontbreken"]
    films = {c["film"] for key in ("home", "detail") for c in films_on(key, credits)}
    credit = credit_line([c for c in films_on("", credits) if c["film"] in films])
    d = out / "Promo"
    d.mkdir(parents=True, exist_ok=True)
    report = []
    for name, w, h, safe in [("Header-3840x1646", 3840, 1646, (3840, 1646)),
                             ("Search-3840x2560", 3840, 2560, (3840, 2560)),
                             ("Search-1920x1280", 1920, 1280, (1920, 1280)),
                             ("Universal-5244x2950", 5244, 2950, (4425, 2247))]:
        img = promo(w, h, safe, shots, fonts, credit)
        assert img.size == (w, h) and img.mode == "RGB"
        img.save(d / f"{name}.png", optimize=True)
        report.append(f"Promo/{name}.png")
    # controle-uitsneden van de universele afbeelding (niet om te uploaden)
    u = Image.open(d / "Universal-5244x2950.png")
    chk = out.parent / "_promo-crops"
    chk.mkdir(parents=True, exist_ok=True)
    u.crop((0, (2950 - 2247) // 2, 5244, (2950 - 2247) // 2 + 2247)).save(chk / "Universal-crop-21x9.png")
    u.crop(((5244 - 4425) // 2, 0, (5244 - 4425) // 2 + 4425, 2950)).save(chk / "Universal-crop-3x2.png")
    return report


# welke films op welk scherm in beeld kunnen zijn (None = alle)
SCREEN_FILMS: dict[str, set[str] | None] = {}


def main() -> None:
    src, fonts, out = (pathlib.Path(a) for a in sys.argv[1:4])
    out.mkdir(parents=True, exist_ok=True)
    credits = load_credits(src)
    report = []
    for key, folder, sizes, landscape in SETS:
        sdir = src / key
        if not sdir.is_dir():
            report.append(f"{folder}: ontbreekt")
            continue
        raw_dir = out / folder / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)
        n = 0
        for name, title, subtitle in SCREENS:
            p = sdir / f"{name}.png"
            if not p.exists():
                continue
            shot = rgb(Image.open(p))
            n += 1
            prefix = f"{n:02d}-{name}"
            # kaal (RGB); Apple TV: 1920×1080 en (indien echt zo groot) 3840×2160
            if key == "appletv":
                if shot.size[0] >= 3840:
                    shot.resize((3840, 2160), Image.LANCZOS).save(raw_dir / f"{prefix}-3840x2160.png")
                shot.resize((1920, 1080), Image.LANCZOS).save(raw_dir / f"{prefix}.png")
            else:
                shot.save(raw_dir / f"{prefix}.png")
            for w, h, sub in sizes:
                d = out / folder / sub if sub else out / folder
                d.mkdir(parents=True, exist_ok=True)
                img = compose(shot, w, h, landscape, title, subtitle, n == 1, fonts,
                              credit_line(films_on(name, credits)))
                assert img.size == (w, h) and img.mode == "RGB"
                img.save(d / f"{prefix}.png", optimize=True)
        report.append(f"{folder}: {n} screenshots")

    # app-icoon (RGB, zonder alfa) en de Top Shelf-afbeeldingen van tvOS (ter referentie)
    icon = rgb(Image.open(ROOT / "iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
    icon.save(out / "AppIcon-1024.png")
    shelf = ROOT / "tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    tdir = out / "AppleTV" / "TopShelf"
    tdir.mkdir(parents=True, exist_ok=True)
    for p in sorted(shelf.rglob("*.png")):
        if p.parent.name.startswith("Top Shelf Image"):
            im = rgb(Image.open(p))
            im.save(tdir / f"{p.parent.stem.replace(' ', '')}-{im.size[0]}x{im.size[1]}.png")

    if credits:
        write_credits(out, credits)
    report += make_promos(src, out, fonts, credits)
    (out / "README.txt").write_text(README)
    print("\n".join(report))


README = """Bingr - App Store screenshots (English)
=========================================

Made with the real Bingr apps in screenshot mode. The demo library holds real films that
are free to use worldwide: Blender open movies (Creative Commons Attribution, (c) Blender
Foundation | blender.org) and silent films in the public domain in the EU and the US.
Every image, its author, licence and source is listed in CREDITS.txt; images with CC BY
material carry a short credit line at the bottom. Channels, TV guide, channel logos and
profile names are made up (no real channels or brands). No personal data, no prices or
purchase buttons.

Each folder: numbered marketing screenshots (01-home.png ...) to upload, plus raw/ with
the plain screenshots. All PNG, RGB without alpha channel, max. 10 per set.

REQUIRED in App Store Connect
  iPhone-6.3in/   1206 x 2622   iPhone 6.3" display (Dynamic Island, medium) - required
  iPad-13in/      2064 x 2752   iPad 13" display - required for the iPad app
  AppleTV/        1920 x 1080   Apple TV (tvOS app) - required
                  AppleTV/3840x2160/ has the same set at 3840 x 2160 (also accepted)
  Mac/            2880 x 1800   Mac (16:10) - required for the macOS app

OPTIONAL
  iPhone-6.9in/   1320 x 2868   iPhone 6.9" display (Dynamic Island, large); with this set
                                the 6.5" display is not needed

PROMOTIONAL ARTWORK (App Store Connect: product page header and search results)
  Promo/Header-3840x1646.png    21:9, product page header
  Promo/Search-3840x2560.png    3:2, search results
  Promo/Search-1920x1280.png    3:2, search results (smaller)
  Promo/Universal-5244x2950.png 16:9, for both places: all text and the main image sit inside
                                the centre 4425 x 2247 (21:9 and 3:2 crops keep everything)

OTHER
  CREDITS.txt                   film images: title, author, licence and source per image
  AppIcon-1024.png              App Store icon, 1024 x 1024, RGB without alpha
  AppleTV/TopShelf/             existing Top Shelf images of the tvOS app (reference only)

Order: 01 Home, 02 Detail (series), 03 Live TV, 04 TV guide, 05 Top 10, 06 Who's watching?,
07 Categories, 08 Multiview (iPad, Apple TV, Mac). The first image of every set carries the
note: "Bring your own IPTV subscription. Bingr does not provide any channels, movies or series."
"""

if __name__ == "__main__":
    main()
