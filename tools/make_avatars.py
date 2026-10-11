import pathlib, sys
from playwright.sync_api import sync_playwright
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
SK = ["#FBD9C3","#F2C29B","#E3A97C","#C68642","#94603A","#6B4129"]
HC = {"dark":"#2B1B17","brown":"#6B3B22","ginger":"#D9692B","blond":"#F2C14E","navy":"#25305E","purple":"#7B3FA0","pink":"#E85C9A","black":"#151515"}
def darker(h, f=.85):
    h=h.lstrip('#'); r,g,b=[int(h[i:i+2],16) for i in (0,2,4)]
    return '#%02x%02x%02x'%(int(r*f),int(g*f),int(b*f))

def hair_back(style, c):
    if style=="long":   return f'<path d="M50 96 Q46 150 62 172 L138 172 Q154 150 150 96 Z" fill="{c}"/>'
    if style=="afro":
        dots=''.join(f'<circle cx="{100+52*__import__("math").cos(a/10*6.283)}" cy="{82+46*__import__("math").sin(a/10*6.283)}" r="20" fill="{c}"/>' for a in range(10))
        return f'<circle cx="100" cy="82" r="56" fill="{c}"/>'+dots
    if style=="pigtails": return f'<circle cx="46" cy="78" r="15" fill="{c}"/><circle cx="154" cy="78" r="15" fill="{c}"/><path d="M40 90 Q30 120 44 134 Q48 112 52 98Z" fill="{c}"/><path d="M160 90 Q170 120 156 134 Q152 112 148 98Z" fill="{c}"/>'
    if style=="buns": return f'<circle cx="70" cy="52" r="16" fill="{c}"/><circle cx="130" cy="52" r="16" fill="{c}"/>'
    if style=="ponytail": return f'<path d="M140 70 Q178 60 172 110 Q166 92 150 88 Z" fill="{c}"/><circle cx="146" cy="70" r="6" fill="#FF5A8A"/>'
    return ''

def hair_front(style, c):
    top = f'<path d="M55 100 Q50 50 100 48 Q150 50 145 100 Q142 80 124 72 Q104 84 78 74 Q62 82 55 100 Z" fill="{c}"/>'
    if style in ("short","pigtails","ponytail","cap","buns"): return top
    if style=="long": return f'<path d="M55 104 Q48 48 100 46 Q152 48 145 104 Q138 74 112 70 Q96 86 66 78 Q58 88 55 104 Z" fill="{c}"/>'
    if style=="spiky":
        return f'<path d="M54 98 Q52 70 62 58 L60 40 L76 52 L82 32 L94 50 L104 28 L112 50 L126 34 L128 54 L144 46 L140 64 Q150 78 146 98 Q138 76 120 72 Q100 80 78 72 Q62 80 54 98Z" fill="{c}"/>'
    if style=="curly":
        dots=''.join(f'<circle cx="{x}" cy="{y}" r="11" fill="{c}"/>' for x,y in [(60,82),(66,64),(80,52),(98,47),(116,50),(132,58),(142,74),(146,90),(56,96)])
        return f'<path d="M56 96 Q54 56 100 52 Q146 56 144 96 Q130 74 100 72 Q70 74 56 96Z" fill="{c}"/>'+dots
    if style=="afro": return f'<path d="M56 92 Q70 70 100 70 Q130 70 144 92 Q140 60 100 56 Q60 60 56 92Z" fill="{c}"/>'
    if style=="bob": return f'<path d="M50 120 Q44 48 100 46 Q156 48 150 120 L140 120 Q140 84 126 74 Q100 84 74 72 Q60 84 60 120 Z" fill="{c}"/>'
    return top

def cap(color, sideways=False):
    if sideways:
        return f'<path d="M54 88 Q56 46 100 44 Q144 46 146 88 Z" fill="{color}"/><path d="M128 70 Q168 64 176 82 Q150 84 136 86Z" fill="{darker(color,.75)}"/><circle cx="100" cy="45" r="4" fill="{darker(color,.7)}"/>'
    return f'<path d="M54 86 Q56 44 100 42 Q144 44 146 86 Z" fill="{color}"/><path d="M58 86 Q100 74 150 84 Q160 92 150 96 Q100 86 56 92Z" fill="{darker(color,.75)}"/>'

def beanie(color):
    return f'<path d="M52 92 Q52 38 100 38 Q148 38 148 92 Z" fill="{color}"/><rect x="50" y="80" width="100" height="16" rx="8" fill="{darker(color,.8)}"/><circle cx="100" cy="36" r="8" fill="{darker(color,.8)}"/>'

