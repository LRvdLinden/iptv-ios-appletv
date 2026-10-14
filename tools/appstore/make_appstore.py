"""App Store-afbeeldingen voor Bingr (iPhone, iPad, Apple TV, Mac en banners), NL en EN.

Gebruikt de ontwerpschermen uit docs/mockups/mockups.html ZONDER echte posters (alleen verzonnen titels en eigen
kleurvlakken: App Review accepteert geen auteursrechtelijk beschermde covers of zenderlogo's in een IPTV-app).
Gebruik: python3 tools/appstore/make_appstore.py [uitvoermap]   (standaard: build/appstore)
"""
import pathlib, sys, html as H
from playwright.sync_api import sync_playwright
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
MOCK = (ROOT / "docs/mockups/mockups.html").as_uri()
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/appstore").resolve()
RAW = OUT / "_raw"
RED = "#E50914"

# verzonnen namen i.p.v. bestaande programma's
FIX = "document.querySelectorAll('*').forEach(e=>{for(const n of e.childNodes){if(n.nodeType===3){n.textContent=n.textContent.replace(/Studio Voetbal/g,'Voetbalavond').replace(/Football Studio/g,'Football Night')}}})"

T = {
 "nl": {
  "tag": "Je eigen IPTV, op elk scherm in huis.",
  "sub": "Bingr is de speler voor je eigen IPTV-abonnement. Bingr levert zelf geen zenders, films of series.",
  "phone": [
   ("home", "Al je films, series en zenders", "Eén overzichtelijk thuisscherm, net als je gewend bent."),
   ("picker", "Een profiel voor iedereen", "Eigen lijst, voortgang en kinderprofielen met pincode."),
   ("guide", "Live tv met tv-gids", "Zap, kijk terug en zie wat er straks komt."),
   ("detail", "Alles over elke titel", "Seizoenen, afleveringen, beoordelingen en trailers."),
   ("top10", "Ontdek wat populair is", "Top 10, Voor jou en Verder kijken."),
   ("category", "Blader per categorie", "Per genre of de categorieën van je server."),
   ("settings", "Mijn Bingr", "Statistieken, collecties, Trakt en je apparaten."),
   ("add", "Gebruik je eigen IPTV", "Xtream Codes, M3U, Plex of Jellyfin. Bingr levert zelf geen content."),
  ],
  "tv": [
   ("home", "Gemaakt voor je tv"), ("picker", "Profielen voor het hele gezin"), ("guide", "Live tv met tv-gids"),
   ("detail", "Series en afleveringen"), ("multiview", "Multiview: tot vier streams tegelijk"), ("live", "Zappen zoals je gewend bent"),
  ],
 },
 "en": {
  "tag": "Your own IPTV, on every screen at home.",
  "sub": "Bingr is the player for your own IPTV subscription. Bingr itself provides no channels, movies or series.",
  "phone": [
   ("home", "All your movies, series and channels", "One clear home screen, just like you're used to."),
   ("picker", "A profile for everyone", "Own list, progress and kids profiles with a PIN."),
   ("guide", "Live TV with a TV guide", "Zap, catch up and see what's on next."),
   ("detail", "Everything about every title", "Seasons, episodes, ratings and trailers."),
   ("top10", "Discover what's popular", "Top 10, For you and Continue watching."),
   ("category", "Browse by category", "By genre or your server's own categories."),
   ("settings", "My Bingr", "Statistics, collections, Trakt and your devices."),
   ("add", "Use your own IPTV", "Xtream Codes, M3U, Plex or Jellyfin. Bingr provides no content."),
  ],
  "tv": [
   ("home", "Made for your TV"), ("picker", "Profiles for the whole family"), ("guide", "Live TV with a TV guide"),
   ("detail", "Series and episodes"), ("multiview", "Multiview: up to four streams at once"), ("live", "Zap like you're used to"),
  ],
 },
}

FONT = "-apple-system,BlinkMacSystemFont,Inter,Helvetica,Arial,sans-serif"  # zonder aanhalingstekens (staat in style='…')


def logo(px):
    return (f'<div style="display:inline-block;font:900 {px}px/1 {FONT};letter-spacing:-.02em;color:#fff">BINGR'
            f'<div style="height:{px*.12:.0f}px;border-radius:{px*.06:.0f}px;background:{RED};margin-top:{px*.06:.0f}px;width:94%"></div></div>')


def bg():
    return (f"background:radial-gradient(ellipse at 50% -10%,#5a0a10 0%,transparent 55%),"
            f"radial-gradient(ellipse at 100% 100%,#2a0508 0%,transparent 50%),#000;")


