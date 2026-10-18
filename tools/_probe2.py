import json, urllib.request, urllib.parse, pathlib, re, time, sys
from io import BytesIO
from PIL import Image, ImageDraw
UA={"User-Agent":"BingrAppStoreScreenshots/1.0 (https://github.com/LRvdLinden/iptv-ios-appletv)"}
def api(**q):
    q.update(format="json",formatversion="2")
    return json.loads(urllib.request.urlopen(urllib.request.Request("https://commons.wikimedia.org/w/api.php?"+urllib.parse.urlencode(q),headers=UA),timeout=60).read())
def get(u):
    for a in range(3):
        try: return urllib.request.urlopen(urllib.request.Request(u,headers=UA),timeout=90).read()
        except Exception as e: err=e; time.sleep(4)
    raise err
films={
 "bbb":"Big Buck Bunny","ed":"Elephants Dream","sintel":"Sintel","tos":"Tears of Steel","cosmos":"Cosmos Laundromat",
 "agent":"Agent 327","spring":"Spring Blender","coffee":"Coffee Run","sprite":"Sprite Fright","charge":"Charge Blender",
 "nosferatu":"Nosferatu 1922","moon":"Voyage dans la Lune","moon2":"Trip to the Moon Melies","train":"Great Train Robbery",
 "vampires":"Les Vampires Feuillade","judex":"Judex","nanook":"Nanook of the North","caligari":"Caligari"}
out=pathlib.Path("sheets2"); out.mkdir(exist_ok=True)
rep=open("probe2.txt","w")
for key,q in films.items():
    res=api(action="query",list="search",srsearch=f"filetype:video {q}",srnamespace="6",srlimit="25")
    titles=[m["title"] for m in res["query"]["search"]]
    if not titles: rep.write(f"### {key}: geen video\n"); continue
    pages=api(action="query",titles="|".join(titles),prop="videoinfo",viprop="url|size|mime|extmetadata",viextmetadatafilter="LicenseShortName|Artist",viurlwidth="640")["query"]["pages"]
    rep.write(f"### {key}\n")
    cands=[]
    for p in pages:
        vi=(p.get("videoinfo") or [{}])[0]; lic=vi.get("extmetadata",{}).get("LicenseShortName",{}).get("value","")
        dur=vi.get("duration") or 0
        rep.write(f"  {p['title']}\t{vi.get('width')}x{vi.get('height')}\t{dur:.0f}s\t{lic}\n")
        if dur>60 and vi.get("thumburl"): cands.append((vi.get("width",0)*min(dur,3000),p["title"],dur,vi["thumburl"],lic))
    cands.sort(reverse=True)
    for ci,(sc,t,dur,tu,lic) in enumerate(cands[:2]):
        n=16; cols=4; sheet=Image.new("RGB",(cols*490,(n//cols)*300),(25,25,25)); d=ImageDraw.Draw(sheet)
        base=tu.split("?")[0]
        for i in range(n):
            s=int(dur*(i+0.5)/n)
            u=re.sub(r"/(\d+)px--",lambda m:f"/{m.group(1)}px-seek%3D{s}-",base)
            try:
                im=Image.open(BytesIO(get(u))).convert("RGB"); im.thumbnail((480,270)); sheet.paste(im,((i%cols)*490+5,(i//cols)*300+5))
            except Exception as e: rep.write(f"  frame {s} fout {e}\n")
            d.text(((i%cols)*490+8,(i//cols)*300+280),f"{s}s",fill=(255,255,0))
        sheet.save(out/f"{key}-{ci}.jpg",quality=78)
        rep.write(f"  SHEET {key}-{ci}: {t} ({lic}) {base}\n")
    time.sleep(1)
# extra stilstaande beelden
for q in ["Nosferatu 1922","Voyage dans la Lune 1902","Great Train Robbery 1903","Elephants Dream","Agent 327 Operation Barbershop","Sintel Blender","Tears of Steel"]:
    res=api(action="query",list="search",srsearch=f"filetype:bitmap {q}",srnamespace="6",srlimit="40")
    titles=[m["title"] for m in res["query"]["search"]]
    if not titles: continue
    pages=api(action="query",titles="|".join(titles),prop="imageinfo",iiprop="url|size|extmetadata",iiextmetadatafilter="LicenseShortName|Artist",iiurlwidth="360")["query"]["pages"]
    rep.write(f"### img {q}\n"); items=[]
    for p in pages:
        ii=(p.get("imageinfo") or [{}])[0]; md=ii.get("extmetadata",{})
        lic=md.get("LicenseShortName",{}).get("value",""); art=re.sub("<[^>]+>","",md.get("Artist",{}).get("value",""))[:60]
        rep.write(f"  {p['title']}\t{ii.get('width')}x{ii.get('height')}\t{lic}\t{art}\n")
        if ii.get("thumburl"): items.append((p["title"],ii["thumburl"],lic))
    cols=6; items=items[:36]; rows=(len(items)+cols-1)//cols
    sheet=Image.new("RGB",(cols*370,rows*260),(30,30,30)); d=ImageDraw.Draw(sheet)
    for i,(t,u,lic) in enumerate(items):
        try:
            im=Image.open(BytesIO(get(u))).convert("RGB"); im.thumbnail((360,230)); sheet.paste(im,((i%cols)*370+5,(i//cols)*260+5))
        except Exception as e: pass
        d.text(((i%cols)*370+8,(i//cols)*260+238),f"{i} {lic[:12]} {t[5:40]}",fill=(255,255,0))
    sheet.save(out/("img-"+re.sub(r"\W+","_",q)+".jpg"),quality=78)
    rep.write("  index: "+" | ".join(f"{i}={t}" for i,(t,u,l) in enumerate(items))+"\n")
