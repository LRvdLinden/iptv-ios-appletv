import base64, pathlib, json
from playwright.sync_api import sync_playwright

D = pathlib.Path(__file__).parent
OUT = D / "out"
def b64(p): return "data:image/png;base64," + base64.b64encode((D / p).read_bytes()).decode()

T = {
 "nl": {"kop": "Al je tv op één plek",
        "sub": "Live tv, films en series uit je eigen IPTV, Plex of Jellyfin. Op iPhone, iPad, Apple TV, Mac, Android en Windows.",
        "tag": "Nieuwe tv-gids met live beeld",
        "byo": "Gebruik je eigen IPTV-abonnement",
        "cta": "bingr.online", "store": "Ook in de App Store"},
 "en": {"kop": "All your TV in one place",
        "sub": "Live TV, movies and series from your own IPTV, Plex or Jellyfin. On iPhone, iPad, Apple TV, Mac, Android and Windows.",
        "tag": "New TV guide with live preview",
        "byo": "Bring your own IPTV subscription",
        "cta": "bingr.online", "store": "Also on the App Store"},
}
LANGDIR = {"nl": "nl-NL", "en": "en-US"}

CSS = """
*{margin:0;padding:0;box-sizing:border-box}
body{width:%(w)dpx;height:%(h)dpx;overflow:hidden;background:#000;color:#fff;font-family:Inter,sans-serif;position:relative}
.bg{position:absolute;inset:0;background:
 radial-gradient(ellipse 60%% 50%% at 85%% 15%%,rgba(229,9,20,.35),transparent 70%%),
 radial-gradient(ellipse 70%% 60%% at 10%% 95%%,rgba(0,120,140,.30),transparent 70%%),#050505}
.logo{display:flex;align-items:center;gap:.45em}
.logo img{border-radius:22%%;display:block}
.word{font-family:'Inter Display',Inter;font-weight:900;letter-spacing:-.01em;position:relative;line-height:1}
.word:after{content:"";position:absolute;left:0;right:0;bottom:-.14em;height:.09em;background:#E50914;border-radius:9px}
h1{font-family:'Inter Display',Inter;font-weight:900;line-height:1.02;letter-spacing:-.02em}
.sub{color:#C9C9C9;font-weight:500;line-height:1.35}
.tag{display:inline-flex;align-items:center;gap:.5em;background:rgba(229,9,20,.15);border:2px solid rgba(229,9,20,.6);color:#fff;font-weight:700;border-radius:999px;padding:.35em .9em}
.tag i{width:.55em;height:.55em;border-radius:50%%;background:#E50914;display:block}
.cta{display:inline-block;background:#E50914;color:#fff;font-weight:800;border-radius:999px;padding:.45em 1.1em}
.byo{color:#9a9a9a;font-weight:500}
.store{color:#fff;font-weight:600;opacity:.9}
.phone{position:absolute;border-radius:13%%/6.3%%;overflow:hidden;box-shadow:0 30px 80px rgba(0,0,0,.7)}
.phone img{width:100%%;display:block}
"""

def phone(img, x, y, w, rot=0, z=1):
    return f'<div class="phone" style="left:{x}px;top:{y}px;width:{w}px;transform:rotate({rot}deg);z-index:{z}"><img src="{img}"></div>'

def page(w, h, body):
    return f"<html><head><meta charset='utf-8'><style>{CSS % {'w': w, 'h': h}}</style></head><body><div class='bg'></div>{body}</body></html>"

def logo(size):
    return f'<div class="logo" style="font-size:{size}px"><img src="{ICON}" style="width:{size*1.5}px;height:{size*1.5}px"><span class="word">BINGR</span></div>'