def eyes(kind, iris):
    if kind=="happy":
        return ''.join(f'<path d="M{x-9} 106 Q{x} 96 {x+9} 106" stroke="#2a1a14" stroke-width="3.5" fill="none" stroke-linecap="round"/>' for x in (82,118))
    if kind=="wink":
        return (f'<ellipse cx="82" cy="104" rx="8.5" ry="10" fill="#fff"/><circle cx="83" cy="106" r="6" fill="{iris}"/><circle cx="83" cy="106" r="3.2" fill="#111"/><circle cx="85" cy="103" r="1.8" fill="#fff"/>'
                '<path d="M110 106 Q118 98 127 106" stroke="#2a1a14" stroke-width="3.5" fill="none" stroke-linecap="round"/>')
    s=''
    for x in (82,118):
        s+=f'<ellipse cx="{x}" cy="104" rx="8.5" ry="10" fill="#fff"/><circle cx="{x+1}" cy="106" r="6.2" fill="{iris}"/><circle cx="{x+1}" cy="106" r="3.3" fill="#111"/><circle cx="{x+3}" cy="103" r="1.9" fill="#fff"/>'
    return s

def mouth(kind):
    if kind=="smile": return '<path d="M88 126 Q100 138 112 126" stroke="#7a2430" stroke-width="3.5" fill="none" stroke-linecap="round"/>'
    if kind=="grin": return '<path d="M84 123 Q100 146 116 123 Z" fill="#7a1f2b"/><path d="M86 124 L114 124 L112 129 L88 129Z" fill="#fff"/><ellipse cx="100" cy="137" rx="7" ry="3.5" fill="#F06A7A"/>'
    if kind=="braces": return '<path d="M84 123 Q100 144 116 123 Z" fill="#7a1f2b"/><path d="M85 124 L115 124 L113 131 L87 131Z" fill="#fff"/><line x1="86" y1="127.5" x2="114" y2="127.5" stroke="#9aa3ad" stroke-width="2"/>' + ''.join(f'<rect x="{x}" y="125.5" width="3" height="4" fill="#7d8792"/>' for x in (89,95,101,107))
    if kind=="tooth": return '<path d="M86 124 Q100 142 114 124 Z" fill="#7a1f2b"/><rect x="94" y="124" width="5" height="5" fill="#fff"/><rect x="101" y="124" width="5" height="5" fill="#fff"/>'
    if kind=="shy": return '<path d="M92 128 Q100 132 108 128" stroke="#7a2430" stroke-width="3" fill="none" stroke-linecap="round"/>'
    return ''

def avatar(bg, skin, hair, hc, eye="open", iris="#4a7fd6", mth="smile", shirt="#FFD54F", glasses=False, hat=None, freckles=False, clip=None):
    h = HC[hc]
    parts=[f'<circle cx="100" cy="100" r="100" fill="{bg}"/>', '<g clip-path="url(#c)"><g transform="translate(100 108) scale(1.2) translate(-100 -100)">']
    parts.append(hair_back(hair, h))
    parts.append(f'<path d="M28 205 Q34 162 100 160 Q166 162 172 205 Z" fill="{shirt}"/>')
    parts.append(f'<path d="M84 160 Q100 172 116 160" fill="{darker(shirt,.85)}"/>')
    parts.append(f'<rect x="89" y="134" width="22" height="30" rx="6" fill="{darker(skin,.9)}"/>')
    parts.append(f'<circle cx="56" cy="108" r="10" fill="{skin}"/><circle cx="144" cy="108" r="10" fill="{skin}"/><circle cx="57" cy="108" r="5" fill="{darker(skin,.88)}"/><circle cx="143" cy="108" r="5" fill="{darker(skin,.88)}"/>')
    parts.append(f'<ellipse cx="100" cy="102" rx="44" ry="46" fill="{skin}"/>')
    parts.append(f'<ellipse cx="73" cy="121" rx="7" ry="4.5" fill="#FF6B81" opacity=".35"/><ellipse cx="127" cy="121" rx="7" ry="4.5" fill="#FF6B81" opacity=".35"/>')
    if freckles: parts.append(''.join(f'<circle cx="{x}" cy="{y}" r="1.4" fill="{darker(skin,.7)}"/>' for x,y in [(70,116),(75,119),(66,120),(130,116),(125,119),(134,120)]))
    parts.append(eyes(eye, iris))
    if eye!="happy": parts.append(f'<path d="M74 88 Q82 84 90 88" stroke="{h}" stroke-width="3" fill="none" stroke-linecap="round"/><path d="M110 88 Q118 84 126 88" stroke="{h}" stroke-width="3" fill="none" stroke-linecap="round"/>')
    parts.append(f'<path d="M97 115 Q100 118 103 115" stroke="{darker(skin,.7)}" stroke-width="2.5" fill="none" stroke-linecap="round"/>')
    parts.append(mouth(mth))
    if glasses: parts.append('<g fill="none" stroke="#2b2b2b" stroke-width="2.5"><circle cx="82" cy="105" r="12"/><circle cx="118" cy="105" r="12"/><path d="M94 104 Q100 100 106 104"/></g>')
    if hat and hat[0]=="cap": parts.append(hair_front("short",h) if False else ''); parts.append(cap(hat[1], hat[2] if len(hat)>2 else False))
    elif hat and hat[0]=="beanie": parts.append(beanie(hat[1]))
    else: parts.append(hair_front(hair, h))
    if clip: parts.append(f'<g transform="translate(128 66) rotate(20)"><path d="M-8 0 L0 -6 L8 0 L0 6Z" fill="{clip}"/><circle r="3" fill="#fff"/></g>')
    parts.append('</g></g>')
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="360" height="360"><defs><clipPath id="c"><circle cx="100" cy="100" r="100"/></clipPath></defs>'+''.join(parts)+'</svg>'