def render_raw(pw, lang):
    d = RAW / lang; d.mkdir(parents=True, exist_ok=True)
    b = pw.chromium.launch()
    jobs = [("ios", [k for k, *_ in T[lang]["phone"]], (430, 932), 3),
            ("tv", [k for k, _ in T[lang]["tv"]], (1920, 1080), 2),
            ("mac", ["home"], (1440, 900), 2)]
    for pre, names, vp, sc in jobs:
        pg = b.new_page(viewport={"width": vp[0], "height": vp[1]}, device_scale_factor=sc)
        pg.add_init_script("window.COVERS = [];")
        for n in names:
            pg.goto(f"{MOCK}?s={pre}_{n}&lang={lang}"); pg.wait_for_timeout(300)
            pg.evaluate(FIX)
            pg.screenshot(path=str(d / f"{pre}_{n}.png"))
        pg.close()
    b.close()
    return d


def shoot(pg, html_s, w, h, path):
    pg.set_viewport_size({"width": w, "height": h})
    # als bestand openen (file://), anders laadt Chromium de schermafbeeldingen niet
    tmp = OUT / "_page.html"
    tmp.write_text(f"<!doctype html><html><head><meta charset='utf-8'></head><body style='margin:0;width:{w}px;height:{h}px;overflow:hidden;background:#000'>{html_s}</body></html>", encoding="utf-8")
    pg.goto(tmp.as_uri()); pg.wait_for_load_state("load"); pg.wait_for_timeout(150)
    path.parent.mkdir(parents=True, exist_ok=True)
    pg.screenshot(path=str(path))
    im = Image.open(path).convert("RGB"); assert im.size == (w, h), (path, im.size); im.save(path, optimize=True)


def phone_shot(img, w, h, head, sub):
    # kop boven, telefoonscherm met afgeronde hoeken eronder (afgesneden onderaan, zoals veel App Store-sets)
    sw = w * 0.80; top = h * 0.215
    return (f"<div style='width:{w}px;height:{h}px;{bg()}position:relative;font-family:{FONT};color:#fff;text-align:center'>"
            f"<div style='position:absolute;top:{h*.045:.0f}px;left:{w*.07:.0f}px;right:{w*.07:.0f}px'>"
            f"<div style='font-weight:800;font-size:{w*.072:.0f}px;line-height:1.08;letter-spacing:-.01em'>{H.escape(head)}</div>"
            f"<div style='margin-top:{w*.025:.0f}px;font-size:{w*.037:.0f}px;line-height:1.3;color:#cfcfcf'>{H.escape(sub)}</div></div>"
            f"<div style='position:absolute;left:{(w-sw)/2:.0f}px;top:{top:.0f}px;width:{sw:.0f}px;border-radius:{sw*.11:.0f}px;"
            f"overflow:hidden;border:{w*.012:.0f}px solid #1c1c1e;box-shadow:0 0 0 {w*.004:.0f}px #3a3a3c,0 40px 120px #000c,0 0 160px #e5091433'>"
            f"<img src='{img.as_uri()}' style='display:block;width:100%'></div></div>")


def wide_shot(img, w, h, head, frame="ipad"):
    # iPad liggend of Mac-venster: kop boven, scherm eronder
    head_h = h * 0.17; sw = w * 0.86; sh = sw * 1080 / 1920
    if frame == "macraw":   # mac_home bevat al een bureaublad met venster
        scr = (f"<div style='width:{sw:.0f}px;border-radius:{sw*.012:.0f}px;overflow:hidden;box-shadow:0 0 0 2px #3a3a3c,0 50px 140px #000d'>"
               f"<img src='{img.as_uri()}' style='display:block;width:100%'></div>")
    elif frame == "mac":
        bar = sw * 0.028
        scr = (f"<div style='width:{sw:.0f}px;border-radius:{sw*.012:.0f}px;overflow:hidden;box-shadow:0 0 0 2px #3a3a3c,0 50px 140px #000d'>"
               f"<div style='height:{bar:.0f}px;background:#2a2a2c;display:flex;align-items:center;gap:{bar*.35:.0f}px;padding-left:{bar*.5:.0f}px'>"
               + "".join(f"<i style='width:{bar*.38:.0f}px;height:{bar*.38:.0f}px;border-radius:50%;background:{c};display:block'></i>" for c in ("#ff5f57", "#febc2e", "#28c840"))
               + f"</div><img src='{img.as_uri()}' style='display:block;width:100%'></div>")
    else:
        scr = (f"<div style='width:{sw:.0f}px;border-radius:{sw*.035:.0f}px;overflow:hidden;border:{w*.012:.0f}px solid #1c1c1e;"
               f"box-shadow:0 0 0 3px #3a3a3c,0 50px 140px #000d'><img src='{img.as_uri()}' style='display:block;width:100%'></div>")
    return (f"<div style='width:{w}px;height:{h}px;{bg()}position:relative;font-family:{FONT};color:#fff;text-align:center'>"
            f"<div style='position:absolute;top:{h*.05:.0f}px;left:0;right:0;font-weight:800;font-size:{h*.058:.0f}px;letter-spacing:-.01em'>{H.escape(head)}</div>"
            f"<div style='position:absolute;top:{head_h + (h-head_h-sh)/2 - h*.01:.0f}px;left:{(w-sw)/2:.0f}px'>{scr}</div></div>")


