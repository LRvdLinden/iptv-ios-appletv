import sys, pathlib
from playwright.sync_api import sync_playwright
root = pathlib.Path(sys.argv[1]).resolve()
html = (root/"docs/mockups/mockups.html").as_uri()
ios = ["ios_splash","ios_picker","ios_home","ios_detail","ios_detail2","ios_live","ios_add","ios_guide","ios_settings","ios_top10","ios_categories","ios_category"]
tv = ["tv_home","tv_picker","tv_detail","tv_live","tv_trakt","tv_multiview","tv_guide"]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width":430,"height":932}, device_scale_factor=3)
    for s in ios:
        pg.goto(f"{html}?s={s}"); pg.wait_for_timeout(150)
        pg.screenshot(path=str(root/f"docs/screenshots/{s}.png"))
    pg = b.new_page(viewport={"width":1920,"height":1080}, device_scale_factor=1)
    for s in tv:
        pg.goto(f"{html}?s={s}"); pg.wait_for_timeout(150)
        pg.screenshot(path=str(root/f"docs/screenshots/{s}.png"))
    pg = b.new_page(viewport={"width":1440,"height":900}, device_scale_factor=1)
    pg.goto(f"{html}?s=mac_home"); pg.wait_for_timeout(200)
    pg.screenshot(path=str(root/"docs/screenshots/mac_home.png"))
    b.close()
print("ok")