A = [
 avatar("#3FA9F5", SK[0], "long", "ginger", mth="grin", shirt="#FFE066", iris="#3b8d4a", freckles=True),
 avatar("#FF7043", SK[4], "ponytail", "dark", mth="grin", shirt="#FFD54F", iris="#5a3a20"),
 avatar("#FFE066", SK[2], "pigtails", "blond", eye="happy", mth="grin", shirt="#66BB6A"),
 avatar("#66BB6A", SK[1], "short", "black", eye="happy", mth="smile", shirt="#7E57C2", glasses=True),
 avatar("#9CCC65", SK[3], "bob", "ginger", mth="smile", shirt="#F06292", iris="#6b4a2a"),
 avatar("#F06292", SK[0], "short", "brown", mth="shy", shirt="#1E88E5", iris="#4a90d9"),
 avatar("#9C6ADE", SK[1], "ponytail", "black", eye="wink", mth="grin", shirt="#FFB74D", iris="#3a2a20"),
 avatar("#29B6F6", SK[1], "spiky", "navy", mth="smile", shirt="#1E3A8A", glasses=True, iris="#4a7fd6"),
 avatar("#7E57C2", SK[0], "short", "dark", mth="grin", shirt="#FFEB3B", hat=("cap","#EF5350",True), iris="#3a7a3a"),
 avatar("#FFD54F", SK[4], "buns", "dark", mth="braces", shirt="#F48FB1", iris="#4a3020"),
 avatar("#EF5350", SK[0], "bob", "purple", mth="grin", shirt="#81C784", iris="#2e8b57", clip="#FFCA28"),
 avatar("#66BB6A", SK[5], "afro", "black", mth="tooth", shirt="#E53935", iris="#3a2a1a"),
 avatar("#26C6DA", SK[1], "spiky", "dark", mth="smile", shirt="#FFF176", iris="#4a7fd6"),
 avatar("#FF8A65", SK[1], "curly", "brown", mth="shy", shirt="#42A5F5", iris="#5a7a3a"),
 avatar("#AB47BC", SK[5], "curly", "black", eye="happy", mth="grin", shirt="#FFEE58"),
 avatar("#FFE082", SK[2], "short", "brown", mth="grin", shirt="#9CCC65", hat=("beanie","#1E88E5"), iris="#6b4a2a"),
]
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(viewport={"width":360,"height":360})
    for i,svg in enumerate(A,1):
        pg.set_content(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
        pg.screenshot(path=str(out/f"kid{i:02d}.png"), omit_background=True, clip={"x":0,"y":0,"width":360,"height":360})
    # overzicht
    grid=''.join(f'<img src="kid{i:02d}.png" width="180" style="margin:10px">' for i in range(1,len(A)+1))
    (out/'_sheet.html').write_text(f'<html><body style="background:#fff;width:800px">{grid}</body></html>')
    pg2=b.new_page(viewport={"width":800,"height":820}); pg2.goto((out/'_sheet.html').as_uri()); pg2.screenshot(path='/tmp/claude-0/av/sheet.png')
    b.close()
print(len(A))