def tv_shot(img, w, h, head):
    # Apple TV: het scherm vult alles, kleine kop linksonder in een verloop
    return (f"<div style='width:{w}px;height:{h}px;position:relative;font-family:{FONT};color:#fff'>"
            f"<img src='{img.as_uri()}' style='position:absolute;inset:0;width:100%;height:100%;object-fit:cover'>"
            f"<div style='position:absolute;left:0;right:0;bottom:0;height:{h*.28:.0f}px;background:linear-gradient(transparent,#000d)'></div>"
            f"<div style='position:absolute;left:{w*.045:.0f}px;bottom:{h*.06:.0f}px;font-weight:800;font-size:{h*.05:.0f}px'>{H.escape(head)}</div></div>")


def banner(raw, w, h, lang):
    # tekst links (max. 36% breed), tv rechts, telefoon voor de rechteronderhoek van de tv (dekt geen titel af)
    t = T[lang]
    tvw = w * 0.44; phw = min(w * 0.11, h * 0.26)
    tv_right = w * 0.07; tv_top = h * 0.5 - tvw * 9 / 16 / 2 - h * 0.03
    return (f"<div style='width:{w}px;height:{h}px;{bg()}position:relative;overflow:hidden;font-family:{FONT};color:#fff'>"
            f"<div style='position:absolute;left:{w*.08:.0f}px;top:50%;transform:translateY(-50%);width:{w*.36:.0f}px'>"
            f"{logo(h*.10)}<div style='margin-top:{h*.055:.0f}px;font-weight:800;font-size:{min(h*.07, w*.034):.0f}px;line-height:1.08'>{H.escape(t['tag'])}</div>"
            f"<div style='margin-top:{h*.03:.0f}px;font-size:{min(h*.028, w*.013):.0f}px;line-height:1.4;color:#cfcfcf'>{H.escape(t['sub'])}</div></div>"
            f"<div style='position:absolute;right:{tv_right:.0f}px;top:{tv_top:.0f}px;width:{tvw:.0f}px'>"
            f"<div style='border-radius:{tvw*.018:.0f}px;overflow:hidden;border:{tvw*.012:.0f}px solid #111;box-shadow:0 0 0 3px #333,0 60px 160px #000e,0 0 220px #e5091440'>"
            f"<img src='{(raw/'tv_home.png').as_uri()}' style='display:block;width:100%'></div>"
            f"<div style='width:{tvw*.18:.0f}px;height:{tvw*.02:.0f}px;margin:{tvw*.015:.0f}px auto 0;background:#222;border-radius:4px'></div></div>"
            f"<div style='position:absolute;right:{tv_right - phw*.25:.0f}px;top:{tv_top + tvw*9/16 - phw*1.55:.0f}px;width:{phw:.0f}px;border-radius:{phw*.14:.0f}px;overflow:hidden;"
            f"border:{phw*.035:.0f}px solid #1c1c1e;box-shadow:0 0 0 3px #3a3a3c,0 40px 120px #000e'><img src='{(raw/'ios_home.png').as_uri()}' style='display:block;width:100%'></div></div>")


def main():
    with sync_playwright() as pw:
        for lang in ("nl", "en"):
            raw = render_raw(pw, lang)
            b = pw.chromium.launch(); pg = b.new_page(device_scale_factor=1)
            o = OUT / lang
            for w, h in ((5244, 2950), (3840, 1646)):
                shoot(pg, banner(raw, w, h, lang), w, h, o / "banners" / f"bingr-banner-{w}x{h}.png")
            for i, (k, head, sub) in enumerate(T[lang]["phone"], 1):
                img = raw / f"ios_{k}.png"
                shoot(pg, phone_shot(img, 1179, 2556, head, sub), 1179, 2556, o / "iphone-6.1" / f"{i:02d}-{k}-1179x2556.png")
                shoot(pg, phone_shot(img, 1206, 2622, head, sub), 1206, 2622, o / "iphone-6.3" / f"{i:02d}-{k}-1206x2622.png")
            for i, (k, head) in enumerate(T[lang]["tv"], 1):
                img = raw / f"tv_{k}.png"
                shoot(pg, wide_shot(img, 2752, 2064, head, "ipad"), 2752, 2064, o / "ipad-13" / f"{i:02d}-{k}-2752x2064.png")
                shoot(pg, tv_shot(img, 3840, 2160, head), 3840, 2160, o / "appletv" / f"{i:02d}-{k}-3840x2160.png")
                shoot(pg, tv_shot(img, 1920, 1080, head), 1920, 1080, o / "appletv-1080p" / f"{i:02d}-{k}-1920x1080.png")
                if i <= 5:
                    mimg = raw / ("mac_home.png" if k == "home" else f"tv_{k}.png")
                    mhead = ({"nl": "Ook op je Mac", "en": "On your Mac too"}[lang]) if k == "home" else head
                    shoot(pg, wide_shot(mimg, 2880, 1800, mhead, "macraw" if k == "home" else "mac"), 2880, 1800, o / "mac" / f"{i:02d}-{k}-2880x1800.png")
            b.close()
    print("klaar:", OUT)


if __name__ == "__main__":
    main()
