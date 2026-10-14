// Bingr App Store-materiaal: de app-schermen (iPhone, iPad, Mac, Apple TV), nagebouwd naar Shared/UI.
// Alle teksten NL/EN volgens Shared/Resources/Translations.json; alle titels, zenders en mensen zijn fictief.
'use strict';

let LANG = 'nl';
const t = (nl, en) => LANG === 'en' ? en : nl;
const TN = id => LANG === 'en' ? TBY[id].en : TBY[id].nl;
const RED = '#E50914', SEC = '#B3B3B3', CARD = '#181818', EL = '#232323', IMDB = '#F5C518', GREEN = '#46D369';
const SERIES_C = '#3B82F6', LIVE_C = '#F59E0B';

// ---------- iconen (SF Symbols-achtig, eigen tekening) ----------
const ICONS = {
  house: '<path d="M3 11.2 12 3.5l9 7.7V20a1 1 0 0 1-1 1h-5.2v-6.2H9.2V21H4a1 1 0 0 1-1-1z" fill="currentColor"/>',
  radio: '<circle cx="12" cy="12" r="2.6" fill="currentColor"/><path d="M8.2 8.2a5.4 5.4 0 0 0 0 7.6M15.8 8.2a5.4 5.4 0 0 1 0 7.6M5.3 5.3a9.5 9.5 0 0 0 0 13.4M18.7 5.3a9.5 9.5 0 0 1 0 13.4" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/>',
  film: '<rect x="3" y="7" width="18" height="14" rx="2.2" fill="currentColor"/><path d="M5.5 4.5h13M7.5 2h9" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M7 7v14M17 7v14" stroke="#000" stroke-opacity=".45" stroke-width="1.4"/>',
  stack: '<rect x="3" y="8" width="18" height="13" rx="2.2" fill="currentColor"/><path d="M5 5.2h14M7 2.5h10" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
  person: '<circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="12" cy="9.5" r="3.4" fill="currentColor"/><path d="M5.8 18.2c1.5-2.4 3.7-3.5 6.2-3.5s4.7 1.1 6.2 3.5" fill="currentColor"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M15.5 15.5 21 21" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/>',
  play: '<path d="M7 4.2v15.6a1 1 0 0 0 1.5.9l12.4-7.8a1 1 0 0 0 0-1.8L8.5 3.3A1 1 0 0 0 7 4.2z" fill="currentColor"/>',
  info: '<circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 11v6" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="7.6" r="1.5" fill="currentColor"/>',
  plus: '<path d="M12 4v16M4 12h16" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/>',
  check: '<path d="M4.5 12.5 9.5 17.5 19.5 6.5" stroke="currentColor" stroke-width="2.8" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  heart: '<path d="M12 20.5s-8.5-5.2-8.5-11A4.8 4.8 0 0 1 12 6.6a4.8 4.8 0 0 1 8.5 2.9c0 5.8-8.5 11-8.5 11z" fill="currentColor"/>',
  chevD: '<path d="M6 9l6 6 6-6" stroke="currentColor" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  chevL: '<path d="M15 5l-7 7 7 7" stroke="currentColor" stroke-width="2.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  chevR: '<path d="M9 5l7 7-7 7" stroke="currentColor" stroke-width="2.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  x: '<path d="M6 6l12 12M18 6 6 18" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/>',
  grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.6" fill="none" stroke="currentColor" stroke-width="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.6" fill="none" stroke="currentColor" stroke-width="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.6" fill="none" stroke="currentColor" stroke-width="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.6" fill="none" stroke="currentColor" stroke-width="2"/>',
  gridFill: '<rect x="3" y="3" width="8" height="8" rx="1.8" fill="currentColor"/><rect x="13" y="3" width="8" height="8" rx="1.8" fill="currentColor"/><rect x="3" y="13" width="8" height="8" rx="1.8" fill="currentColor"/><rect x="13" y="13" width="8" height="8" rx="1.8" fill="currentColor"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/><circle cx="4" cy="6" r="1.4" fill="currentColor"/><circle cx="4" cy="12" r="1.4" fill="currentColor"/><circle cx="4" cy="18" r="1.4" fill="currentColor"/>',
  guide: '<rect x="3" y="4" width="18" height="16" rx="2.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3 9.5h18M9 9.5V20M9 14.8h12" stroke="currentColor" stroke-width="2"/>',
  download: '<circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7v9M8 12.5l4 4 4-4" stroke="currentColor" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  bell: '<path d="M12 3a6 6 0 0 0-6 6v4l-2 3h16l-2-3V9a6 6 0 0 0-6-6zM9.5 19a2.5 2.5 0 0 0 5 0" fill="currentColor"/>',
  star: '<path d="M12 2.8l2.8 5.8 6.4.8-4.7 4.4 1.2 6.3L12 17l-5.7 3.1 1.2-6.3L2.8 9.4l6.4-.8z" fill="currentColor"/>',
  clock: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 6.5V12l3.8 2.4" stroke="#000" stroke-width="2.2" fill="none" stroke-linecap="round"/>',
  chart: '<path d="M4 20h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><rect x="5" y="11" width="3.2" height="7" rx="1" fill="currentColor"/><rect x="10.4" y="6" width="3.2" height="12" rx="1" fill="currentColor"/><rect x="15.8" y="9" width="3.2" height="9" rx="1" fill="currentColor"/>',
  gear: '<circle cx="12" cy="12" r="3.2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
  history: '<path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4.5h4.5" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 8v4.5l3 2" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/>',
  collection: '<rect x="3" y="8" width="18" height="13" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M5.5 5h13M8 2.2h8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
  sync: '<path d="M19 8.5A7.5 7.5 0 0 0 5.4 7.6M5 15.5a7.5 7.5 0 0 0 13.6.9" stroke="currentColor" stroke-width="2.2" fill="none" stroke-linecap="round"/><path d="M19.5 3.5v5h-5M4.5 20.5v-5h5" stroke="currentColor" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  checkCircle: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M7.5 12.4l3 3 6-6.4" stroke="#000" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  envelope: '<rect x="2.5" y="5" width="19" height="14" rx="2.5" fill="currentColor"/><path d="M3.5 6.5 12 13l8.5-6.5" stroke="#000" stroke-opacity=".55" stroke-width="1.8" fill="none"/>',
  clapper: '<rect x="3" y="9" width="18" height="12" rx="2" fill="currentColor"/><path d="M3.5 8.5 19.7 4.3l.7 2.7L4.2 11.2z" fill="currentColor"/><path d="M7.3 7.4l2.2 2.4M11.7 6.3l2.2 2.4M16 5.2l2.2 2.4" stroke="#000" stroke-opacity=".5" stroke-width="1.4"/>',
  stack3d: '<path d="M12 3 21 7.5 12 12 3 7.5z" fill="currentColor"/><path d="M3 12l9 4.5 9-4.5M3 16.5 12 21l9-4.5" stroke="currentColor" stroke-width="2" fill="none" stroke-linejoin="round"/>',
  sort: '<path d="M7 4v16M3.5 7.5 7 4l3.5 3.5M17 20V4M13.5 16.5 17 20l3.5-3.5" stroke="currentColor" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
  pencil: '<path d="M4 20l1-4.5L15.5 5a2.1 2.1 0 0 1 3 3L8 18.5z" fill="currentColor"/>',
  airplay: '<path d="M6 17H4.5A1.5 1.5 0 0 1 3 15.5v-10A1.5 1.5 0 0 1 4.5 4h15A1.5 1.5 0 0 1 21 5.5v10a1.5 1.5 0 0 1-1.5 1.5H18" stroke="currentColor" stroke-width="2" fill="none"/><path d="M12 14l5 6.5H7z" fill="currentColor"/>',
  lock: '<rect x="5" y="10.5" width="14" height="10.5" rx="2.2" fill="currentColor"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" stroke-width="2.2" fill="none"/>',
  phone: '<rect x="6.5" y="2" width="11" height="20" rx="2.6" fill="none" stroke="currentColor" stroke-width="2"/><path d="M10.5 5h3" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  tvfill: '<rect x="2.5" y="4" width="19" height="13" rx="2.2" fill="currentColor"/><path d="M8 20.5h8" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
  filmfill: '<rect x="3" y="4" width="18" height="16" rx="2.4" fill="currentColor"/><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4" stroke="#000" stroke-opacity=".5" stroke-width="1.5"/>',
};
function I(name, size, color = 'currentColor', extra = '') {
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" style="color:${color};flex:none;display:block;${extra}">${ICONS[name]}</svg>`;
}
function statusIcons(s = 1, color = '#fff') {
  return `<div style="display:flex;align-items:center;gap:${7 * s}px;color:${color}">
    <svg width="${18 * s}" height="${12 * s}" viewBox="0 0 18 12">${[0, 1, 2, 3].map(i => `<rect x="${i * 4.8}" y="${9 - i * 3}" width="3.2" height="${3 + i * 3}" rx="1" fill="currentColor"/>`).join('')}</svg>
    <svg width="${16 * s}" height="${12 * s}" viewBox="0 0 16 12"><path d="M8 11.5 5.6 9a3.4 3.4 0 0 1 4.8 0z" fill="currentColor"/><path d="M3.4 6.8a6.5 6.5 0 0 1 9.2 0M1 4.4a9.9 9.9 0 0 1 14 0" stroke="currentColor" stroke-width="1.7" fill="none" stroke-linecap="round"/></svg>
    <svg width="${27 * s}" height="${13 * s}" viewBox="0 0 27 13"><rect x=".5" y=".5" width="23" height="12" rx="3.6" fill="none" stroke="currentColor" stroke-opacity=".45"/><rect x="2.3" y="2.3" width="17" height="8.4" rx="2" fill="currentColor"/><path d="M25 4.5v4a1.8 1.8 0 0 0 0-4z" fill="currentColor" fill-opacity=".45"/></svg></div>`;
}
const bg = (url, pos = 'center', size = 'cover') => `background:#111 url('${url}') ${pos}/${size} no-repeat`;
const sceneURL = (id, w, h, seed = 0) => backdropURL(id, seed, w, h);