def layouts(l):
    t = T[l]; L = LANGDIR[l]
    home, guide, det = (b64(f"{L}_{n}.png") for n in ("01_home", "02_guide", "03_detail"))
    out = {}
    # 1080x1080 post: tekst links boven, twee telefoons rechtsonder
    out["instagram-post-1080x1080"] = (1080, 1080, f"""
      <div style="position:absolute;left:72px;top:72px;width:530px;z-index:3">
        {logo(40)}
        <h1 style="font-size:84px;margin-top:56px">{t['kop']}</h1>
        <p class="sub" style="font-size:27px;margin-top:24px">{t['sub']}</p>
        <div style="margin-top:36px"><span class="cta" style="font-size:32px">{t['cta']}</span></div>
        <p class="byo" style="font-size:20px;margin-top:22px">{t['byo']}</p>
      </div>
      {phone(home, 680, 340, 320, -6, 1)}
      {phone(guide, 820, 240, 320, 4, 2)}
    """)
    # 1080x1350 post
    out["instagram-post-1080x1350"] = (1080, 1350, f"""
      <div style="position:absolute;left:72px;top:72px;right:72px;z-index:3">
        {logo(40)}
        <h1 style="font-size:92px;margin-top:48px">{t['kop']}</h1>
        <p class="sub" style="font-size:29px;margin-top:22px;max-width:900px">{t['sub']}</p>
        <div style="margin-top:30px;display:flex;gap:26px;align-items:center"><span class="cta" style="font-size:32px">{t['cta']}</span><span class="byo" style="font-size:22px">{t['byo']}</span></div>
      </div>
      {phone(home, 130, 790, 400, -5, 1)}
      {phone(guide, 560, 750, 400, 4, 2)}
    """)
    # 1080x1920 story (veilige zone 250px boven en onder)
    out["story-1080x1920"] = (1080, 1920, f"""
      <div style="position:absolute;left:80px;right:80px;top:260px;text-align:center;z-index:3">
        <div style="display:flex;justify-content:center">{logo(46)}</div>
        <h1 style="font-size:104px;margin-top:50px">{t['kop']}</h1>
        <p class="sub" style="font-size:34px;margin-top:26px">{t['sub']}</p>
        <div style="margin-top:30px"><span class="tag" style="font-size:28px"><i></i>{t['tag']}</span></div>
        <div style="margin-top:40px"><span class="cta" style="font-size:44px">{t['cta']}</span></div>
        <p class="byo" style="font-size:24px;margin-top:16px">{t['byo']}</p>
      </div>
      {phone(home, 140, 1130, 400, -6, 1)}
      {phone(guide, 540, 1090, 400, 5, 2)}
    """)
    # 1640x624 Facebook-cover (inhoud gecentreerd; mobiel snijdt de zijkanten af)
    out["facebook-cover-1640x624"] = (1640, 624, f"""
      <div style="position:absolute;left:250px;top:110px;width:720px;z-index:3">
        {logo(36)}
        <h1 style="font-size:76px;margin-top:40px">{t['kop']}</h1>
        <p class="sub" style="font-size:26px;margin-top:20px">{t['sub']}</p>
        <div style="margin-top:28px;display:flex;gap:24px;align-items:center"><span class="cta" style="font-size:28px">{t['cta']}</span><span class="byo" style="font-size:20px">{t['byo']}</span></div>
      </div>
      {phone(home, 1010, 70, 250, -6, 1)}
      {phone(guide, 1190, 40, 250, 4, 2)}
    """)
    # 1584x396 LinkedIn-cover (linksonder valt de profielfoto: tekst rechts van het midden)
    out["linkedin-cover-1584x396"] = (1584, 396, f"""
      {phone(home, 360, 70, 190, -6, 1)}
      {phone(guide, 500, 40, 190, 4, 2)}
      <div style="position:absolute;left:780px;top:70px;width:720px;z-index:3">
        {logo(30)}
        <h1 style="font-size:58px;margin-top:30px">{t['kop']}</h1>
        <p class="sub" style="font-size:21px;margin-top:14px">{t['sub']}</p>
        <div style="margin-top:20px"><span class="cta" style="font-size:22px">{t['cta']}</span></div>
      </div>
    """)
    return out

ICON = b64("icon.png")
with sync_playwright() as p:
    b = p.chromium.launch()
    for l in ("nl", "en"):
        (OUT / l).mkdir(parents=True, exist_ok=True)
        for name, (w, h, body) in layouts(l).items():
            pg = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            pg.set_content(page(w, h, body)); pg.wait_for_timeout(300)
            pg.screenshot(path=str(OUT / l / f"{name}.png")); pg.close()
    b.close()
print("ok")
