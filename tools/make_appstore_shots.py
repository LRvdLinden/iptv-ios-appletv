#!/usr/bin/env python3
"""App Store-screenshots in Bingr-stijl (workflow appstore-screenshots.yml).

Gebruik: make_appstore_shots.py <kale screenshots> <map met Inter-*.ttf> <uitvoermap>

Leest de kale screenshots van de screenshotmodus (iphone69/, iphone63/, ipad13/, appletv/, mac/) en maakt per set de
marketingversies op de exacte App Store-maten: zwart met een rode gloed, Engelse kop en ondertitel, de echte screenshot
met afgeronde hoeken. Alles RGB zonder alfakanaal. Daarnaast AppIcon-1024.png, de Top Shelf-afbeeldingen en README.txt.
"""
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
            fonts: pathlib.Path) -> Image.Image:
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

    # de screenshot: zo groot als past onder de tekst
    bottom_margin = int(h * (0.035 if not landscape else 0.05))
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


def main() -> None:
    src, fonts, out = (pathlib.Path(a) for a in sys.argv[1:4])
    out.mkdir(parents=True, exist_ok=True)
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
                img = compose(shot, w, h, landscape, title, subtitle, n == 1, fonts)
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

    (out / "README.txt").write_text(README)
    print("\n".join(report))


README = """Bingr - App Store screenshots (English)
=========================================

Made with the real Bingr apps in screenshot mode (demo library with made-up titles,
self-drawn artwork and made-up channels; no real movies, series, posters, channel logos,
brands or personal data; no prices or purchase buttons).

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

OTHER
  AppIcon-1024.png              App Store icon, 1024 x 1024, RGB without alpha
  AppleTV/TopShelf/             existing Top Shelf images of the tvOS app (reference only)

Order: 01 Home, 02 Detail (series), 03 Live TV, 04 TV guide, 05 Top 10, 06 Who's watching?,
07 Categories, 08 Multiview (iPad, Apple TV, Mac). The first image of every set carries the
note: "Bring your own IPTV subscription. Bingr does not provide any channels, movies or series."
"""

if __name__ == "__main__":
    main()