// ---------- bouwstenen ----------
function logo(px) {
  return `<div style="display:inline-flex;flex-direction:column;align-items:center;gap:${px * .1}px;filter:drop-shadow(0 0 ${px * .15}px #0008)"><div style="font-family:ui-rounded,'SF Pro Rounded','Inter Display',Inter,sans-serif;font-weight:900;font-size:${px}px;line-height:.86;letter-spacing:${px * .02}px;color:#fff">BINGR</div><div style="height:${Math.max(2, px * .09)}px;align-self:stretch;margin:0 ${px * .04}px;border-radius:99px;background:${RED}"></div></div>`;
}
function badgeLabel(text, s = 1) { return `<div style="background:${RED};color:#fff;font-weight:800;font-size:${9 * s}px;padding:${2 * s}px ${4 * s}px;border-radius:2px;letter-spacing:.02em;white-space:nowrap">${text}</div>`; }
function poster(id, w, o = {}) {
  const s = o.s || 1;
  return `<div style="position:relative;flex:none;width:${w}px;height:${w * 1.5}px;border-radius:${o.r ?? 4 * s}px;overflow:hidden;${bg(posterURL(id, LANG))};${o.style || ''}">
    ${o.badge ? `<div style="position:absolute;left:0;right:0;bottom:${o.prog != null ? 8 * s : 0}px;display:flex;justify-content:center">${badgeLabel(o.badge, s)}</div>` : ''}
    ${o.top10 ? `<div style="position:absolute;top:${4 * s}px;left:${4 * s}px;background:${RED};border-radius:2px;padding:${1.5 * s}px ${3 * s}px;text-align:center;line-height:.9;font-weight:900"><div style="font-size:${6.5 * s}px">TOP</div><div style="font-size:${11 * s}px">10</div></div>` : ''}
    ${o.check ? `<div style="position:absolute;top:${6 * s}px;right:${6 * s}px;width:${20 * s}px;height:${20 * s}px;border-radius:50%;background:${RED};display:grid;place-items:center;box-shadow:0 1px 4px #0008">${I('check', 12 * s, '#fff')}</div>` : ''}
    ${o.rating ? `<div style="position:absolute;top:${6 * s}px;right:${6 * s}px;background:${IMDB};color:#000;font-size:${11 * s}px;font-weight:800;padding:${2 * s}px ${6 * s}px;border-radius:${4 * s}px">★ ${o.rating.toFixed(1)}</div>` : ''}
    ${o.prog != null ? `<div style="position:absolute;left:0;right:0;bottom:0;height:${3 * s}px;background:#ffffff4d"><div style="height:100%;width:${o.prog}%;background:${RED}"></div></div>` : ''}
    ${o.focus ? `<div style="position:absolute;inset:0;border-radius:inherit;box-shadow:inset 0 0 0 ${4 * s}px #fff"></div>` : ''}
  </div>`;
}
function cont(id, w, pct, min, s = 1, o = {}) {
  return `<div style="flex:none;width:${w}px;${o.focus ? `transform:scale(1.1);transform-origin:50% 40%;z-index:2;filter:drop-shadow(0 ${14 * s}px ${18 * s}px #000c)` : ''}"><div style="position:relative">${poster(id, w, { s, focus: o.focus })}
    <div style="position:absolute;inset:0;display:grid;place-items:center"><div style="width:${38 * s}px;height:${38 * s}px;border-radius:50%;background:#0009;border:${1.5 * s}px solid #fffe;display:grid;place-items:center;padding-left:${3 * s}px">${I('play', 16 * s, '#fff')}</div></div></div>
    <div style="height:${4 * s}px;border-radius:${4 * s}px;background:#ffffff4d;margin-top:${5 * s}px;overflow:hidden"><div style="height:100%;width:${pct}%;background:${RED}"></div></div>
    <div style="font-size:${10 * s}px;color:${SEC};margin-top:${4 * s}px">${t(`Nog ${min} min`, `${min} min left`)}</div></div>`;
}
function top10(id, rank, w, s = 1, badge) {
  const h = w * 1.5;
  return `<div style="display:flex;align-items:flex-end;flex:none">
    <div style="width:${h * .46}px;height:${h}px;display:flex;align-items:flex-end;justify-content:flex-end;font-family:${FONT.display};font-size:${h * .78}px;font-weight:900;line-height:.8;letter-spacing:-.06em;color:#000;-webkit-text-stroke:${Math.max(2, w / 40)}px #8c8c8c;margin-right:-${w * .1}px">${rank}</div>
    ${poster(id, w, { s, top10: true, badge, style: 'box-shadow:-6px 0 14px #000a' })}</div>`;
}
function rowHead(title, all, fs = 19, pad = 16, s = 1) {
  return `<div style="display:flex;justify-content:space-between;align-items:baseline;margin:0 ${pad}px ${8 * s}px"><div style="font-size:${fs}px;font-weight:700">${title}</div>${all ? `<div style="font-size:${15 * s}px;font-weight:600">${t('Bekijk allemaal', 'See all')}</div>` : ''}</div>`;
}
function imdb(r, px) { return `<span style="display:inline-flex;align-items:center;gap:${px * .3}px;font-weight:600"><b style="background:${IMDB};color:#000;font-weight:900;font-size:${px * .72}px;padding:${px * .06}px ${px * .2}px;border-radius:${px * .15}px">IMDb</b>${r.toFixed(1)}</span>`; }
function ageBox(a, px) { return `<span style="border:${Math.max(1.5, px * .08)}px solid ${SEC};border-radius:${px * .2}px;padding:0 ${px * .3}px;font-weight:600;font-size:${px * .85}px;line-height:1.25">${a}</span>`; }
function tags(id) {
  const x = TBY[id]; const g = (LANG === 'en' ? x.ge : x.g).slice(0, 2).join(' • ');
  const len = x.type === 'film' ? t(`${Math.floor(x.len / 60)}u ${x.len % 60}m`, `${Math.floor(x.len / 60)}h ${x.len % 60}m`) : t(`${x.seasons} ${x.seasons === 1 ? 'seizoen' : 'seizoenen'}`, `${x.seasons} ${x.seasons === 1 ? 'season' : 'seasons'}`);
  return `${x.year}  •  ${g}  •  ${len}`;
}
function btn(kind, icon, label, px, pad, extra = '') {
  const st = { w: 'background:#fff;color:#000', g: 'background:#ffffff38;color:#fff', r: `background:${RED};color:#fff`, d: `background:${EL};color:#fff` }[kind];
  return `<div style="display:inline-flex;align-items:center;justify-content:center;gap:${px * .45}px;font-weight:700;font-size:${px}px;border-radius:${px * .38}px;padding:${pad};white-space:nowrap;${st};${extra}">${icon ? I(icon, px * 1.05) : ''}${label}</div>`;
}
function pill(text, on, px = 13, extra = '') {
  return `<div style="padding:${px * .54}px ${px * 1.08}px;border-radius:999px;font-size:${px}px;font-weight:600;white-space:nowrap;${on ? 'background:#fff;color:#000' : `background:${EL};color:#fff`};${extra}">${text}</div>`;
}
function seg(items, sel, px = 13, extra = '') {
  return `<div style="display:flex;background:#1c1c1e;border-radius:${px * .7}px;padding:2px;${extra}">${items.map((x, i) => `<div style="flex:1;text-align:center;padding:${px * .45}px ${px}px;border-radius:${px * .55}px;font-size:${px}px;font-weight:600;${i === sel ? 'background:#636366' : ''}">${x}</div>`).join('')}</div>`;
}

// ---------- gedeelde inhoud ----------
const HERO = 'polder';
const CONT = [['noordlicht', 62, 38], ['haven', 25, 71], ['archief', 80, 9], ['stationzero', 40, 52], ['erfenis', 15, 44], ['kustlijn', 70, 21]];
const TOP10S = ['ekster', 'stillestad', 'glas', 'erfenis', 'archief'];
const FORYOU = ['nachtrit', 'kustlijn', 'diepzee', 'wolfsuur', 'vuurlinie', 'kortsluiting', 'zomer', 'stationzero'];
const MYLIST = ['glas', 'wolfsuur', 'zomer', 'kortsluiting', 'diepzee', 'ekster', 'haven', 'nachtrit'];
const EPS = [
  ['Het eerste signaal', 'The First Signal', 'Op het poolstation vangt Ilse een signaal op dat er niet hoort te zijn.', 'At the polar station, Ilse picks up a signal that shouldn’t be there.', 52, 1],
  ['Witte nacht', 'White Night', 'Een sneeuwstorm sluit het station af. Iemand heeft de radio gesaboteerd.', 'A blizzard cuts off the station. Someone has sabotaged the radio.', 48, 1],
  ['Poolwind', 'Polar Wind', 'Joris volgt de sporen in de sneeuw en vindt een tweede station.', 'Joris follows tracks in the snow and finds a second station.', 55, 1],
  ['De bron', 'The Source', 'Het signaal blijkt een boodschap te zijn, gericht aan Ilse zelf.', 'The signal turns out to be a message, addressed to Ilse herself.', 51, .35],
  ['Echo', 'Echo', 'De bemanning moet kiezen: vertrekken of het geheim ontrafelen.', 'The crew must choose: leave, or unravel the secret.', 49, 0],
  ['Dageraad', 'Dawn', 'Na maanden duisternis komt de zon op, en alles wordt zichtbaar.', 'After months of darkness the sun rises, and everything is revealed.', 58, 0],
];
const GENRES = [
  ['Actie', 'Action', '#c2410c', '#3b0d02', ['vuurlinie', 'nachtrit', 'kortsluiting'], 214],
  ['Drama', 'Drama', '#7c3aed', '#1e0b46', ['erfenis', 'kustlijn', 'stillestad'], 486],
  ['Thriller', 'Thriller', '#0f766e', '#021f1d', ['haven', 'ekster', 'archief'], 302],
  ['Sciencefiction', 'Sci-Fi', '#1d4ed8', '#0a1442', ['stationzero', 'kortsluiting', 'glas'], 127],
  ['Misdaad', 'Crime', '#475569', '#0b1220', ['polder', 'ekster', 'nachtrit'], 233],
  ['Documentaire', 'Documentary', '#15803d', '#04220f', ['diepzee', 'kustlijn', 'noordlicht'], 158],
  ['Animatie', 'Animation', '#db2777', '#4a0623', ['dex', 'piraten', 'zomer'], 96],
  ['Komedie', 'Comedy', '#d97706', '#3d1a02', ['zomer', 'dex', 'kustlijn'], 341],
  ['Horror', 'Horror', '#7f1d1d', '#140303', ['wolfsuur', 'archief', 'polder'], 88],
  ['Romantiek', 'Romance', '#be185d', '#3b0418', ['zomer', 'erfenis', 'kustlijn'], 175],
  ['Familie', 'Family', '#0891b2', '#05303b', ['dex', 'piraten', 'kustlijn'], 142],
  ['Mysterie', 'Mystery', '#4338ca', '#120d3d', ['noordlicht', 'archief', 'glas'], 119],
];
const SERVER = [
  ['NL | Series', 'NL | Series', '#9a3412', '#2a0c03', ['polder', 'stillestad', 'erfenis'], 412],
  ['Films 4K', 'Movies 4K', '#0369a1', '#03182b', ['stationzero', 'haven', 'vuurlinie'], 268],
  ['Kids', 'Kids', '#ca8a04', '#3a2702', ['dex', 'piraten', 'zomer'], 154],
  ['Nieuw deze week', 'New this week', '#be123c', '#300410', ['noordlicht', 'nachtrit', 'ekster'], 37],
];
function catTile(c, w, s = 1, focus = false) {
  const h = w / (16 / 9.5); const pw = h * .78 / 1.5;
  const fan = c[4].slice(0, 3).map((id, i) => ({ id, i })).reverse().map(({ id, i }) =>
    `<div style="position:absolute;right:${-pw * .18 + i * pw * .42}px;bottom:${-h * .12 - i * h * .03}px;width:${pw}px;height:${pw * 1.5}px;border-radius:${4 * s}px;${bg(posterURL(id, LANG))};box-shadow:-2px 3px ${6 * s}px #0008;transform:rotate(${i * 7 - 4}deg);transform-origin:50% 100%"></div>`).join('');
  return `<div style="position:relative;width:${w}px;height:${h}px;border-radius:${8 * s}px;overflow:hidden;flex:none;background:linear-gradient(135deg,${c[2]},${c[3]});box-shadow:inset 0 0 0 ${focus ? 3 * s : 1}px ${focus ? '#fff' : '#ffffff14'};${focus ? `transform:scale(1.06);z-index:2;filter:drop-shadow(0 ${16 * s}px ${20 * s}px #000c)` : ''}">
    ${fan}<div style="position:absolute;inset:0;background:linear-gradient(90deg,#0000008c,#0000000d)"></div>
    <div style="position:absolute;left:${10 * s}px;bottom:${10 * s}px;max-width:60%"><div style="font-size:${16 * s}px;font-weight:800;line-height:1.1;text-shadow:0 1px 4px #0008">${LANG === 'en' ? c[1] : c[0]}</div><div style="font-size:${11 * s}px;font-weight:600;color:#fffc;margin-top:${2 * s}px">${t(`${c[5]} titels`, `${c[5]} titles`)}</div></div>
    ${focus ? `<div style="position:absolute;inset:0;border-radius:inherit;box-shadow:inset 0 0 0 ${3 * s}px #fff"></div>` : ''}</div>`;
}
function chCard(c, w, s = 1) { // ChannelCard (landschap, met LIVE)
  const h = w * .5625;
  return `<div style="flex:none;width:${w}px"><div style="position:relative;width:${w}px;height:${h}px;border-radius:${6 * s}px;overflow:hidden;background:radial-gradient(circle at 30% 30%,${c.c}55,${CARD} 70%);display:grid;place-items:center">${chLogo(c, 20 * s)}
    <div style="position:absolute;top:${6 * s}px;left:${6 * s}px;display:flex;align-items:center;gap:${4 * s}px;background:#0009;border-radius:99px;padding:${3 * s}px ${7 * s}px;font-size:${9 * s}px;font-weight:900"><i style="width:${6 * s}px;height:${6 * s}px;border-radius:50%;background:${RED}"></i>LIVE</div>
    <div style="position:absolute;top:${6 * s}px;right:${7 * s}px">${I('star', 11 * s, IMDB)}</div>
    <div style="position:absolute;left:0;right:0;bottom:0;height:${3 * s}px;background:#ffffff33"><div style="height:100%;width:${c.p * 100}%;background:${RED}"></div></div></div>
    <div style="font-size:${13 * s}px;font-weight:600;margin-top:${5 * s}px">${c.n}</div><div style="font-size:${11 * s}px;color:${SEC};white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${LANG === 'en' ? c.now[1] : c.now[0]}</div></div>`;
}
const TIMES = ['20:00', '20:30', '21:00', '21:30', '22:00', '22:30', '23:00'];
// EPG-rijen: [breedte in half-uren, titel nl/en]
function epgRow(c, r) {
  const W = [[2.2, 1.8, 2], [1.4, 2.6, 2], [3, 1, 2], [1.6, 2, 2.4], [1, 2, 3], [3.6, 1.4, 1], [2, 2, 2], [1.4, 1.6, 3], [2.6, 1.4, 2], [1.2, 2.8, 2]][r % 10];
  const last = [['Late Show', 'Late Show'], ['Nachtfilm', 'Late Movie'], ['Herhaling', 'Rerun']][r % 3];
  return [[W[0], c.now], [W[1], c.next], [W[2], last]];
}
function epg(o) { // gedeelde tv-gids: o = {s, colW, slot, rowH, rows, nowAt (half-uren vanaf 20:00), focus:[r,i], showLogo}
  const { s, colW, slot, rowH, rows } = o;
  const chans = CHANNELS.slice(0, rows);
  return `<div style="display:flex;position:relative">
    <div style="width:${colW}px;flex:none"><div style="height:${30 * s}px"></div>${chans.map(c => `<div style="height:${rowH}px;background:${CARD};border-bottom:${1 * s}px solid #000;display:flex;align-items:center;padding:0 ${10 * s}px">${chLogo(c, 12 * s)}</div>`).join('')}</div>
    <div style="flex:1;overflow:hidden;position:relative">
      <div style="height:${30 * s}px;display:flex;color:${SEC};font-size:${11 * s}px;font-weight:600">${TIMES.map((x, i) => `<div style="width:${slot}px;flex:none;padding:${8 * s}px ${4 * s}px">${i === 0 ? t('Vandaag ', 'Today ') : ''}${x}</div>`).join('')}</div>
      ${chans.map((c, r) => { let x = 0; return `<div style="height:${rowH}px;position:relative;background:#101010;border-bottom:${1 * s}px solid #000">${epgRow(c, r).map(([wd, nm], i) => { const w = wd * slot; const st = x; x += w; const t0 = 20 * 60 + st / slot * 30, t1 = t0 + wd * 30; const fm = m => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(Math.round(m % 60 / 5) * 5 % 60).padStart(2, '0')}`; const foc = o.focus && o.focus[0] === r && o.focus[1] === i;
        return `<div style="position:absolute;left:${st + s}px;top:${2 * s}px;width:${w - 3 * s}px;height:${rowH - 5 * s}px;border-radius:${4 * s}px;background:${i === 0 ? '#3A1418' : EL};padding:${6 * s}px ${8 * s}px;overflow:hidden;${foc ? `box-shadow:0 0 0 ${3 * s}px #fff;background:#3a3a3a;z-index:2` : ''}"><div style="font-size:${12 * s}px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${LANG === 'en' ? nm[1] : nm[0]}</div><div style="font-size:${10 * s}px;color:${SEC};margin-top:${2 * s}px">${fm(t0)} – ${fm(t1)}</div>${i === 1 && r === 2 ? `<div style="position:absolute;top:${5 * s}px;right:${6 * s}px">${I('bell', 11 * s, IMDB)}</div>` : ''}</div>`; }).join('')}</div>`; }).join('')}
      <div style="position:absolute;top:${24 * s}px;bottom:0;left:${o.nowAt * slot}px;width:${2 * s}px;background:${RED}"><div style="position:absolute;top:0;left:${-4 * s}px;width:${10 * s}px;height:${10 * s}px;border-radius:50%;background:${RED}"></div></div>
    </div></div>`;
}
function tabbarPhone(sel) {
  const items = [['house', t('Home', 'Home')], ['radio', 'Live TV'], ['film', t('Films', 'Movies')], ['stack', 'Series'], ['me', t('Mijn Bingr', 'My Bingr')]];
  return `<div style="position:absolute;left:0;right:0;bottom:0;height:83px;background:#000000eb;border-top:.5px solid #ffffff1f;display:flex;justify-content:space-around;padding:7px 8px 0;z-index:20">${items.map(([ic, l], i) => `<div style="display:flex;flex-direction:column;align-items:center;gap:3px;width:70px;color:${i === sel ? '#fff' : '#8c8c8c'};font-size:10px;font-weight:500">${ic === 'me' ? `<div style="width:26px;height:26px;border-radius:5px;overflow:hidden;${i === sel ? 'box-shadow:0 0 0 1.5px #fff' : 'opacity:.75'}">${avatar(PROFILES[0], 26, '5px')}</div>` : I(ic, 26)}${l}</div>`).join('')}</div>
    <div style="position:absolute;left:50%;bottom:8px;width:134px;height:5px;margin-left:-67px;border-radius:3px;background:#fff;z-index:21"></div>`;
}
function phoneStatus(time = '20:41') {
  return `<div style="position:absolute;top:0;left:0;right:0;height:54px;display:flex;justify-content:space-between;align-items:center;padding:6px 34px 0 52px;font-weight:600;font-size:17px;z-index:30"><span>${time}</span>${statusIcons(1)}</div>`;
}

// ================= iPhone (402 × 874 pt) =================
const PHONE = {
  home() {
    return `<div class="app" style="width:402px;height:874px">
      <div style="position:absolute;inset:0 0 auto 0;height:640px;${bg(sceneURL(HERO, 330, 470))};filter:blur(46px) saturate(1.3);opacity:.7;transform:scale(1.25)"></div>
      <div style="position:absolute;inset:0 0 auto 0;height:660px;background:linear-gradient(#0000 40%,#000)"></div>
      ${phoneStatus()}
      <div style="position:absolute;top:56px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center">${logo(24)}<div style="display:flex;gap:18px;align-items:center">${I('airplay', 22)}${I('search', 22)}${avatar(PROFILES[0], 28, '5px')}</div></div>
      <div style="position:absolute;top:100px;left:16px;display:flex;gap:8px">${['Series', t('Films', 'Movies')].map(x => `<div style="padding:6px 14px;border-radius:99px;border:1px solid #ffffff59;font-size:14px;font-weight:600">${x}</div>`).join('')}<div style="padding:6px 12px 6px 14px;border-radius:99px;border:1px solid #ffffff59;font-size:14px;font-weight:600;display:flex;gap:4px;align-items:center">${t('Categorieën', 'Categories')}${I('chevD', 14)}</div></div>
      <div style="position:absolute;top:146px;left:36px;width:330px;height:470px;border-radius:12px;overflow:hidden;${bg(sceneURL(HERO, 330, 470))};box-shadow:0 10px 40px #000a,0 0 0 1px #ffffff1f">
        <div style="position:absolute;inset:0;background:linear-gradient(#0000 50%,#000000d9)"></div>
        <div style="position:absolute;left:16px;right:16px;bottom:16px;text-align:center">
          <div style="font-family:${FONT.display};font-weight:900;font-size:30px;letter-spacing:1px;text-shadow:0 2px 8px #0008">${TN(HERO).toUpperCase()}</div>
          <div style="font-size:12px;font-weight:500;color:#ffffffd9;margin:9px 0 12px">${tags(HERO)}</div>
          <div style="display:flex;gap:10px">${btn('w', 'play', t('Afspelen', 'Play'), 16, '10px 0', 'flex:1;border-radius:6px')}${btn('g', 'info', 'Info', 16, '10px 0', 'flex:1;border-radius:6px')}</div></div></div>
      <div style="position:absolute;top:636px;left:0;right:0">${rowHead(t('Verder kijken', 'Continue watching'), false)}<div style="display:flex;gap:8px;padding:0 16px">${CONT.slice(0, 4).map(c => cont(c[0], 112, c[1], c[2])).join('')}</div></div>
      ${tabbarPhone(0)}</div>`;
  },
  detail() {
    const id = 'noordlicht', x = TBY[id];
    return `<div class="app" style="width:402px;height:874px">
      <div style="position:absolute;top:0;left:0;right:0;height:440px;${bg(sceneURL(id, 402, 440, 1))}"></div>
      <div style="position:absolute;top:0;left:0;right:0;height:442px;background:linear-gradient(#0006,#0000 25%,#0000 50%,#000c 82%,#000)"></div>
      ${phoneStatus('20:43')}
      <div style="position:absolute;top:58px;right:16px;width:40px;height:40px;border-radius:50%;background:#ffffff33;backdrop-filter:blur(10px);display:grid;place-items:center">${I('x', 17)}</div>
      <div style="position:absolute;top:322px;left:0;right:0;display:flex;justify-content:center">${titleLogo(id, LANG, 40)}</div>
      <div style="position:absolute;top:384px;left:16px;right:16px">
        <div style="display:flex;justify-content:center;gap:12px;align-items:center;font-size:15px;color:#ddd">${imdb(x.rating, 15)}<span>${x.year}</span>${ageBox(x.age, 14)}<span>${t('2 seizoenen', '2 seasons')}</span></div>
        <div style="margin-top:16px;background:#fff;color:#000;border-radius:999px;height:50px;display:flex;align-items:center;justify-content:center;gap:8px;font-weight:700;font-size:16px">${I('play', 17)}${t('Speel seizoen 1: aflevering 4', 'Play Season 1: Episode 4')}</div>
        <div style="display:flex;gap:10px;margin-top:10px">${['heart', 'clapper', 'download'].map((k, i) => `<div style="width:48px;height:48px;border-radius:50%;background:#ffffff1f;display:grid;place-items:center">${I(k, 20, i === 0 ? RED : '#fff')}</div>`).join('')}<div style="flex:1;height:48px;border-radius:999px;background:#ffffff1f;display:flex;align-items:center;justify-content:center;gap:7px;font-size:15px;font-weight:600">${I('stack3d', 17)}${t('Andere bronnen', 'Other sources')}</div></div>
        <p style="font-size:15px;line-height:1.4;margin:16px 0 0;color:#ffffffeb">${LANG === 'en' ? x.de : x.d}</p>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-top:20px"><div style="font-size:19px;font-weight:700">${t('Afleveringen', 'Episodes')}</div><div style="background:#ffffff1f;border-radius:999px;padding:8px 14px;font-weight:600;font-size:14px;display:flex;gap:6px;align-items:center">${t('Seizoen 1', 'Season 1')}${I('chevD', 13)}</div></div>
        <div style="display:flex;gap:12px;margin-top:12px">${EPS.slice(2, 4).map((e, i) => `<div style="width:262px;flex:none;background:#ffffff0f;border-radius:12px;padding-bottom:10px;overflow:hidden">
          <div style="height:128px;position:relative;${bg(sceneURL(id, 262, 128, 10 + i))};border-radius:12px">${e[5] === 1 ? `<div style="position:absolute;top:8px;right:8px;width:22px;height:22px;border-radius:50%;background:${RED};display:grid;place-items:center">${I('check', 13, '#fff')}</div>` : ''}<div style="position:absolute;left:12px;right:12px;bottom:10px;height:4px;border-radius:4px;background:#ffffff4d"><div style="height:100%;width:${e[5] * 100}%;background:#fff;border-radius:4px"></div></div></div>
          <div style="padding:8px 10px 0"><div style="color:${SEC};font-size:12px">S01E0${i + 3}</div><div style="font-weight:600;font-size:15px">${LANG === 'en' ? e[1] : e[0]}</div><div style="color:${SEC};font-size:12px;line-height:1.3;margin-top:2px;height:31px;overflow:hidden">${LANG === 'en' ? e[3] : e[2]}</div></div></div>`).join('')}</div>
      </div></div>`;
  },
  guide() {
    return `<div class="app" style="width:402px;height:874px">${phoneStatus('20:45')}
      <div style="position:absolute;top:54px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center"><div style="font-size:32px;font-weight:800">Live TV</div><div style="display:flex;gap:16px;color:${RED}">${I('list', 24)}${I('guide', 24)}${I('search', 22, '#fff')}</div></div>
      <div style="position:absolute;top:104px;left:16px;display:flex;gap:8px">${[t('Alle zenders', 'All channels'), '★ ' + t('Favorieten', 'Favorites'), t('Recent', 'Recent'), 'Sport', 'Docu'].map((x, i) => pill(x, i === 0, 13)).join('')}</div>
      <div style="position:absolute;top:146px;left:0;right:0;height:210px;margin:0 16px;border-radius:12px;overflow:hidden;background:radial-gradient(circle at 70% 40%,#22c55e66,#0b1a10 70%)">
        <div style="position:absolute;inset:0;${bg(sceneURL('kustlijn', 370, 210, 3))};opacity:.0"></div>
        ${stadium(370, 210)}
        <div style="position:absolute;inset:0;background:linear-gradient(#0000 45%,#000d)"></div>
        <div style="position:absolute;top:10px;left:10px;display:flex;align-items:center;gap:4px;background:#0009;border-radius:99px;padding:3px 8px;font-size:10px;font-weight:900"><i style="width:6px;height:6px;border-radius:50%;background:${RED}"></i>LIVE</div>
        <div style="position:absolute;left:12px;right:12px;bottom:10px"><div style="display:flex;align-items:center;gap:8px">${chLogo(CHANNELS[1], 12)}</div><div style="font-size:16px;font-weight:700;margin-top:5px">${t('Voetbal: halve finale', 'Football: semi-final')}</div><div style="height:3px;border-radius:2px;background:#ffffff40;margin-top:6px"><div style="height:100%;width:41%;background:${RED};border-radius:2px"></div></div></div></div>
      <div style="position:absolute;top:368px;left:0;right:0">${epg({ s: 1, colW: 118, slot: 120, rowH: 58, rows: 7, nowAt: 1.5, focus: [1, 0] })}</div>
      ${tabbarPhone(1)}</div>`;
  },
  categories() {
    const W = (402 - 32 - 12) / 2;
    return `<div class="app" style="width:402px;height:874px;background:#000">${phoneStatus('20:47')}
      <div style="position:absolute;top:60px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center"><div style="font-size:28px;font-weight:900">${t('Categorieën', 'Categories')}</div><div style="width:40px;height:40px;border-radius:50%;background:#ffffff26;display:grid;place-items:center">${I('x', 17)}</div></div>
      ${seg([t('Alles', 'All'), t('Films', 'Movies'), 'Series'], 0, 13, 'position:absolute;top:112px;left:16px;right:16px')}
      <div style="position:absolute;top:160px;left:16px;right:16px">
        <div style="font-size:19px;font-weight:700;margin-bottom:10px">${t('Genres', 'Genres')}</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">${GENRES.slice(0, 8).map(c => catTile(c, W)).join('')}</div>
        <div style="font-size:19px;font-weight:700;margin:22px 0 10px">${t('Van je server', 'From your server')}</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">${SERVER.map(c => catTile(c, W)).join('')}</div></div></div>`;
  },
  profiles() {
    const P = PROFILES;
    const it = (p, i) => `<div style="display:flex;flex-direction:column;align-items:center;gap:9px">${avatar(p, 124, '12px')}<div style="font-size:16px;color:#ddd;display:flex;align-items:center;gap:6px">${LANG === 'en' ? p.nameEn : p.name}${p.age != null ? I('lock', 12, SEC) : ''}</div></div>`;
    return `<div class="app" style="width:402px;height:874px;background:#000">${phoneStatus('20:40')}
      <div style="position:absolute;top:62px;left:0;right:0;display:flex;justify-content:center">${logo(26)}</div>
      <div style="position:absolute;top:150px;left:0;right:0;text-align:center;font-size:26px;font-weight:600">${t('Wie kijkt er?', 'Who’s watching?')}</div>
      <div style="position:absolute;top:214px;left:0;right:0;display:grid;grid-template-columns:repeat(2,124px);gap:30px 36px;justify-content:center">
        ${P.map(it).join('')}
        <div style="display:flex;flex-direction:column;align-items:center;gap:9px"><div style="width:124px;height:124px;border-radius:12px;border:2px solid #ffffff40;display:grid;place-items:center">${I('plus', 46, '#ffffffb0')}</div><div style="font-size:16px;color:${SEC}">${t('Profiel toevoegen', 'Add profile')}</div></div></div>
      <div style="position:absolute;bottom:52px;left:0;right:0;display:flex;justify-content:center">${btn('d', 'pencil', t('Profielen beheren', 'Manage profiles'), 15, '12px 22px', 'border-radius:99px;font-weight:600')}</div>
      <div style="position:absolute;left:50%;bottom:8px;width:134px;height:5px;margin-left:-67px;border-radius:3px;background:#fff"></div></div>`;
  },
  mybingr() {
    return `<div class="app" style="width:402px;height:874px;background:#000">${phoneStatus('20:48')}
      <div style="position:absolute;top:58px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center"><div style="display:flex;align-items:center;gap:10px">${avatar(PROFILES[0], 40, '7px')}<div style="font-size:24px;font-weight:800">Sanne</div>${I('chevD', 16)}</div>
        <div style="display:flex;align-items:center;gap:6px;background:#46d3691f;color:${GREEN};border-radius:99px;padding:6px 11px;font-size:13px;font-weight:600">${I('checkCircle', 15, GREEN)}${t('Bijgewerkt', 'Up to date')}</div></div>
      <div style="position:absolute;top:120px;left:0;right:0">
        ${rowHead(t('Verder kijken', 'Continue watching'), false)}<div style="display:flex;gap:8px;padding:0 16px">${CONT.slice(0, 4).map(c => cont(c[0], 112, c[1], c[2])).join('')}</div>
        <div style="height:22px"></div>${rowHead(t('Favoriete zenders', 'Favorite channels'), false)}<div style="display:flex;gap:8px;padding:0 16px">${[1, 3, 4].map(i => chCard(CHANNELS[i], 200)).join('')}</div>
        <div style="height:22px"></div>${rowHead(t('Mijn lijst', 'My List'), true)}<div style="display:flex;gap:8px;padding:0 16px">${MYLIST.slice(0, 4).map(id => poster(id, 112)).join('')}</div></div>
      ${tabbarPhone(4)}</div>`;
  },
  stats() {
    return `<div class="app" style="width:402px;height:874px;background:#000">${phoneStatus('20:49')}
      <div style="position:absolute;top:54px;left:10px;display:flex;align-items:center;gap:2px;color:${RED};font-size:17px">${I('chevL', 22, RED)}${t('Mijn Bingr', 'My Bingr')}</div>
      <div style="position:absolute;top:92px;left:16px;font-size:32px;font-weight:800">${t('Statistieken', 'Statistics')}</div>
      <div style="position:absolute;top:144px;left:16px;display:flex;gap:8px">${[t('Alle profielen', 'All profiles'), 'Sanne', 'Daan', 'Noor'].map((x, i) => pill(x, i === 0, 13)).join('')}</div>
      ${seg(['Week', t('Maand', 'Month'), t('Jaar', 'Year')], 1, 13, 'position:absolute;top:186px;left:16px;right:16px')}
      <div style="position:absolute;top:228px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center">${I('chevL', 20, RED)}<div style="font-size:17px;font-weight:700">${t('september 2026', 'September 2026')}</div>${I('chevR', 20, RED)}</div>
      <div style="position:absolute;top:264px;left:16px;right:16px">${statTiles(1, 2)}</div>
      <div style="position:absolute;top:478px;left:16px;right:16px">${statChart(370, 120, 1)}</div>
      <div style="position:absolute;top:676px;left:16px;right:16px">${topList(t('Topseries', 'Top series'), [['noordlicht', 9, 4, 30], ['polder', 6, 5, 10]], 1)}</div>
      ${tabbarPhone(4)}</div>`;
  },
};
// voetbalveld (fictief beeld voor live sport)
function stadium(w, h) {
  return `<svg viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" style="position:absolute;inset:0" preserveAspectRatio="xMidYMid slice"><defs><linearGradient id="gs" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0b1a10"/><stop offset=".35" stop-color="#1a3d22"/><stop offset="1" stop-color="#2f7a3c"/></linearGradient></defs>
    <rect width="${w}" height="${h}" fill="url(#gs)"/>${Array.from({ length: 8 }, (_, i) => `<polygon points="${w * (.5 - .7 + i * .175)},${h} ${w * (.5 - .7 + (i + 1) * .175)},${h} ${w * (.5 - .3 + (i + 1) * .075)},${h * .38} ${w * (.5 - .3 + i * .075)},${h * .38}" fill="#fff" opacity="${i % 2 ? .04 : 0}"/>`).join('')}
    <polygon points="${w * .2},${h * .38} ${w * .8},${h * .38} ${w * 1.1},${h} ${-w * .1},${h}" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="1.5"/><line x1="${w * .5}" y1="${h * .38}" x2="${w * .5}" y2="${h}" stroke="#fff" stroke-opacity=".5" stroke-width="1.5"/>
    <ellipse cx="${w * .5}" cy="${h * .66}" rx="${w * .13}" ry="${h * .09}" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="1.5"/>
    ${Array.from({ length: 30 }, (_, i) => `<circle cx="${(i * 37) % w}" cy="${h * .08 + (i * 13) % (h * .22)}" r="1.4" fill="#fff" opacity=".35"/>`).join('')}
    ${[[.38, .6, '#fff'], [.47, .72, '#e11d48'], [.6, .55, '#fff'], [.66, .8, '#e11d48'], [.3, .82, '#fff']].map(([x, y, c]) => `<g><circle cx="${w * x}" cy="${h * y - 8}" r="3" fill="${c}"/><rect x="${w * x - 3}" y="${h * y - 5}" width="6" height="10" rx="2" fill="${c}"/></g>`).join('')}<circle cx="${w * .52}" cy="${h * .7}" r="2.5" fill="#fff"/></svg>`;
}
function statTiles(s, cols) {
  const tiles = [[t('Uren gekeken', 'Hours watched'), 'clock', '#fff', t('41 u 20 min', '41 h 20 min'), t('september 2026', 'September 2026')],
    [t('Films', 'Movies'), 'filmfill', RED, t('12 u 5 min', '12 h 5 min'), t('7 films', '7 movies')],
    ['Series', 'tvfill', SERIES_C, t('21 u 40 min', '21 h 40 min'), t('4 series · 26 afleveringen', '4 series · 26 episodes')],
    ['Live TV', 'radio', LIVE_C, t('7 u 35 min', '7 h 35 min'), t('9 zenders', '9 channels')]];
  return `<div style="display:grid;grid-template-columns:repeat(${cols},1fr);gap:${10 * s}px">${tiles.map(x => `<div style="background:${CARD};border-radius:${12 * s}px;padding:${12 * s}px ${14 * s}px;box-shadow:inset 0 0 0 1px #ffffff0f">
    <div style="display:flex;align-items:center;gap:${6 * s}px;color:${x[2]};font-size:${13 * s}px;font-weight:600">${I(x[1], 14 * s, x[2])}${x[0]}</div>
    <div style="font-size:${22 * s}px;font-weight:700;margin-top:${5 * s}px;font-variant-numeric:tabular-nums">${x[3]}</div><div style="font-size:${12 * s}px;color:${SEC};margin-top:${3 * s}px">${x[4]}</div></div>`).join('')}</div>`;
}
function statChart(w, h, s) {
  const r = rng(42); const days = 30, today = 30;
  const bw = (w - 30 * s - 28 * s) / days;
  let bars = '';
  const max = 5;
  for (let d = 0; d < days; d++) {
    if (d >= today) continue;
    const we = (d % 7 === 4 || d % 7 === 5);
    const m = r() < .5 ? (we ? 1.6 + r() * 1.5 : r() * 1.2) : 0, e = (we ? .9 : .4) + r() * 1.3, l = r() < .6 ? r() * .9 : 0;
    let y = h; const seg = (v, c, top) => { const hh = v / max * (h - 20 * s); y -= hh; return `<rect x="${30 * s + d * bw + bw * .18}" y="${y}" width="${bw * .64}" height="${hh}" fill="${c}" ${top ? `rx="${2 * s}"` : ''}/>`; };
    bars += seg(m, RED) + seg(e, SERIES_C) + seg(l, LIVE_C, true);
  }
  const grid = [0, 2, 4].map(v => { const y = h - v / max * (h - 20 * s); return `<line x1="${30 * s}" x2="${w}" y1="${y}" y2="${y}" stroke="#ffffff1a"/><text x="0" y="${y + 4 * s}" fill="${SEC}" font-size="${10 * s}">${v} ${t('u', 'h')}</text>`; }).join('');
  const lbl = [1, 8, 15, 22, 29].map(d => `<text x="${30 * s + (d - 1) * bw + bw / 2}" y="${h + 14 * s}" fill="${SEC}" font-size="${10 * s}" text-anchor="middle">${d}</text>`).join('');
  return `<div style="background:${CARD};border-radius:${12 * s}px;padding:${14 * s}px;box-shadow:inset 0 0 0 1px #ffffff0f">
    <div style="display:flex;gap:${14 * s}px;font-size:${12 * s}px;color:${SEC};margin-bottom:${10 * s}px">${[[t('Films', 'Movies'), RED], ['Series', SERIES_C], ['Live TV', LIVE_C]].map(([n, c]) => `<span style="display:flex;align-items:center;gap:${5 * s}px"><i style="width:${9 * s}px;height:${9 * s}px;border-radius:50%;background:${c}"></i>${n}</span>`).join('')}</div>
    <svg width="${w - 28 * s}" height="${h + 18 * s}" viewBox="0 0 ${w - 28 * s} ${h + 18 * s}" style="font-family:inherit;display:block">${grid}${bars}${lbl}</svg></div>`;
}
function topList(title, items, s, max = 99) {
  return `<div style="font-size:${19 * s}px;font-weight:700;margin-bottom:${8 * s}px">${title}</div>${items.slice(0, max).map((x, i) => `<div style="display:flex;align-items:center;gap:${12 * s}px;padding:${7 * s}px 0;${i ? 'border-top:1px solid #ffffff14' : ''}">
    <div style="width:${18 * s}px;color:${SEC};font-weight:700;font-size:${15 * s}px;text-align:center">${i + 1}</div>${poster(x[0], 34 * s, { s: s * .6 })}
    <div style="flex:1;min-width:0"><div style="font-size:${15 * s}px;font-weight:600">${TN(x[0])}</div><div style="font-size:${12 * s}px;color:${SEC};margin-top:${2 * s}px">${x[1] ? t(`${x[1]} afleveringen · `, `${x[1]} episodes · `) : ''}${t(`${x[2]} u ${x[3]} min`, `${x[2]} h ${x[3]} min`)}</div></div>
    <div style="width:${70 * s}px;height:${5 * s}px;border-radius:9px;background:#ffffff1a"><div style="height:100%;border-radius:9px;width:${100 - i * 28}%;background:${x[1] ? SERIES_C : RED}"></div></div></div>`).join('')}`;
}

// ================= iPad (1032 × 1376 pt) en Mac (venster) — brede lay-out =================
function ipadTabs(sel, w) {
  const items = [t('Home', 'Home'), 'Live TV', t('Films', 'Movies'), 'Series', t('Categorieën', 'Categories')];
  return `<div style="position:absolute;top:30px;left:0;right:0;display:flex;justify-content:center;z-index:20"><div style="display:flex;align-items:center;gap:2px;padding:5px;border-radius:99px;background:#2c2c2ee6;backdrop-filter:blur(20px);box-shadow:0 6px 24px #0008,inset 0 0 0 1px #ffffff14">
    ${items.map((x, i) => `<div style="padding:9px 18px;border-radius:99px;font-size:15px;font-weight:600;${i === sel ? 'background:#ffffff2e;color:#fff' : 'color:#d0d0d0'}">${x}</div>`).join('')}
    <div style="padding:8px 12px;color:#d0d0d0">${I('search', 18)}</div><div style="padding:8px 12px;color:#d0d0d0">${I('download', 19)}</div><div style="padding:3px 6px 3px 8px">${avatar(PROFILES[0], 28, '6px')}</div></div></div>`;
}
function ipadStatus() { return `<div style="position:absolute;top:0;left:0;right:0;height:26px;display:flex;justify-content:space-between;align-items:center;padding:4px 26px 0;font-size:14px;font-weight:600;z-index:30"><span>20:41 &nbsp;${t('di 14 okt.', 'Tue Oct 14')}</span><div style="display:flex;align-items:center;gap:8px"><span style="font-size:13px">100%</span>${statusIcons(.9).replace(/<svg width="[\d.]+" height="[\d.]+" viewBox="0 0 18 12">.*?<\/svg>/, '')}</div></div>`; }
function macTabs(sel) {
  const items = [t('Home', 'Home'), 'Live TV', t('Films', 'Movies'), 'Series', t('Categorieën', 'Categories'), t('Zoeken', 'Search'), t('Mijn Bingr', 'My Bingr')];
  return `<div style="display:flex;background:#ffffff14;border-radius:8px;padding:2px">${items.map((x, i) => `<div style="padding:4px 13px;border-radius:6px;font-size:13px;font-weight:500;${i === sel ? 'background:#ffffff33;color:#fff' : 'color:#cfcfcf'}">${x}</div>`).join('')}</div>`;
}
// o: {w,h,mac}
const WIDE = {
  home(o) {
    const { w, h, mac } = o; const top = mac ? 22 : 104; const cw = 330, ch = 470;
    const cards = Math.floor((w - 32 + 8) / 120);
    return `<div class="app" style="width:${w}px;height:${h}px">
      <div style="position:absolute;left:-10%;right:-10%;top:-40px;height:${ch + top + 200}px;${bg(sceneURL(HERO, 330, 470))};filter:blur(60px) saturate(1.3);opacity:.65"></div>
      <div style="position:absolute;inset:0 0 auto 0;height:${ch + top + 200}px;background:linear-gradient(#0000 45%,#000)"></div>
      ${mac ? '' : ipadStatus() + ipadTabs(0, w)}
      ${mac ? '' : `<div style="position:absolute;top:34px;left:26px">${logo(24)}</div>`}
      <div style="position:absolute;top:${top}px;left:${(w - cw) / 2}px;width:${cw}px;height:${ch}px;border-radius:12px;overflow:hidden;${bg(sceneURL(HERO, cw, ch))};box-shadow:0 10px 40px #000a,0 0 0 1px #ffffff1f">
        <div style="position:absolute;inset:0;background:linear-gradient(#0000 50%,#000000d9)"></div>
        <div style="position:absolute;left:16px;right:16px;bottom:16px;text-align:center"><div style="font-family:${FONT.display};font-weight:900;font-size:30px;letter-spacing:1px">${TN(HERO).toUpperCase()}</div>
        <div style="font-size:12px;font-weight:500;color:#ffffffd9;margin:9px 0 12px">${tags(HERO)}</div>
        <div style="display:flex;gap:10px">${btn('w', 'play', t('Afspelen', 'Play'), 16, '10px 0', 'flex:1;border-radius:6px')}${btn('g', 'info', 'Info', 16, '10px 0', 'flex:1;border-radius:6px')}</div></div></div>
      <div style="position:absolute;top:${top + ch + 26}px;left:0;right:0">
        ${rowHead(t('Verder kijken', 'Continue watching'), false, 21, 20)}<div style="display:flex;gap:10px;padding:0 20px">${CONT.concat(CONT).slice(0, cards).map(c => cont(c[0], 120, c[1], c[2])).join('')}</div>
        <div style="height:26px"></div>${rowHead(t('Top 10 series vandaag', 'Top 10 series today'), true, 21, 20)}<div style="display:flex;gap:4px;padding:0 20px">${TOP10S.map((id, i) => top10(id, i + 1, 120, 1, i === 1 ? t('Nieuw seizoen', 'New season') : null)).join('')}</div>
        <div style="height:26px"></div>${rowHead(t('Voor jou', 'For you'), true, 21, 20)}<div style="display:flex;gap:10px;padding:0 20px">${FORYOU.slice(0, cards).map((id, i) => poster(id, 120, { badge: i % 3 === 0 ? (TBY[id].type === 'film' ? t('FILM', 'MOVIE') : t('SERIE', 'SERIES')) : null })).join('')}</div></div></div>`;
  },
  detail(o) {
    const { w, h, mac } = o; const id = 'noordlicht', x = TBY[id]; const bh = mac ? 330 : 560;
    const top = mac ? 0 : 0;
    return `<div class="app" style="width:${w}px;height:${h}px;background:#000">
      <div style="position:absolute;top:0;left:0;right:0;height:${bh}px;${bg(sceneURL(id, w, bh, 1))}"></div>
      <div style="position:absolute;top:0;left:0;right:0;height:${bh + 2}px;background:linear-gradient(90deg,#000c,#0000 60%),linear-gradient(#0000 50%,#000)"></div>
      ${mac ? '' : ipadStatus()}
      <div style="position:absolute;top:${mac ? 16 : 40}px;right:24px;width:40px;height:40px;border-radius:50%;background:#ffffff33;display:grid;place-items:center">${I('x', 17)}</div>
      <div style="position:absolute;left:${mac ? 40 : 40}px;top:${mac ? 70 : 250}px;display:flex;gap:30px;align-items:flex-end">
        ${poster(id, mac ? 150 : 200, { r: 8 })}
        <div style="padding-bottom:6px">${titleLogo(id, LANG, mac ? 40 : 52, 'left')}
          <div style="display:flex;gap:14px;align-items:center;font-size:16px;color:#ddd;margin:14px 0 18px">${imdb(x.rating, 16)}<span>${x.year}</span>${ageBox(x.age, 15)}<span>${t('2 seizoenen', '2 seasons')}</span><span style="color:${SEC}">${(LANG === 'en' ? x.ge : x.g).join(' • ')}</span></div>
          <div style="display:flex;gap:10px">${btn('w', 'play', t('Afspelen S1:A4', 'Play S1:E4'), 16, '12px 26px', 'border-radius:99px')}${btn('g', 'clapper', 'Trailer', 16, '12px 22px', 'border-radius:99px')}${btn('g', 'check', t('Mijn lijst', 'My List'), 16, '12px 22px', 'border-radius:99px')}${btn('g', 'stack3d', t('Andere bronnen', 'Other sources'), 16, '12px 22px', 'border-radius:99px')}</div></div></div>
      <div style="position:absolute;left:40px;right:40px;top:${mac ? 330 : 590}px">
        ${mac ? '' : `<p style="font-size:17px;line-height:1.45;max-width:760px;color:#ffffffe6;margin-bottom:26px">${LANG === 'en' ? x.de : x.d}</p>`}
        <div style="display:flex;justify-content:space-between;align-items:center"><div style="font-size:22px;font-weight:700">${t('Afleveringen', 'Episodes')}</div><div style="background:#ffffff1f;border-radius:999px;padding:9px 16px;font-weight:600;font-size:15px;display:flex;gap:6px;align-items:center">${t('Seizoen 1 · 50% bekeken', 'Season 1 · 50% watched')}${I('chevD', 14)}</div></div>
        <div style="display:grid;grid-template-columns:${mac ? '1fr 1fr 1fr' : '1fr 1fr'};gap:18px 28px;margin-top:18px">${EPS.slice(0, mac ? 3 : 6).map((e, i) => `<div style="display:flex;gap:16px;align-items:flex-start">
          <div style="width:${mac ? 150 : 200}px;height:${mac ? 84 : 112}px;flex:none;border-radius:8px;position:relative;${bg(sceneURL(id, 200, 112, 20 + i))}"><div style="position:absolute;inset:0;display:grid;place-items:center"><div style="width:34px;height:34px;border-radius:50%;background:#0008;border:1.5px solid #fff;display:grid;place-items:center;padding-left:2px">${I('play', 14)}</div></div>${e[5] > 0 && e[5] < 1 ? `<div style="position:absolute;left:0;right:0;bottom:0;height:4px;background:#ffffff4d"><div style="height:100%;width:${e[5] * 100}%;background:${RED}"></div></div>` : ''}${e[5] === 1 ? `<div style="position:absolute;top:6px;right:6px;width:20px;height:20px;border-radius:50%;background:${RED};display:grid;place-items:center">${I('check', 12, '#fff')}</div>` : ''}</div>
          <div style="min-width:0"><div style="font-size:16px;font-weight:600">${i + 1}. ${LANG === 'en' ? e[1] : e[0]}</div><div style="font-size:13px;color:${SEC};margin:3px 0 5px">${e[4]} min</div><div style="font-size:13px;color:#ffffffbf;line-height:1.35">${LANG === 'en' ? e[3] : e[2]}</div></div></div>`).join('')}</div></div></div>`;
  },
  guide(o) {
    const { w, h, mac } = o; const top = mac ? 18 : 96;
    return `<div class="app" style="width:${w}px;height:${h}px;background:#000">
      ${mac ? '' : ipadStatus() + ipadTabs(1, w)}
      <div style="position:absolute;top:${top}px;left:24px;right:24px;display:flex;gap:24px">
        <div style="flex:1.25;height:${mac ? 250 : 330}px;border-radius:14px;overflow:hidden;position:relative;background:#0b1a10">${stadium(mac ? 560 : 560, mac ? 250 : 330)}
          <div style="position:absolute;inset:0;background:linear-gradient(#0000 50%,#000d)"></div>
          <div style="position:absolute;top:12px;left:12px;display:flex;align-items:center;gap:5px;background:#0009;border-radius:99px;padding:4px 10px;font-size:11px;font-weight:900"><i style="width:7px;height:7px;border-radius:50%;background:${RED}"></i>LIVE</div>
          <div style="position:absolute;left:16px;bottom:14px;right:16px">${chLogo(CHANNELS[1], 14)}<div style="font-size:22px;font-weight:800;margin-top:6px">${t('Voetbal: halve finale', 'Football: semi-final')}</div><div style="height:4px;border-radius:2px;background:#ffffff40;margin-top:8px"><div style="height:100%;width:41%;background:${RED};border-radius:2px"></div></div></div></div>
        <div style="flex:1;display:flex;flex-direction:column;gap:12px;padding-top:4px">
          <div style="font-size:34px;font-weight:800">Live TV</div>
          <div style="background:#1c1c1e;border-radius:10px;padding:10px 12px;color:#8e8e93;font-size:16px;display:flex;gap:8px;align-items:center">${I('search', 16, '#8e8e93')}${t('Zoek zender of programma', 'Search channel or program')}</div>
          <div style="display:flex;flex-wrap:wrap;gap:8px">${[t('Alle zenders', 'All channels'), '★ ' + t('Favorieten', 'Favorites'), t('Recent', 'Recent'), 'Sport', 'Docu', 'Kids', t('Muziek', 'Music')].map((x, i) => pill(x, i === 0, 14)).join('')}</div>
          <div style="font-size:14px;color:${SEC};margin-top:auto">${t('Straks op Veldsport: Sportcafé · 22:00', 'Next on Veldsport: Sports Café · 22:00')}</div></div></div>
      <div style="position:absolute;top:${top + (mac ? 270 : 356)}px;left:24px;right:0">${epg({ s: 1.1, colW: 150, slot: 150, rowH: 66, rows: mac ? 5 : 10, nowAt: 1.5, focus: [1, 0] })}</div></div>`;
  },
  categories(o) {
    const { w, h, mac } = o; const top = mac ? 22 : 100; const cols = mac ? 4 : 3; const gap = 14;
    const tw = (w - 48 - gap * (cols - 1)) / cols;
    return `<div class="app" style="width:${w}px;height:${h}px;background:#000">
      ${mac ? '' : ipadStatus() + ipadTabs(4, w)}
      <div style="position:absolute;top:${top}px;left:24px;right:24px">
        <div style="display:flex;justify-content:space-between;align-items:center"><div style="font-size:30px;font-weight:900">${t('Categorieën', 'Categories')}</div>${seg([t('Alles', 'All'), t('Films', 'Movies'), 'Series'], 0, 14, 'width:300px')}</div>
        <div style="font-size:21px;font-weight:700;margin:20px 0 12px">${t('Genres', 'Genres')}</div>
        <div style="display:grid;grid-template-columns:repeat(${cols},1fr);gap:${gap}px">${GENRES.slice(0, mac ? 8 : 12).map(c => catTile(c, tw, 1.15)).join('')}</div>
        <div style="font-size:21px;font-weight:700;margin:26px 0 12px">${t('Van je server', 'From your server')}</div>
        <div style="display:grid;grid-template-columns:repeat(${cols},1fr);gap:${gap}px">${SERVER.slice(0, cols).map(c => catTile(c, tw, 1.15)).join('')}</div></div></div>`;
  },
  profiles(o) {
    const { w, h, mac } = o; const S = mac ? 130 : 150;
    return `<div class="app" style="width:${w}px;height:${h}px;background:#000">${mac ? '' : ipadStatus()}
      <div style="position:absolute;top:${mac ? 30 : 60}px;left:0;right:0;display:flex;justify-content:center">${logo(mac ? 28 : 36)}</div>
      <div style="position:absolute;top:${h * .3}px;left:0;right:0;text-align:center;font-size:40px;font-weight:600">${t('Wie kijkt er?', 'Who’s watching?')}</div>
      <div style="position:absolute;top:${h * .3 + 90}px;left:0;right:0;display:flex;justify-content:center;flex-wrap:wrap;gap:40px 34px;padding:0 60px">
        ${PROFILES.map((p, i) => `<div style="display:flex;flex-direction:column;align-items:center;gap:12px;width:${S}px">${avatar(p, S, '14px')}<div style="font-size:19px;color:#ddd;display:flex;align-items:center;gap:6px">${LANG === 'en' ? p.nameEn : p.name}${p.age != null ? I('lock', 14, SEC) : ''}</div>${p.age != null ? `<div style="font-size:13px;color:${SEC};margin-top:-6px">${t(`Tot en met ${p.age} jaar`, `Up to ${p.age} years`)}</div>` : ''}</div>`).join('')}
        <div style="display:flex;flex-direction:column;align-items:center;gap:12px;width:${S}px"><div style="width:${S}px;height:${S}px;border-radius:14px;border:2px solid #ffffff40;display:grid;place-items:center">${I('plus', 54, '#ffffffb0')}</div><div style="font-size:19px;color:${SEC}">${t('Profiel toevoegen', 'Add profile')}</div></div></div>
      <div style="position:absolute;bottom:${mac ? 40 : 110}px;left:0;right:0;display:flex;justify-content:center">${btn('d', 'pencil', t('Profielen beheren', 'Manage profiles'), 17, '14px 26px', 'border-radius:99px;font-weight:600')}</div></div>`;
  },
  stats(o) {
    const { w, h, mac } = o; const top = mac ? 18 : 92;
    const colW = (w - 48 - 28) / 2;
    return `<div class="app" style="width:${w}px;height:${h}px;background:#000">${mac ? '' : ipadStatus()}
      <div style="position:absolute;top:${top}px;left:20px;right:24px;display:flex;align-items:center;justify-content:space-between"><div style="display:flex;align-items:center;gap:2px;color:${RED};font-size:17px">${I('chevL', 22, RED)}${t('Mijn Bingr', 'My Bingr')}</div></div>
      <div style="position:absolute;top:${top + 36}px;left:24px;right:24px;display:flex;justify-content:space-between;align-items:center"><div style="font-size:34px;font-weight:800">${t('Statistieken', 'Statistics')}</div>${seg(['Week', t('Maand', 'Month'), t('Jaar', 'Year')], 1, 14, 'width:300px')}</div>
      <div style="position:absolute;top:${top + 96}px;left:24px;right:24px;display:flex;justify-content:space-between;align-items:center"><div style="display:flex;gap:8px">${[t('Alle profielen', 'All profiles'), 'Sanne', 'Daan', 'Noor', 'Mees'].map((x, i) => pill(x, i === 0, 14)).join('')}</div><div style="display:flex;align-items:center;gap:16px">${I('chevL', 20, RED)}<div style="font-size:18px;font-weight:700">${t('september 2026', 'September 2026')}</div>${I('chevR', 20, RED)}</div></div>
      <div style="position:absolute;top:${top + 148}px;left:24px;right:24px">${statTiles(1.05, 4)}</div>
      <div style="position:absolute;top:${top + 278}px;left:24px;width:${colW}px">${statChart(colW, mac ? 150 : 260, 1)}
        ${mac ? '' : `<div style="margin-top:26px">${topList(t('Topzenders', 'Top channels'), [], 1)}${[CHANNELS[1], CHANNELS[0], CHANNELS[3]].map((c, i) => `<div style="display:flex;align-items:center;gap:12px;padding:9px 0;${i ? 'border-top:1px solid #ffffff14' : ''}"><div style="width:18px;color:${SEC};font-weight:700;text-align:center">${i + 1}</div><div style="width:84px;height:46px;border-radius:6px;background:${CARD};display:grid;place-items:center">${chMark(c, 26)}</div><div style="flex:1"><div style="font-size:15px;font-weight:600">${c.n}</div><div style="font-size:12px;color:${SEC}">${['3 u 10 min', '2 u 5 min', '1 u 20 min'][i].replace('u', t('u', 'h'))}</div></div></div>`).join('')}</div>`}</div>
      <div style="position:absolute;top:${top + 278}px;right:24px;width:${colW}px">${topList(t('Topseries', 'Top series'), [['noordlicht', 9, 4, 30], ['polder', 6, 5, 10], ['archief', 5, 3, 55], ['ekster', 3, 2, 40]], 1, mac ? 2 : 4)}
        <div style="height:22px"></div>${topList(t('Topfilms', 'Top movies'), [['stationzero', 0, 2, 11], ['haven', 0, 1, 52], ['nachtrit', 0, 1, 38]], 1, mac ? 1 : 3)}</div></div>`;
  },
};

// ================= Apple TV (1920 × 1080) =================
function tvTabs(sel) {
  const items = [t('Home', 'Home'), 'Live TV', t('Films', 'Movies'), 'Series', t('Categorieën', 'Categories'), t('Zoeken', 'Search')];
  return `<div style="position:absolute;top:40px;left:0;right:0;display:flex;justify-content:center;gap:10px;font-size:29px;font-weight:600;z-index:10">${items.map((x, i) => `<span style="padding:10px 26px;border-radius:999px;${i === sel ? 'background:#fff;color:#000' : 'color:#ccc'}">${x}</span>`).join('')}<span style="padding:6px 16px 6px 20px;display:flex;align-items:center;gap:12px;color:#ccc">${avatar(PROFILES[0], 44, '9px')}Sanne</span></div>`;
}
const TV = {
  home() {
    const id = 'haven';
    return `<div class="app" style="width:1920px;height:1080px;background:#000">
      <div style="position:absolute;inset:0 0 auto 0;height:820px;${bg(posterURL(id, LANG))};filter:blur(30px);opacity:.7;transform:scale(1.1)"></div>
      <div style="position:absolute;right:120px;top:0;width:520px;height:780px;${bg(sceneURL(id, 520, 780))};-webkit-mask:linear-gradient(90deg,#0000,#000 40%)"></div>
      <div style="position:absolute;inset:0 0 auto 0;height:820px;background:linear-gradient(90deg,#000000f2,#0006 55%,#0000),linear-gradient(#0000 55%,#000)"></div>
      ${tvTabs(0)}
      <div style="position:absolute;left:80px;top:250px;width:1000px">
        <div style="font-family:${FONT.serif};font-size:92px;font-weight:700;line-height:1">${TN(id)}</div>
        <div style="display:flex;gap:18px;align-items:center;margin:24px 0;font-size:26px;color:${SEC}">${imdb(TBY[id].rating, 26).replace('font-weight:600', 'font-weight:600;color:#fff')}<span>${tags(id)}</span></div>
        <p style="font-size:26px;max-width:900px;line-height:1.38;color:#ffffffe6">${LANG === 'en' ? TBY[id].de : TBY[id].d}</p>
        <div style="display:flex;gap:24px;margin-top:32px">${btn('w', 'play', t('Afspelen', 'Play'), 30, '19px 44px', 'transform:scale(1.08);transform-origin:0 50%;box-shadow:0 12px 30px #0009;margin-right:12px')}${btn('g', 'info', t('Meer info', 'More info'), 30, '19px 40px')}</div></div>
      <div style="position:absolute;left:0;right:0;top:770px">
        <div style="font-size:38px;font-weight:700;margin-left:80px">${t('Verder kijken', 'Continue watching')}</div>
        <div style="display:flex;gap:40px;padding:24px 80px">${CONT.map((c, i) => `<div style="flex:none;width:400px"><div style="position:relative;width:400px;height:225px;border-radius:10px;overflow:hidden;${bg(sceneURL(c[0], 400, 225, 2))}"><div style="position:absolute;inset:0;background:linear-gradient(#0000 55%,#000b)"></div><div style="position:absolute;left:16px;bottom:16px;font-size:24px;font-weight:700">${TN(c[0])}</div><div style="position:absolute;left:0;right:0;bottom:0;height:6px;background:#ffffff4d"><div style="height:100%;width:${c[1]}%;background:${RED}"></div></div></div></div>`).join('')}</div></div></div>`;
  },
  detail() {
    const id = 'noordlicht', x = TBY[id];
    return `<div class="app" style="width:1920px;height:1080px;background:#000">
      <div style="position:absolute;inset:0 0 auto 0;height:700px;${bg(sceneURL(id, 1920, 700, 1))}"></div>
      <div style="position:absolute;inset:0 0 auto 0;height:702px;background:linear-gradient(90deg,#000000e6,#0000 70%),linear-gradient(#0000 40%,#000)"></div>
      <div style="position:absolute;left:120px;top:110px;display:flex;gap:56px;align-items:flex-end">${poster(id, 260, { r: 10, s: 2 })}
        <div style="padding-bottom:8px">${titleLogo(id, LANG, 80, 'left')}
          <div style="display:flex;gap:22px;align-items:center;font-size:26px;color:#ddd;margin:22px 0 30px">${imdb(x.rating, 26)}<span>${x.year}</span>${ageBox(x.age, 24)}<span>${t('2 seizoenen', '2 seasons')}</span><span style="color:${SEC}">${(LANG === 'en' ? x.ge : x.g).join(' • ')}</span></div>
          <div style="display:flex;gap:28px">${btn('w', 'play', t('Afspelen S1:A4', 'Play S1:E4'), 29, '18px 40px', 'transform:scale(1.08);transform-origin:0 50%;margin-right:14px;box-shadow:0 12px 30px #0009')}${btn('g', 'clapper', 'Trailer', 29, '18px 36px')}${btn('g', 'check', t('Mijn lijst', 'My List'), 29, '18px 34px')}${btn('g', 'stack3d', t('Andere bronnen', 'Other sources'), 29, '18px 34px')}</div></div></div>
      <div style="position:absolute;left:120px;right:120px;top:600px">
        <div style="display:flex;justify-content:space-between;align-items:center"><b style="font-size:38px">${t('Afleveringen', 'Episodes')}</b><span style="background:${EL};padding:12px 26px;border-radius:10px;font-size:26px;font-weight:600;display:flex;gap:10px;align-items:center">${t('Seizoen 1', 'Season 1')}${I('chevD', 22)}</span></div>
        <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:30px 44px;margin-top:28px">${EPS.slice(0, 6).map((e, i) => `<div style="display:flex;align-items:center;gap:22px;${i === 3 ? 'transform:scale(1.05);transform-origin:0 50%;' : ''}">
          <div style="width:236px;height:133px;border-radius:10px;flex:none;position:relative;${bg(sceneURL(id, 236, 133, 20 + i))};${i === 3 ? 'box-shadow:0 0 0 5px #fff,0 18px 30px #000' : ''}">${e[5] > 0 && e[5] < 1 ? `<div style="position:absolute;left:0;right:0;bottom:0;height:7px;background:#ffffff4d"><div style="height:100%;width:${e[5] * 100}%;background:${RED}"></div></div>` : ''}</div>
          <div style="flex:1;min-width:0"><div style="font-weight:600;font-size:27px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${i + 1}. ${LANG === 'en' ? e[1] : e[0]}</div><div style="font-size:21px;color:${SEC};margin-top:4px">${e[4]} min</div></div>
          ${e[5] === 1 ? `<div style="width:42px;height:42px;border-radius:50%;background:${RED};display:grid;place-items:center;flex:none">${I('check', 24, '#fff')}</div>` : `<div style="width:42px;height:42px;border-radius:50%;border:3px solid #777;flex:none"></div>`}</div>`).join('')}</div></div></div>`;
  },
  guide() {
    return `<div class="app" style="width:1920px;height:1080px;background:#000">${tvTabs(1)}
      <div style="position:absolute;top:130px;left:80px;right:80px;height:250px;display:flex;gap:40px;align-items:center">
        <div style="width:444px;height:250px;border-radius:14px;overflow:hidden;position:relative;flex:none;background:#0b1a10">${stadium(444, 250)}<div style="position:absolute;top:14px;left:14px;display:flex;align-items:center;gap:6px;background:#0009;border-radius:99px;padding:5px 12px;font-size:16px;font-weight:900"><i style="width:9px;height:9px;border-radius:50%;background:${RED}"></i>LIVE</div></div>
        <div>${chLogo(CHANNELS[1], 26).replace('justify-content:center', 'justify-content:flex-start')}<div style="font-size:52px;font-weight:800;margin:14px 0 8px">${t('Voetbal: halve finale', 'Football: semi-final')}</div><div style="font-size:24px;color:${SEC}">20:00 – 22:00 · ${t('Straks: Sportcafé', 'Next: Sports Café')}</div><div style="width:620px;height:6px;border-radius:3px;background:#ffffff33;margin-top:18px"><div style="height:100%;width:41%;background:${RED};border-radius:3px"></div></div></div></div>
      <div style="position:absolute;top:410px;left:80px;right:0">${epg({ s: 1.75, colW: 300, slot: 270, rowH: 104, rows: 6, nowAt: 1.5, focus: [2, 1] })}</div></div>`;
  },
  categories() {
    const tw = (1920 - 160 - 40 * 3) / 4;
    return `<div class="app" style="width:1920px;height:1080px;background:#000">${tvTabs(4)}
      <div style="position:absolute;top:150px;left:80px;right:80px">
        <div style="display:flex;justify-content:space-between;align-items:center"><div style="font-size:53px;font-weight:900">${t('Categorieën', 'Categories')}</div>${seg([t('Alles', 'All'), t('Films', 'Movies'), 'Series'], 0, 26, 'width:560px')}</div>
        <div style="font-size:38px;font-weight:700;margin:30px 0 22px">${t('Genres', 'Genres')}</div>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:40px">${GENRES.slice(0, 8).map((c, i) => catTile(c, tw, 1.9, i === 1)).join('')}</div>
        <div style="font-size:38px;font-weight:700;margin:40px 0 22px">${t('Van je server', 'From your server')}</div>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:40px">${SERVER.map(c => catTile(c, tw, 1.9)).join('')}</div></div></div>`;
  },
  profiles() {
    return `<div class="app" style="width:1920px;height:1080px;background:#000">
      <div style="position:absolute;top:56px;left:80px">${logo(50)}</div>
      <div style="position:absolute;top:250px;left:0;right:0;text-align:center;font-size:56px;font-weight:600">${t('Wie kijkt er?', 'Who’s watching?')}</div>
      <div style="position:absolute;top:400px;left:0;right:0;display:flex;justify-content:center;gap:70px;align-items:flex-start">
        ${PROFILES.map((p, i) => { const f = i === 2; return `<div style="display:flex;flex-direction:column;align-items:center;gap:18px;${f ? 'transform:scale(1.12);filter:drop-shadow(0 20px 30px #000)' : 'opacity:.85'}"><div style="border-radius:50%;${f ? 'box-shadow:0 0 0 7px #fff' : ''}">${avatar(p, 230, '50%')}</div><div style="font-size:31px;${f ? 'font-weight:700;color:#fff' : `color:${SEC}`};display:flex;gap:10px;align-items:center">${LANG === 'en' ? p.nameEn : p.name}${p.age != null ? I('lock', 22, SEC) : ''}</div></div>`; }).join('')}</div>
      <div style="position:absolute;bottom:70px;left:0;right:0;text-align:center;color:#b3b3b3bb;font-size:24px;display:flex;justify-content:center;align-items:center;gap:10px">${I('sync', 24, '#b3b3b3bb')}${t('Profielen en voortgang gesynchroniseerd met je iPhone', 'Profiles and progress synced with your iPhone')}</div></div>`;
  },
  login() {
    return `<div class="app" style="width:1920px;height:1080px;background:radial-gradient(circle at 30% 40%,#2a0507,#000 60%)">
      <div style="position:absolute;top:60px;left:100px">${logo(48)}</div>
      <div style="position:absolute;top:140px;left:100px;right:100px;bottom:60px;display:flex;align-items:center;gap:70px">
        <div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:22px">
          <div style="font-size:44px;font-weight:700">${t('Inloggen met je telefoon', 'Sign in with your phone')}</div>
          <div style="font-size:26px;color:${SEC}">${t('Scan de QR-code met de camera van je telefoon', 'Scan the QR code with your phone’s camera')}</div>
          <div style="width:300px;height:300px;background:#fff;border-radius:16px;padding:18px">${fakeQR(29, 11)}</div>
          <div style="font-size:26px;color:${SEC};text-align:center">${t('Of ga naar', 'Or go to')} <b style="color:#fff">bingr.online/koppelen</b> ${t('en voer deze code in:', 'and enter this code:')}</div>
          <div style="font-family:Menlo,'DejaVu Sans Mono',monospace;font-size:64px;font-weight:800;letter-spacing:8px;background:#232323d9;padding:8px 30px;border-radius:12px">K7Q-4ZM</div>
          <div style="display:flex;align-items:center;gap:14px;font-size:24px;color:${SEC}"><div style="width:26px;height:26px;border-radius:50%;border:3px solid ${RED};border-right-color:transparent"></div>${t('Wachten op bevestiging…', 'Waiting for confirmation…')}</div></div>
        <div style="display:flex;flex-direction:column;align-items:center;gap:24px"><div style="width:2px;height:230px;background:#ffffff40"></div><div style="font-size:30px;font-weight:700;color:${SEC}">${t('OF', 'OR')}</div><div style="width:2px;height:230px;background:#ffffff40"></div></div>
        <div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:30px">${I('envelope', 76, SEC)}<div style="width:520px;padding:24px 0;border-radius:12px;background:${RED};font-size:30px;font-weight:700;text-align:center">${t('Inloggen met e-mail', 'Sign in with email')}</div></div></div></div>`;
  },
};
