// Bingr App Store-materiaal: procedurele, volledig fictieve key art (posters, achtergronden, stills),
// fictieve zenders en programma's. Geen echte titels, logo's of merken.
'use strict';

const FONT = {
  display: "'Inter Display','SF Pro Display','Helvetica Neue',Arial,sans-serif",
  text: "Inter,'SF Pro Text','Helvetica Neue',Arial,sans-serif",
  serif: "Lora,'New York',Georgia,serif",
  bonum: "'TeX Gyre Bonum',Bookman,Georgia,serif",
  adv: "'TeX Gyre Adventor','Avenir Next','Century Gothic',sans-serif",
  pop: "Poppins,'Avenir Next',sans-serif",
  bask: "'GFS Baskerville',Baskerville,Georgia,serif",
};

// ---------- hulpjes ----------
function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const f1 = n => Math.round(n * 10) / 10;
function lg(id, stops, x2 = 0, y2 = 1, x1 = 0, y1 = 0) {
  return `<linearGradient id="${id}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}">${stops.map(s => `<stop offset="${s[0]}" stop-color="${s[1]}" stop-opacity="${s[2] ?? 1}"/>`).join('')}</linearGradient>`;
}
function rg(id, stops, cx = .5, cy = .5, r = .5) {
  return `<radialGradient id="${id}" cx="${cx}" cy="${cy}" r="${r}">${stops.map(s => `<stop offset="${s[0]}" stop-color="${s[1]}" stop-opacity="${s[2] ?? 1}"/>`).join('')}</radialGradient>`;
}
const blur = (id, s) => `<filter id="${id}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="${s}"/></filter>`;
// heuvelrug: polygon over de hele breedte
function ridge(w, h, y, amp, r, fill, steps = 14, rough = .5) {
  let pts = [], ph = r() * 6;
  for (let i = 0; i <= steps; i++) {
    const x = w * i / steps;
    const yy = y + Math.sin(i * .9 + ph) * amp * .6 + (r() - .5) * amp * rough * 2;
    pts.push(`${f1(x)},${f1(yy)}`);
  }
  return `<polygon points="0,${h} ${pts.join(' ')} ${w},${h}" fill="${fill}"/>`;
}
function peaks(w, h, y, amp, r, fill, n = 7) {
  let pts = [`0,${f1(y)}`];
  for (let i = 0; i < n; i++) {
    const x0 = w * (i + .5) / n + (r() - .5) * w / n * .5;
    pts.push(`${f1(x0)},${f1(y - amp * (.4 + r() * .6))}`);
    pts.push(`${f1(w * (i + 1) / n)},${f1(y + (r() - .3) * amp * .3)}`);
  }
  return `<polygon points="0,${h} ${pts.join(' ')} ${w},${h}" fill="${fill}"/>`;
}
function stars(w, h, n, r, maxY = .6, op = .9) {
  let s = '';
  for (let i = 0; i < n; i++) s += `<circle cx="${f1(r() * w)}" cy="${f1(r() * h * maxY)}" r="${f1((r() ** 3) * w * .003 + w * .0007)}" fill="#fff" opacity="${f1(op * (.3 + r() * .7))}"/>`;
  return s;
}
function pine(x, y, s, fill) { // kerstboomvormige den
  return `<polygon points="${f1(x)},${f1(y - s)} ${f1(x - s * .22)},${f1(y - s * .55)} ${f1(x - s * .12)},${f1(y - s * .56)} ${f1(x - s * .32)},${f1(y - s * .2)} ${f1(x - s * .14)},${f1(y - s * .22)} ${f1(x - s * .4)},${f1(y)} ${f1(x + s * .4)},${f1(y)} ${f1(x + s * .14)},${f1(y - s * .22)} ${f1(x + s * .32)},${f1(y - s * .2)} ${f1(x + s * .12)},${f1(y - s * .56)} ${f1(x + s * .22)},${f1(y - s * .55)}" fill="${fill}"/>`;
}
function figure(x, y, s, fill) { // staande silhouet, voeten op (x,y), hoogte s
  return `<g fill="${fill}"><circle cx="${f1(x)}" cy="${f1(y - s * .9)}" r="${f1(s * .075)}"/><path d="M${f1(x - s * .13)},${f1(y - s * .78)} Q${f1(x)},${f1(y - s * .84)} ${f1(x + s * .13)},${f1(y - s * .78)} L${f1(x + s * .16)},${f1(y - s * .4)} L${f1(x + s * .08)},${f1(y - s * .4)} L${f1(x + s * .07)},${f1(y)} L${f1(x + s * .01)},${f1(y)} L${f1(x)},${f1(y - s * .38)} L${f1(x - s * .01)},${f1(y)} L${f1(x - s * .07)},${f1(y)} L${f1(x - s * .08)},${f1(y - s * .4)} L${f1(x - s * .16)},${f1(y - s * .4)} Z"/></g>`;
}
function coatFigure(x, y, s, fill) { // figuur met lange jas en hoed
  return `<g fill="${fill}"><ellipse cx="${f1(x)}" cy="${f1(y - s * .93)}" rx="${f1(s * .15)}" ry="${f1(s * .022)}"/><rect x="${f1(x - s * .07)}" y="${f1(y - s * 1.02)}" width="${f1(s * .14)}" height="${f1(s * .09)}" rx="${f1(s * .02)}"/><circle cx="${f1(x)}" cy="${f1(y - s * .87)}" r="${f1(s * .065)}"/><path d="M${f1(x - s * .14)},${f1(y - s * .78)} Q${f1(x)},${f1(y - s * .83)} ${f1(x + s * .14)},${f1(y - s * .78)} L${f1(x + s * .22)},${f1(y - s * .08)} L${f1(x + s * .07)},${f1(y - s * .08)} L${f1(x + s * .06)},${f1(y)} L${f1(x + s * .01)},${f1(y)} L${f1(x)},${f1(y - s * .1)} L${f1(x - s * .01)},${f1(y)} L${f1(x - s * .06)},${f1(y)} L${f1(x - s * .07)},${f1(y - s * .08)} L${f1(x - s * .22)},${f1(y - s * .08)} Z"/></g>`;
}

// ---------- scènes (w, h, r) → svg-inhoud ----------
const SCENES = {
  aurora(w, h, r) {
    const hz = h * .7;
    let a = '';
    for (let k = 0; k < 3; k++) {
      const y0 = h * (.18 + k * .1), amp = h * .08, th = h * (.12 + k * .04);
      let top = [], bot = [];
      for (let i = 0; i <= 10; i++) { const x = w * i / 10; const yy = y0 + Math.sin(i * .8 + k * 2 + r() * .5) * amp; top.push(`${f1(x)},${f1(yy)}`); bot.unshift(`${f1(x)},${f1(yy + th * (.6 + .4 * Math.sin(i * 1.3 + k)))}`); }
      a += `<polygon points="${top.join(' ')} ${bot.join(' ')}" fill="url(#au${k})" filter="url(#b1)" opacity="${[.9, .7, .55][k]}"/>`;
    }
    return `<defs>${lg('sky', [[0, '#01060f'], [.55, '#04192a'], [1, '#0c3a4a']])}${lg('au0', [[0, '#3cffb0', 0], [.5, '#3cffb0', .85], [1, '#0aa2a0', 0]])}${lg('au1', [[0, '#7cf7ff', 0], [.5, '#4adfff', .7], [1, '#7b5cff', 0]])}${lg('au2', [[0, '#b388ff', 0], [.5, '#c77dff', .6], [1, '#3cffb0', 0]])}${blur('b1', w * .012)}${lg('lake', [[0, '#0a2e3a'], [1, '#010508']])}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>${stars(w, h, 140, r, .65)}${a}
      ${peaks(w, h, hz, h * .22, r, '#06202b', 6)}${peaks(w, h, hz + h * .03, h * .12, r, '#03121a', 9)}
      <rect y="${f1(hz + h * .06)}" width="${w}" height="${f1(h - hz)}" fill="url(#lake)"/>
      <rect x="${f1(w * .62)}" y="${f1(hz + h * .035)}" width="${f1(w * .03)}" height="${f1(w * .018)}" fill="#02080c"/><polygon points="${f1(w * .615)},${f1(hz + h * .035)} ${f1(w * .635)},${f1(hz + h * .035 - w * .014)} ${f1(w * .655)},${f1(hz + h * .035)}" fill="#02080c"/>
      <rect x="${f1(w * .628)}" y="${f1(hz + h * .04)}" width="${f1(w * .006)}" height="${f1(w * .006)}" fill="#ffcc66"/><circle cx="${f1(w * .631)}" cy="${f1(hz + h * .043)}" r="${f1(w * .03)}" fill="#ffcc66" opacity=".12"/>
      <rect y="${f1(hz + h * .065)}" width="${w}" height="${f1(h * .006)}" fill="#3cffb0" opacity=".18" filter="url(#b1)"/>`;
  },
  harbor(w, h, r) {
    const hz = h * .64;
    let cr = '';
    [[.12, .5], [.24, .62], [.82, .55]].forEach(([x, s], i) => {
      const X = w * x, H = h * .32 * s * 1.6, top = hz - H;
      cr += `<rect x="${f1(X - w * .006)}" y="${f1(top)}" width="${f1(w * .012)}" height="${f1(H)}" fill="#14060f"/>
        <rect x="${f1(X - w * .09 * s)}" y="${f1(top)}" width="${f1(w * .24 * s)}" height="${f1(h * .012)}" fill="#14060f"/>
        <line x1="${f1(X)}" y1="${f1(top - h * .05 * s)}" x2="${f1(X + w * .15 * s)}" y2="${f1(top)}" stroke="#14060f" stroke-width="${f1(w * .002)}"/>
        <line x1="${f1(X)}" y1="${f1(top - h * .05 * s)}" x2="${f1(X - w * .09 * s)}" y2="${f1(top)}" stroke="#14060f" stroke-width="${f1(w * .002)}"/>
        <rect x="${f1(X - w * .003)}" y="${f1(top - h * .05 * s)}" width="${f1(w * .006)}" height="${f1(h * .05 * s)}" fill="#14060f"/>
        <line x1="${f1(X + w * .1 * s)}" y1="${f1(top)}" x2="${f1(X + w * .1 * s)}" y2="${f1(top + H * .45)}" stroke="#14060f" stroke-width="${f1(w * .0015)}"/>`;
    });
    let refl = '';
    for (let i = 0; i < 26; i++) { const y = hz + (h - hz) * (i / 26) ** 1.4 + 2; const ww = w * (.04 + .22 * (1 - i / 26) * r()); refl += `<rect x="${f1(w * .62 - ww / 2 + (r() - .5) * w * .05)}" y="${f1(y)}" width="${f1(ww)}" height="${f1(h * .004 + i * .25)}" fill="#ffc06a" opacity="${f1(.55 * (1 - i / 30))}"/>`; }
    return `<defs>${lg('sky', [[0, '#1a0b24'], [.35, '#4a1031'], [.7, '#c2410c'], [1, '#ffb259']])}${rg('sun', [[0, '#fff1c1'], [.25, '#ffd27a'], [.6, '#ff8a3c', .35], [1, '#ff8a3c', 0]])}${lg('sea', [[0, '#3a1224'], [1, '#07030a']])}</defs>
      <rect width="${w}" height="${f1(hz)}" fill="url(#sky)"/><circle cx="${f1(w * .62)}" cy="${f1(hz - h * .06)}" r="${f1(Math.min(w, h) * .32)}" fill="url(#sun)"/>
      <circle cx="${f1(w * .62)}" cy="${f1(hz - h * .06)}" r="${f1(Math.min(w, h) * .07)}" fill="#ffe3a3"/>
      <rect y="${f1(hz)}" width="${w}" height="${f1(h - hz)}" fill="url(#sea)"/>${refl}
      <path d="M${f1(w * .3)},${f1(hz)} L${f1(w * .33)},${f1(hz - h * .045)} L${f1(w * .52)},${f1(hz - h * .045)} L${f1(w * .54)},${f1(hz - h * .07)} L${f1(w * .58)},${f1(hz - h * .07)} L${f1(w * .58)},${f1(hz - h * .045)} L${f1(w * .6)},${f1(hz - h * .045)} L${f1(w * .57)},${f1(hz)} Z" fill="#14060f"/>
      ${cr}<rect y="${f1(hz - h * .006)}" width="${w}" height="${f1(h * .008)}" fill="#14060f"/>`;
  },
  nightride(w, h, r) {
    const hz = h * .56, vx = w * .5;
    let city = '', x = 0;
    while (x < w) { const bw = w * (.03 + r() * .05), bh = h * (.05 + r() * .16) * (1 - Math.abs(x - vx) / w * .8); city += `<rect x="${f1(x)}" y="${f1(hz - bh)}" width="${f1(bw + 1)}" height="${f1(bh)}" fill="#12002a"/>`; for (let k = 0; k < 4; k++) if (r() < .6) city += `<rect x="${f1(x + r() * bw * .8)}" y="${f1(hz - bh + r() * bh * .8)}" width="${f1(w * .004)}" height="${f1(w * .004)}" fill="${r() < .5 ? '#ff4fd8' : '#4de8ff'}" opacity=".8"/>`; x += bw; }
    let lines = '';
    for (let i = 1; i < 14; i++) { const y = hz + (h - hz) * (i / 14) ** 2; lines += `<line x1="0" y1="${f1(y)}" x2="${w}" y2="${f1(y)}" stroke="#ff2e93" stroke-opacity="${f1(.15 + i / 30)}" stroke-width="${f1(1 + i * .2)}"/>`; }
    for (let i = -8; i <= 8; i++) lines += `<line x1="${f1(vx)}" y1="${f1(hz)}" x2="${f1(vx + i * w * .16)}" y2="${h}" stroke="#ff2e93" stroke-opacity=".35" stroke-width="1.2"/>`;
    return `<defs>${lg('sky', [[0, '#05000f'], [.6, '#2a0a4a'], [1, '#ff2e93']])}${lg('gr', [[0, '#1a0233'], [1, '#05000f']])}${rg('glow', [[0, '#ff5fb8', .9], [1, '#ff2e93', 0]])}${blur('b1', w * .006)}${lg('road', [[0, '#1b1030'], [1, '#05000a']])}</defs>
      <rect width="${w}" height="${f1(hz)}" fill="url(#sky)"/>${stars(w, h, 60, r, .35, .6)}
      <circle cx="${f1(vx)}" cy="${f1(hz - h * .02)}" r="${f1(h * .22)}" fill="url(#glow)" opacity=".6"/>
      <circle cx="${f1(vx)}" cy="${f1(hz - h * .1)}" r="${f1(h * .12)}" fill="#ffb3e0" opacity=".9"/>
      ${[0, 1, 2, 3].map(i => `<rect x="${f1(vx - h * .13)}" y="${f1(hz - h * .1 + i * h * .025)}" width="${f1(h * .26)}" height="${f1(h * (.004 + i * .003))}" fill="#2a0a4a"/>`).join('')}
      ${city}<rect y="${f1(hz)}" width="${w}" height="${f1(h - hz)}" fill="url(#gr)"/>${lines}
      <polygon points="${f1(vx - w * .01)},${f1(hz)} ${f1(vx + w * .01)},${f1(hz)} ${f1(vx + w * .35)},${h} ${f1(vx - w * .35)},${h}" fill="url(#road)"/>
      <polygon points="${f1(vx - w * .01)},${f1(hz)} ${f1(vx - w * .006)},${f1(hz)} ${f1(vx - w * .33)},${h} ${f1(vx - w * .35)},${h}" fill="#4de8ff" opacity=".9"/>
      <polygon points="${f1(vx + w * .006)},${f1(hz)} ${f1(vx + w * .01)},${f1(hz)} ${f1(vx + w * .35)},${h} ${f1(vx + w * .33)},${h}" fill="#4de8ff" opacity=".9"/>
      ${[0, 1, 2, 3, 4].map(i => { const t1 = (i * .2 + .05) ** 2, t2 = (i * .2 + .13) ** 2; return `<polygon points="${f1(vx - w * .002 - t1 * w * .012)},${f1(hz + (h - hz) * t1)} ${f1(vx + w * .002 + t1 * w * .012)},${f1(hz + (h - hz) * t1)} ${f1(vx + w * .002 + t2 * w * .012)},${f1(hz + (h - hz) * t2)} ${f1(vx - w * .002 - t2 * w * .012)},${f1(hz + (h - hz) * t2)}" fill="#ffe7f6" opacity=".8"/>`; }).join('')}
      <g transform="translate(${f1(vx)},${f1(hz + (h - hz) * .5)})"><path d="M${f1(-w * .07)},0 L${f1(-w * .055)},${f1(-h * .05)} L${f1(w * .055)},${f1(-h * .05)} L${f1(w * .07)},0 L${f1(w * .07)},${f1(h * .03)} L${f1(-w * .07)},${f1(h * .03)} Z" fill="#07000f"/>
      <rect x="${f1(-w * .065)}" y="${f1(-h * .006)}" width="${f1(w * .03)}" height="${f1(h * .012)}" fill="#ff1f3d" filter="url(#b1)"/><rect x="${f1(w * .035)}" y="${f1(-h * .006)}" width="${f1(w * .03)}" height="${f1(h * .012)}" fill="#ff1f3d" filter="url(#b1)"/>
      <rect x="${f1(-w * .065)}" y="${f1(-h * .004)}" width="${f1(w * .03)}" height="${f1(h * .008)}" fill="#ff8a9a"/><rect x="${f1(w * .035)}" y="${f1(-h * .004)}" width="${f1(w * .03)}" height="${f1(h * .008)}" fill="#ff8a9a"/></g>`;
  },
  polder(w, h, r) {
    const hz = h * .7, mx = w * .3;
    const sail = a => `<g transform="translate(${f1(mx)},${f1(hz - h * .3)}) rotate(${a})"><rect x="${f1(-w * .006)}" y="${f1(-h * .2)}" width="${f1(w * .012)}" height="${f1(h * .2)}" fill="#0a0d12"/><rect x="${f1(w * .006)}" y="${f1(-h * .19)}" width="${f1(w * .03)}" height="${f1(h * .16)}" fill="none" stroke="#0a0d12" stroke-width="${f1(w * .003)}"/>${[1, 2, 3, 4].map(k => `<line x1="${f1(w * .006)}" y1="${f1(-h * .19 + k * h * .032)}" x2="${f1(w * .036)}" y2="${f1(-h * .19 + k * h * .032)}" stroke="#0a0d12" stroke-width="${f1(w * .0015)}"/>`).join('')}</g>`;
    let ditch = '';
    for (let i = -5; i <= 5; i++) ditch += `<line x1="${f1(w * .55 + i * w * .02)}" y1="${f1(hz)}" x2="${f1(w * .55 + i * w * .35)}" y2="${h}" stroke="#b9c6d3" stroke-opacity="${f1(.08 + (5 - Math.abs(i)) * .02)}" stroke-width="${f1(w * .003)}"/>`;
    return `<defs>${lg('sky', [[0, '#141b24'], [.6, '#3d4a57'], [1, '#56616c']])}${rg('moon', [[0, '#e5484d'], [.7, '#b4232a'], [1, '#7a1219']])}${rg('mg', [[0, '#e5484d', .5], [1, '#e5484d', 0]])}${blur('b1', h * .02)}${lg('land', [[0, '#1b222b'], [1, '#07090c']])}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/><circle cx="${f1(w * .68)}" cy="${f1(h * .38)}" r="${f1(Math.min(w, h) * .4)}" fill="url(#mg)"/>
      <circle cx="${f1(w * .68)}" cy="${f1(h * .38)}" r="${f1(Math.min(w, h) * .17)}" fill="url(#moon)"/>
      ${[.3, .45, .52].map((y, i) => `<rect x="${f1(-w * .1)}" y="${f1(h * y)}" width="${f1(w * 1.2)}" height="${f1(h * .03)}" rx="${f1(h * .015)}" fill="#cfd8e3" opacity="${[.08, .12, .1][i]}" filter="url(#b1)"/>`).join('')}
      <rect y="${f1(hz)}" width="${w}" height="${f1(h - hz)}" fill="url(#land)"/>${ditch}
      <polygon points="${f1(mx - w * .035)},${f1(hz)} ${f1(mx - w * .022)},${f1(hz - h * .29)} ${f1(mx + w * .022)},${f1(hz - h * .29)} ${f1(mx + w * .035)},${f1(hz)}" fill="#0a0d12"/>
      <path d="M${f1(mx - w * .026)},${f1(hz - h * .29)} Q${f1(mx)},${f1(hz - h * .345)} ${f1(mx + w * .026)},${f1(hz - h * .29)} Z" fill="#0a0d12"/>
      ${sail(20)}${sail(110)}${sail(200)}${sail(290)}
      <rect x="${f1(mx - w * .006)}" y="${f1(hz - h * .06)}" width="${f1(w * .012)}" height="${f1(h * .03)}" fill="#ffcf7a" opacity=".8"/>
      <rect x="${f1(-w * .1)}" y="${f1(hz - h * .03)}" width="${f1(w * 1.2)}" height="${f1(h * .06)}" fill="#cfd8e3" opacity=".08" filter="url(#b1)"/>`;
  },
  city(w, h, r) {
    const hz = h * .78;
    let b = '', x = -w * .02;
    while (x < w) {
      const bw = w * (.05 + r() * .07), bh = h * (.15 + r() * .45);
      b += `<rect x="${f1(x)}" y="${f1(hz - bh)}" width="${f1(bw)}" height="${f1(bh + 2)}" fill="${r() < .5 ? '#0a1428' : '#0c1730'}"/>`;
      for (let yy = hz - bh + h * .02; yy < hz - h * .02; yy += h * .025) for (let xx = x + bw * .12; xx < x + bw * .85; xx += bw * .18) if (r() < .22) b += `<rect x="${f1(xx)}" y="${f1(yy)}" width="${f1(bw * .08)}" height="${f1(h * .01)}" fill="${r() < .8 ? '#ffd98a' : '#9fd3ff'}" opacity="${f1(.5 + r() * .5)}"/>`;
      x += bw + w * .004;
    }
    const lx = w * .7;
    return `<defs>${lg('sky', [[0, '#081428'], [.55, '#1f3d6b'], [.85, '#5a6fa0'], [1, '#f2a65a']])}${lg('cone', [[0, '#ffe2a8', .55], [1, '#ffe2a8', 0]])}${blur('b1', w * .01)}${lg('st', [[0, '#0b1222'], [1, '#03060c']])}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>${stars(w, h, 30, r, .3, .5)}${b}
      <rect y="${f1(hz)}" width="${w}" height="${f1(h - hz)}" fill="url(#st)"/>
      <polygon points="${f1(lx)},${f1(hz - h * .3)} ${f1(lx - w * .12)},${f1(h)} ${f1(lx + w * .12)},${f1(h)}" fill="url(#cone)" filter="url(#b1)"/>
      <rect x="${f1(lx - w * .003)}" y="${f1(hz - h * .3)}" width="${f1(w * .006)}" height="${f1(h * .3 + h * .1)}" fill="#02050b"/><path d="M${f1(lx)},${f1(hz - h * .3)} q${f1(w * .03)},${f1(-h * .02)} ${f1(w * .035)},${f1(h * .01)}" stroke="#02050b" stroke-width="${f1(w * .005)}" fill="none"/>
      <circle cx="${f1(lx + w * .035)}" cy="${f1(hz - h * .285)}" r="${f1(w * .008)}" fill="#fff1c9"/>
      <ellipse cx="${f1(lx + w * .02)}" cy="${f1(hz + h * .12)}" rx="${f1(w * .1)}" ry="${f1(h * .02)}" fill="#ffe2a8" opacity=".18"/>
      ${figure(lx + w * .03, hz + h * .12, h * .17, '#02050b')}`;
  },
  coast(w, h, r) {
    const hz = h * .55;
    let waves = '';
    for (let i = 0; i < 22; i++) { const y = hz + (h - hz) * (i / 22) ** 1.3; waves += `<path d="M0,${f1(y)} ${Array.from({ length: 12 }, (_, k) => `Q${f1(w * (k + .5) / 12)},${f1(y - h * .006 * (1 + i / 10))} ${f1(w * (k + 1) / 12)},${f1(y)}`).join(' ')}" stroke="#bff3f0" stroke-opacity="${f1(.06 + i * .008)}" fill="none" stroke-width="${f1(1 + i * .15)}"/>`; }
    const lx = w * .24, ly = h * .48;
    return `<defs>${lg('sky', [[0, '#082a36'], [.7, '#2c7f86'], [1, '#9fd8cf']])}${lg('sea', [[0, '#1d5f68'], [1, '#04161b']])}${lg('beam', [[0, '#fff6c8', .55], [1, '#fff6c8', 0]], 1, 0)}${blur('b1', w * .008)}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/><rect y="${f1(hz)}" width="${w}" height="${f1(h - hz)}" fill="url(#sea)"/>${waves}
      <polygon points="${f1(lx)},${f1(ly - h * .2)} ${f1(w * 1.05)},${f1(ly - h * .34)} ${f1(w * 1.05)},${f1(ly - h * .06)}" fill="url(#beam)" filter="url(#b1)"/>
      <path d="M0,${f1(ly)} L${f1(w * .14)},${f1(ly - h * .01)} L${f1(w * .33)},${f1(ly + h * .02)} L${f1(w * .38)},${f1(h * .7)} L${f1(w * .34)},${f1(h)} L0,${h} Z" fill="#061317"/>
      <polygon points="${f1(lx - w * .025)},${f1(ly)} ${f1(lx - w * .016)},${f1(ly - h * .17)} ${f1(lx + w * .016)},${f1(ly - h * .17)} ${f1(lx + w * .025)},${f1(ly)}" fill="#e9eef0"/>
      ${[.04, .1].map(k => `<polygon points="${f1(lx - w * .023 + k * w * .05)},${f1(ly - h * k * 1.1)} ${f1(lx + w * .023 - k * w * .05)},${f1(ly - h * k * 1.1)} ${f1(lx + w * .022 - k * w * .05)},${f1(ly - h * (k * 1.1 + .03))} ${f1(lx - w * .022 + k * w * .05)},${f1(ly - h * (k * 1.1 + .03))}" fill="#1d5f68"/>`).join('')}
      <rect x="${f1(lx - w * .02)}" y="${f1(ly - h * .2)}" width="${f1(w * .04)}" height="${f1(h * .03)}" fill="#fff6c8"/><circle cx="${f1(lx)}" cy="${f1(ly - h * .19)}" r="${f1(w * .05)}" fill="#fff6c8" opacity=".35" filter="url(#b1)"/>
      <path d="M${f1(lx - w * .024)},${f1(ly - h * .2)} L${f1(lx)},${f1(ly - h * .235)} L${f1(lx + w * .024)},${f1(ly - h * .2)} Z" fill="#0c2a30"/>
      ${[[.55, .2], [.62, .17], [.7, .24], [.48, .26]].map(([x, y]) => `<path d="M${f1(w * x - w * .012)},${f1(h * y)} q${f1(w * .006)},${f1(-h * .01)} ${f1(w * .012)},0 q${f1(w * .006)},${f1(-h * .01)} ${f1(w * .012)},0" stroke="#e9eef0" stroke-width="${f1(w * .0025)}" fill="none"/>`).join('')}`;
  },
  space(w, h, r) {
    const px = w * .72, py = h * .82, pr = Math.max(w, h) * .32;
    return `<defs>${rg('neb1', [[0, '#7b2ff7', .55], [1, '#7b2ff7', 0]])}${rg('neb2', [[0, '#00b3ff', .4], [1, '#00b3ff', 0]])}${rg('pl', [[0, '#f6c28b'], [.55, '#c06a3a'], [1, '#2a0f08']], .35, .3, .75)}${lg('ring', [[0, '#f8e3c4', 0], [.5, '#f8e3c4', .8], [1, '#f8e3c4', 0]], 1, 0)}${blur('b1', w * .004)}</defs>
      <rect width="${w}" height="${h}" fill="#02020a"/><ellipse cx="${f1(w * .3)}" cy="${f1(h * .3)}" rx="${f1(w * .5)}" ry="${f1(h * .35)}" fill="url(#neb1)"/><ellipse cx="${f1(w * .55)}" cy="${f1(h * .2)}" rx="${f1(w * .35)}" ry="${f1(h * .25)}" fill="url(#neb2)"/>
      ${stars(w, h, 220, r, 1)}
      <circle cx="${f1(px)}" cy="${f1(py)}" r="${f1(pr)}" fill="url(#pl)"/>
      <ellipse cx="${f1(px)}" cy="${f1(py)}" rx="${f1(pr * 1.7)}" ry="${f1(pr * .28)}" fill="none" stroke="url(#ring)" stroke-width="${f1(pr * .07)}" transform="rotate(-14 ${f1(px)} ${f1(py)})"/>
      <g transform="translate(${f1(w * .32)},${f1(h * .42)}) rotate(-20)"><ellipse rx="${f1(Math.min(w, h) * .14)}" ry="${f1(Math.min(w, h) * .045)}" fill="none" stroke="#cfd6e6" stroke-width="${f1(Math.min(w, h) * .016)}"/>
      ${[0, 60, 120].map(a => `<line x1="${f1(-Math.min(w, h) * .14 * Math.cos(a * Math.PI / 180))}" y1="${f1(-Math.min(w, h) * .045 * Math.sin(a * Math.PI / 180))}" x2="${f1(Math.min(w, h) * .14 * Math.cos(a * Math.PI / 180))}" y2="${f1(Math.min(w, h) * .045 * Math.sin(a * Math.PI / 180))}" stroke="#9aa3b8" stroke-width="${f1(Math.min(w, h) * .005)}"/>`).join('')}
      <circle r="${f1(Math.min(w, h) * .022)}" fill="#e7ecf5"/><circle r="${f1(Math.min(w, h) * .008)}" fill="#4de8ff" filter="url(#b1)"/></g>`;
  },
  archive(w, h, r) {
    const vx = w * .5, vy = h * .48, ew = w * .12, eh = h * .2;
    let shelves = '';
    for (let side of [-1, 1]) {
      for (let i = 0; i < 9; i++) {
        const t = i / 9; const y0 = h * (.05 + t * .9), y1 = vy - eh / 2 + eh * t;
        shelves += `<line x1="${side < 0 ? 0 : w}" y1="${f1(y0)}" x2="${f1(vx + side * ew / 2)}" y2="${f1(y1)}" stroke="#2a1608" stroke-width="${f1(h * .008 * (1 - t * .5))}"/>`;
      }
      for (let k = 0; k < 70; k++) {
        const t = r() ** .7; const x = side < 0 ? (vx - ew / 2) * (1 - t) : vx + ew / 2 + (w - vx - ew / 2) * t;
        const sc = Math.abs(x - vx) / (w / 2); const yy = vy + (r() - .5) * h * .9 * sc;
        shelves += `<rect x="${f1(x)}" y="${f1(yy)}" width="${f1(w * .006 * sc + 1)}" height="${f1(h * .07 * sc + 2)}" fill="${['#6b3a17', '#8a5a2b', '#3d200c', '#a07040'][Math.floor(r() * 4)]}" opacity=".85"/>`;
      }
    }
    return `<defs>${rg('end', [[0, '#fff3d6'], [.4, '#f4c27a', .8], [1, '#3a1f0c', 0]])}${lg('fl', [[0, '#3a210d'], [1, '#0c0603']])}${rg('vig', [[.4, '#000', 0], [1, '#000', .85]])}</defs>
      <rect width="${w}" height="${h}" fill="#1a0e05"/>
      <polygon points="0,${h} ${w},${h} ${f1(vx + ew / 2)},${f1(vy + eh / 2)} ${f1(vx - ew / 2)},${f1(vy + eh / 2)}" fill="url(#fl)"/>
      <polygon points="0,0 ${w},0 ${f1(vx + ew / 2)},${f1(vy - eh / 2)} ${f1(vx - ew / 2)},${f1(vy - eh / 2)}" fill="#120902"/>
      ${shelves}
      <ellipse cx="${f1(vx)}" cy="${f1(vy)}" rx="${f1(w * .35)}" ry="${f1(h * .35)}" fill="url(#end)"/>
      <rect x="${f1(vx - ew / 2)}" y="${f1(vy - eh / 2)}" width="${f1(ew)}" height="${f1(eh)}" fill="#fff3d6" opacity=".9"/>
      ${figure(vx, vy + eh / 2, eh * .8, '#1a0e05')}
      <polygon points="${f1(vx - ew * .3)},${f1(vy + eh / 2)} ${f1(vx + ew * .3)},${f1(vy + eh / 2)} ${f1(vx + w * .2)},${h} ${f1(vx - w * .2)},${h}" fill="#f4c27a" opacity=".1"/>
      <rect width="${w}" height="${h}" fill="url(#vig)"/>`;
  },
  crystal(w, h, r) {
    let s = '';
    for (let i = 0; i < 46; i++) {
      const cx = r() * w, cy = h * (.25 + r() * .85), sz = Math.min(w, h) * (.05 + r() * .22);
      const tilt = (r() - .5) * .6;
      s += `<polygon points="${f1(cx + tilt * sz)},${f1(cy - sz * 1.6)} ${f1(cx + sz * .3)},${f1(cy)} ${f1(cx - sz * .3)},${f1(cy)}" fill="url(#c${i % 3})" opacity="${f1(.35 + r() * .55)}"/>`;
    }
    const cx = w * .5, cy = h * .78, S = Math.min(w, h);
    return `<defs>${lg('bg', [[0, '#01161a'], [1, '#04343a']])}${lg('c0', [[0, '#b8fff6'], [1, '#0e6c6c', .2]])}${lg('c1', [[0, '#69e3ff'], [1, '#063d55', .2]])}${lg('c2', [[0, '#e9fffb'], [1, '#1aa59a', .1]])}${rg('gl', [[0, '#7ff7e6', .7], [1, '#7ff7e6', 0]])}</defs>
      <rect width="${w}" height="${h}" fill="url(#bg)"/>${stars(w, h, 50, r, .5, .5)}
      <ellipse cx="${f1(cx)}" cy="${f1(h * .45)}" rx="${f1(S * .45)}" ry="${f1(S * .45)}" fill="url(#gl)"/>${s}
      <polygon points="${f1(cx)},${f1(cy - S * .72)} ${f1(cx + S * .1)},${f1(cy - S * .3)} ${f1(cx + S * .07)},${f1(cy)} ${f1(cx - S * .07)},${f1(cy)} ${f1(cx - S * .1)},${f1(cy - S * .3)}" fill="url(#c2)" opacity=".95"/>
      <polygon points="${f1(cx)},${f1(cy - S * .72)} ${f1(cx + S * .1)},${f1(cy - S * .3)} ${f1(cx)},${f1(cy - S * .25)}" fill="#fff" opacity=".6"/>
      <rect y="${f1(h * .9)}" width="${w}" height="${f1(h * .1)}" fill="#011012" opacity=".8"/>`;
  },
  fire(w, h, r) {
    let emb = '';
    for (let i = 0; i < 90; i++) emb += `<circle cx="${f1(r() * w)}" cy="${f1(h * (.15 + r() * .6))}" r="${f1(Math.min(w, h) * (.002 + r() * .004))}" fill="${r() < .5 ? '#ffb347' : '#ff6a1a'}" opacity="${f1(.4 + r() * .6)}"/>`;
    return `<defs>${lg('sky', [[0, '#120604'], [.45, '#4a1405'], [.75, '#c2410c'], [1, '#ff9f1a']])}${blur('b1', w * .01)}${blur('b2', w * .03)}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>
      ${[.2, .32, .45].map((y, i) => `<ellipse cx="${f1(w * (.3 + i * .25))}" cy="${f1(h * y)}" rx="${f1(w * .45)}" ry="${f1(h * .09)}" fill="#2a0e06" opacity=".55" filter="url(#b2)"/>`).join('')}
      ${ridge(w, h, h * .62, h * .06, r, '#ff7a1a', 12, .3).replace('<polygon', '<polygon filter="url(#b1)"')}
      ${ridge(w, h, h * .64, h * .06, r, '#170603', 18, .4)}${emb}
      ${ridge(w, h, h * .8, h * .05, r, '#070201', 10, .3)}
      ${figure(w * .62, h * .8, h * .2, '#070201')}`;
  },
  deep(w, h, r) {
    let rays = '';
    for (let i = 0; i < 7; i++) { const x = w * (.1 + i * .14 + (r() - .5) * .05); rays += `<polygon points="${f1(x - w * .02)},0 ${f1(x + w * .02)},0 ${f1(x + w * .12)},${h} ${f1(x - w * .02)},${h}" fill="#bfefff" opacity="${f1(.04 + r() * .06)}"/>`; }
    const jelly = (x, y, s, c) => `<g transform="translate(${f1(x)},${f1(y)})"><ellipse rx="${f1(s * 1.6)}" ry="${f1(s * 1.6)}" fill="${c}" opacity=".18" filter="url(#b1)"/><path d="M${f1(-s)},0 Q${f1(-s)},${f1(-s * 1.1)} 0,${f1(-s * 1.1)} Q${f1(s)},${f1(-s * 1.1)} ${f1(s)},0 Z" fill="${c}" opacity=".85"/>${[-.7, -.35, 0, .35, .7].map(k => `<path d="M${f1(k * s)},0 q${f1(s * .2)},${f1(s * .8)} 0,${f1(s * 1.6)} t0,${f1(s * 1.4)}" stroke="${c}" stroke-opacity=".7" fill="none" stroke-width="${f1(s * .06)}"/>`).join('')}</g>`;
    let bub = '';
    for (let i = 0; i < 30; i++) bub += `<circle cx="${f1(w * .42 + (r() - .5) * w * .05)}" cy="${f1(h * (.2 + r() * .4))}" r="${f1(Math.min(w, h) * (.002 + r() * .006))}" fill="none" stroke="#cdf6ff" stroke-opacity=".6"/>`;
    const S = Math.min(w, h);
    return `<defs>${lg('bg', [[0, '#0a4f7a'], [.4, '#043050'], [1, '#010812']])}${blur('b1', S * .03)}</defs>
      <rect width="${w}" height="${h}" fill="url(#bg)"/>${rays}
      ${jelly(w * .7, h * .38, S * .08, '#ff7ad9')}${jelly(w * .22, h * .3, S * .05, '#6af2ff')}${jelly(w * .84, h * .62, S * .035, '#ffb86a')}
      ${bub}<g transform="translate(${f1(w * .42)},${f1(h * .66)}) rotate(-25)"><ellipse rx="${f1(S * .06)}" ry="${f1(S * .016)}" fill="#020a12"/><circle cx="${f1(-S * .065)}" r="${f1(S * .018)}" fill="#020a12"/><path d="M${f1(S * .05)},0 l${f1(S * .06)},${f1(-S * .015)} l0,${f1(S * .03)} Z" fill="#020a12"/></g>
      ${ridge(w, h, h * .9, h * .04, r, '#010509', 16, .6)}`;
  },
  wolf(w, h, r) {
    let trees = '';
    for (let layer = 0; layer < 3; layer++) {
      const n = 10 + layer * 6, base = h * (.7 + layer * .1), col = ['#16284a', '#0c1830', '#040a16'][layer];
      for (let i = 0; i < n; i++) { const x = w * (i + r() * .6) / n; trees += pine(x, base + r() * h * .04, h * (.25 + layer * .1) * (.6 + r() * .6), col); }
      trees += `<rect y="${f1(base)}" width="${w}" height="${f1(h - base)}" fill="${col}"/>`;
    }
    const S = Math.min(w, h);
    return `<defs>${lg('sky', [[0, '#050b1c'], [1, '#26406e']])}${rg('mg', [[0, '#dfe9ff', .7], [1, '#dfe9ff', 0]])}${blur('b1', S * .006)}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>${stars(w, h, 90, r, .6)}
      <circle cx="${f1(w * .5)}" cy="${f1(h * .33)}" r="${f1(S * .45)}" fill="url(#mg)"/><circle cx="${f1(w * .5)}" cy="${f1(h * .33)}" r="${f1(S * .17)}" fill="#eef3ff"/>
      <circle cx="${f1(w * .46)}" cy="${f1(h * .3)}" r="${f1(S * .03)}" fill="#cfd9ee" opacity=".6"/><circle cx="${f1(w * .54)}" cy="${f1(h * .37)}" r="${f1(S * .02)}" fill="#cfd9ee" opacity=".6"/>
      ${trees}
      <g filter="url(#b1)"><ellipse cx="${f1(w * .46)}" cy="${f1(h * .9)}" rx="${f1(S * .012)}" ry="${f1(S * .007)}" fill="#ffd34d"/><ellipse cx="${f1(w * .5)}" cy="${f1(h * .9)}" rx="${f1(S * .012)}" ry="${f1(S * .007)}" fill="#ffd34d"/></g>
      <ellipse cx="${f1(w * .46)}" cy="${f1(h * .9)}" rx="${f1(S * .008)}" ry="${f1(S * .004)}" fill="#fff4b0"/><ellipse cx="${f1(w * .5)}" cy="${f1(h * .9)}" rx="${f1(S * .008)}" ry="${f1(S * .004)}" fill="#fff4b0"/>`;
  },
  summer(w, h, r) {
    const hz = h * .5, sand = h * .7;
    const cols = ['#ff6b6b', '#4dabf7', '#ffd43b', '#69db7c', '#f783ac', '#ffa94d', '#9775fa', '#3bc9db'];
    let huts = '';
    const n = Math.max(6, Math.round(w / h * 6));
    for (let i = 0; i < n; i++) { const x = w * (.03 + i * .94 / n), hw = w * .94 / n * .82, hh = h * .12; const c = cols[i % cols.length];
      huts += `<rect x="${f1(x)}" y="${f1(sand - hh)}" width="${f1(hw)}" height="${f1(hh)}" fill="${c}"/>${[1, 2, 3].map(k => `<rect x="${f1(x + hw * k / 4 - 1)}" y="${f1(sand - hh)}" width="2" height="${f1(hh)}" fill="#fff" opacity=".35"/>`).join('')}<polygon points="${f1(x - hw * .06)},${f1(sand - hh)} ${f1(x + hw / 2)},${f1(sand - hh - h * .05)} ${f1(x + hw * 1.06)},${f1(sand - hh)}" fill="#fff8ee"/><rect x="${f1(x + hw * .35)}" y="${f1(sand - hh * .55)}" width="${f1(hw * .3)}" height="${f1(hh * .55)}" fill="#00000022"/>`; }
    return `<defs>${lg('sky', [[0, '#8fd3ff'], [.7, '#ffd6a5'], [1, '#ffc3a0']])}${lg('sea', [[0, '#5cc8e0'], [1, '#2a9bbf']])}${lg('sand', [[0, '#f6e0b5'], [1, '#eacb8f']])}${rg('sun', [[0, '#fff7d6'], [.4, '#ffe08a', .9], [1, '#ffe08a', 0]])}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/><circle cx="${f1(w * .78)}" cy="${f1(h * .22)}" r="${f1(Math.min(w, h) * .2)}" fill="url(#sun)"/>
      ${[[.2, .15], [.45, .22], [.62, .1]].map(([x, y]) => `<g fill="#fff" opacity=".9"><ellipse cx="${f1(w * x)}" cy="${f1(h * y)}" rx="${f1(w * .06)}" ry="${f1(h * .025)}"/><ellipse cx="${f1(w * x + w * .03)}" cy="${f1(h * y - h * .02)}" rx="${f1(w * .04)}" ry="${f1(h * .03)}"/></g>`).join('')}
      <rect y="${f1(hz)}" width="${w}" height="${f1(sand - hz)}" fill="url(#sea)"/>${[0, 1, 2, 3].map(i => `<rect y="${f1(hz + (sand - hz) * (i + 1) / 5)}" width="${w}" height="2" fill="#fff" opacity=".35"/>`).join('')}
      <rect y="${f1(sand - h * .02)}" width="${w}" height="${f1(h - sand + h * .02)}" fill="url(#sand)"/>${huts}`;
  },
  dragon(w, h, r) {
    const S = Math.min(w, h), cx = w * .5, cy = h * .58;
    return `<defs>${lg('sky', [[0, '#5ec8ff'], [1, '#c9f0ff']])}${lg('h1', [[0, '#5ee08a'], [1, '#2fb866']])}${lg('h2', [[0, '#3fcf75'], [1, '#1f9a50']])}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>
      ${[[.18, .16], [.72, .12], [.5, .26]].map(([x, y]) => `<g fill="#fff"><ellipse cx="${f1(w * x)}" cy="${f1(h * y)}" rx="${f1(S * .12)}" ry="${f1(S * .045)}"/><circle cx="${f1(w * x - S * .04)}" cy="${f1(h * y - S * .03)}" r="${f1(S * .05)}"/><circle cx="${f1(w * x + S * .04)}" cy="${f1(h * y - S * .04)}" r="${f1(S * .06)}"/></g>`).join('')}
      <ellipse cx="${f1(w * .2)}" cy="${f1(h * 1.05)}" rx="${f1(w * .6)}" ry="${f1(h * .35)}" fill="url(#h2)"/><ellipse cx="${f1(w * .85)}" cy="${f1(h * 1.08)}" rx="${f1(w * .55)}" ry="${f1(h * .33)}" fill="url(#h1)"/>
      <g transform="translate(${f1(cx)},${f1(cy)}) scale(${f1(S / 300)})">
        <path d="M40,40 Q110,60 95,0 Q90,-25 70,-20 Q88,-5 80,20 Q70,40 30,30Z" fill="#ff8a3d"/>
        <path d="M-20,-30 L-75,-85 L-60,-30 L-95,-40 L-40,0Z" fill="#ffb02e"/><path d="M20,-30 L75,-85 L60,-30 L95,-40 L40,0Z" fill="#ffb02e"/>
        <ellipse cx="0" cy="20" rx="52" ry="48" fill="#ff8a3d"/><ellipse cx="0" cy="32" rx="32" ry="30" fill="#ffd9a8"/>
        <circle cx="0" cy="-42" r="42" fill="#ff8a3d"/>
        <path d="M-24,-78 L-16,-100 L-8,-80Z M24,-78 L16,-100 L8,-80Z" fill="#fff1c9"/>
        <circle cx="-15" cy="-46" r="12" fill="#fff"/><circle cx="15" cy="-46" r="12" fill="#fff"/><circle cx="-13" cy="-44" r="6.5" fill="#1d1d1f"/><circle cx="17" cy="-44" r="6.5" fill="#1d1d1f"/><circle cx="-11" cy="-47" r="2.2" fill="#fff"/><circle cx="19" cy="-47" r="2.2" fill="#fff"/>
        <path d="M-14,-22 Q0,-10 14,-22" stroke="#7a2e0e" stroke-width="4" fill="none" stroke-linecap="round"/><circle cx="-28" cy="-28" r="6" fill="#ff5d7a" opacity=".5"/><circle cx="28" cy="-28" r="6" fill="#ff5d7a" opacity=".5"/>
        <ellipse cx="-28" cy="64" rx="16" ry="9" fill="#e66f25"/><ellipse cx="28" cy="64" rx="16" ry="9" fill="#e66f25"/>
      </g>`;
  },
  pirates(w, h, r) {
    const S = Math.min(w, h);
    return `<defs>${lg('bg', [[0, '#2b0f6b'], [1, '#7c3aed']])}${rg('p1', [[0, '#ffd166'], [1, '#f77f00']], .35, .3, .8)}${rg('p2', [[0, '#7ef0c5'], [1, '#118a7e']], .35, .3, .8)}${lg('fl', [[0, '#fff3b0'], [.5, '#ffb703'], [1, '#fb5607', 0]])}</defs>
      <rect width="${w}" height="${h}" fill="url(#bg)"/>${stars(w, h, 80, r, 1)}
      <circle cx="${f1(w * .18)}" cy="${f1(h * .78)}" r="${f1(S * .22)}" fill="url(#p1)"/><ellipse cx="${f1(w * .18)}" cy="${f1(h * .78)}" rx="${f1(S * .34)}" ry="${f1(S * .06)}" fill="none" stroke="#ffe8a3" stroke-width="${f1(S * .015)}" transform="rotate(-12 ${f1(w * .18)} ${f1(h * .78)})"/>
      <circle cx="${f1(w * .85)}" cy="${f1(h * .2)}" r="${f1(S * .1)}" fill="url(#p2)"/><circle cx="${f1(w * .82)}" cy="${f1(h * .18)}" r="${f1(S * .02)}" fill="#0c5e57" opacity=".5"/>
      <g transform="translate(${f1(w * .55)},${f1(h * .45)}) rotate(35) scale(${f1(S / 300)})">
        <path d="M0,-90 Q30,-50 28,30 L-28,30 Q-30,-50 0,-90Z" fill="#f1f5ff"/><path d="M0,-90 Q14,-72 20,-55 L-20,-55 Q-14,-72 0,-90Z" fill="#ef476f"/>
        <circle cy="-20" r="13" fill="#118ab2" stroke="#cfd8ff" stroke-width="5"/>
        <path d="M-28,10 L-50,45 L-28,32Z M28,10 L50,45 L28,32Z" fill="#ef476f"/>
        <path d="M-18,32 Q0,110 18,32Z" fill="url(#fl)"/>
        <path d="M-6,-108 L-6,-80 M-6,-108 L14,-100 L-6,-94" stroke="#1d1d1f" stroke-width="3" fill="#1d1d1f"/>
      </g>`;
  },
  magpie(w, h, r) {
    const dx = w * .58, dw = Math.min(w, h) * .26, dh = h * .62;
    return `<defs>${lg('bg', [[0, '#0d0d10'], [1, '#050506']])}${lg('beam', [[0, '#e8c27a', .45], [1, '#e8c27a', 0]])}${lg('door', [[0, '#fff1cf'], [1, '#e8c27a']])}${rg('vig', [[.5, '#000', 0], [1, '#000', .8]])}</defs>
      <rect width="${w}" height="${h}" fill="url(#bg)"/>
      ${[0, 1, 2, 3].map(i => `<rect x="${f1(w * .05 + i * w * .09)}" y="${f1(h * .08)}" width="${f1(w * .006)}" height="${f1(h * .8)}" fill="#1b1b20"/>`).join('')}
      <polygon points="${f1(dx - dw / 2)},${f1(h * .9)} ${f1(dx + dw / 2)},${f1(h * .9)} ${f1(dx + dw * 2.2)},${h} ${f1(dx - dw * 1.4)},${h}" fill="url(#beam)"/>
      <rect x="${f1(dx - dw / 2)}" y="${f1(h * .9 - dh)}" width="${f1(dw)}" height="${f1(dh)}" fill="url(#door)"/>
      ${coatFigure(dx, h * .9, dh * .82, '#0d0d10')}
      <polygon points="${f1(dx - dw * .1)},${f1(h * .9)} ${f1(dx + dw * .3)},${f1(h * .9)} ${f1(dx + dw * 1.6)},${h} ${f1(dx + dw * .4)},${h}" fill="#000" opacity=".55"/>
      <g transform="translate(${f1(w * .22)},${f1(h * .24)}) scale(${f1(Math.min(w, h) / 400)})"><path d="M0,0 Q20,-14 40,-6 L70,-12 L46,2 Q30,14 6,10 L-30,26 L-8,6Z" fill="#e9e9ee"/><circle cx="34" cy="-6" r="2.5" fill="#0d0d10"/></g>
      <rect width="${w}" height="${h}" fill="url(#vig)"/>`;
  },
  manor(w, h, r) {
    const hz = h * .68, mx = w * .5, mw = Math.min(w * .5, h * .7);
    let win = '';
    for (let row = 0; row < 2; row++) for (let i = 0; i < 7; i++) { const lit = (row === 0 && i === 4) || (row === 1 && i === 1); win += `<rect x="${f1(mx - mw * .42 + i * mw * .12)}" y="${f1(hz - h * .2 + row * h * .09)}" width="${f1(mw * .05)}" height="${f1(h * .05)}" fill="${lit ? '#ffcf73' : '#1b231e'}"/>`; }
    return `<defs>${lg('sky', [[0, '#0f1813'], [.6, '#3d4f3a'], [1, '#8b9a72']])}${rg('gl', [[0, '#ffcf73', .6], [1, '#ffcf73', 0]])}${blur('b1', w * .02)}</defs>
      <rect width="${w}" height="${h}" fill="url(#sky)"/>
      ${[.25, .35].map((y, i) => `<rect x="0" y="${f1(h * y)}" width="${w}" height="${f1(h * .04)}" fill="#c8d2b8" opacity=".08" filter="url(#b1)"/>`).join('')}
      ${ridge(w, h, hz, h * .03, r, '#0b120e', 8, .2)}
      <rect x="${f1(mx - mw / 2)}" y="${f1(hz - h * .24)}" width="${f1(mw)}" height="${f1(h * .25)}" fill="#0b120e"/>
      <polygon points="${f1(mx - mw / 2 - mw * .03)},${f1(hz - h * .24)} ${f1(mx - mw * .25)},${f1(hz - h * .36)} ${f1(mx + mw * .25)},${f1(hz - h * .36)} ${f1(mx + mw / 2 + mw * .03)},${f1(hz - h * .24)}" fill="#0b120e"/>
      <polygon points="${f1(mx - mw * .1)},${f1(hz - h * .3)} ${f1(mx)},${f1(hz - h * .42)} ${f1(mx + mw * .1)},${f1(hz - h * .3)}" fill="#0b120e"/>
      ${[-.35, .3].map(k => `<rect x="${f1(mx + k * mw)}" y="${f1(hz - h * .42)}" width="${f1(mw * .05)}" height="${f1(h * .1)}" fill="#0b120e"/>`).join('')}
      ${win}<circle cx="${f1(mx - mw * .42 + 4 * mw * .12 + mw * .025)}" cy="${f1(hz - h * .175)}" r="${f1(mw * .1)}" fill="url(#gl)"/>
      ${[.12, .86].map(x => `<g stroke="#0b120e" stroke-width="${f1(w * .004)}" fill="none"><path d="M${f1(w * x)},${f1(hz + 2)} L${f1(w * x)},${f1(hz - h * .3)}"/><path d="M${f1(w * x)},${f1(hz - h * .18)} L${f1(w * x - w * .05)},${f1(hz - h * .3)} M${f1(w * x)},${f1(hz - h * .22)} L${f1(w * x + w * .05)},${f1(hz - h * .36)} M${f1(w * x)},${f1(hz - h * .26)} L${f1(w * x - w * .03)},${f1(hz - h * .4)}"/></g>`).join('')}`;
  },
  circuit(w, h, r) {
    let tr = '';
    const cx = w * .5, cy = h * .45, S = Math.min(w, h);
    for (let i = 0; i < 40; i++) {
      let x = cx + (r() - .5) * S * .2, y = cy + (r() - .5) * S * .2; let d = `M${f1(x)},${f1(y)}`;
      for (let k = 0; k < 4; k++) { if (r() < .5) x += (r() - .5) * w * .5; else y += (r() - .5) * h * .5; d += ` L${f1(x)},${f1(y)}`; }
      tr += `<path d="${d}" stroke="#facc15" stroke-opacity="${f1(.2 + r() * .5)}" stroke-width="${f1(S * .004)}" fill="none"/><circle cx="${f1(x)}" cy="${f1(y)}" r="${f1(S * .008)}" fill="#facc15"/>`;
    }
    return `<defs>${rg('gl', [[0, '#fde047', .5], [1, '#fde047', 0]])}${blur('b1', S * .006)}</defs>
      <rect width="${w}" height="${h}" fill="#050805"/><g filter="url(#b1)">${tr}</g>${tr}
      <circle cx="${f1(cx)}" cy="${f1(cy)}" r="${f1(S * .35)}" fill="url(#gl)"/>
      <rect x="${f1(cx - S * .09)}" y="${f1(cy - S * .09)}" width="${f1(S * .18)}" height="${f1(S * .18)}" rx="${f1(S * .015)}" fill="#111" stroke="#facc15" stroke-width="${f1(S * .006)}"/>
      <path d="M${f1(cx - S * .02)},${f1(cy - S * .05)} L${f1(cx + S * .02)},${f1(cy - S * .005)} L${f1(cx - S * .005)},${f1(cy)} L${f1(cx + S * .02)},${f1(cy + S * .05)} L${f1(cx - S * .02)},${f1(cy + S * .005)} L${f1(cx + S * .005)},${f1(cy)} Z" fill="#fff7b0"/>`;
  },
};

// ---------- titels ----------
// t: lijnen voor de poster per taal; type: film/serie
const TITLES = [
  { id: 'noordlicht', nl: 'Noordlicht', en: 'Northlight', scene: 'aurora', type: 'serie', year: 2026, seasons: 2, rating: 8.6, age: 12,
    g: ['Drama', 'Mysterie'], ge: ['Drama', 'Mystery'],
    d: 'Een onderzoeker op een afgelegen poolstation ontvangt signalen die niemand kan verklaren.',
    de: 'A researcher at a remote polar station picks up signals nobody can explain.',
    font: FONT.display, weight: 300, ls: .32, upper: true, pos: 'top', size: 21 },
  { id: 'haven', nl: 'De Laatste Haven', en: 'The Last Harbor', scene: 'harbor', type: 'film', year: 2025, len: 112, rating: 7.9, age: 12,
    g: ['Thriller', 'Drama'], ge: ['Thriller', 'Drama'],
    d: 'Een havenmeester ontdekt dat er één schip te veel is aangemeerd.', de: 'A harbor master discovers that one ship too many has docked.',
    font: FONT.serif, weight: 700, ls: .02, upper: false, pos: 'bottom', size: 27, lines: { nl: ['De Laatste', 'Haven'], en: ['The Last', 'Harbor'] } },
  { id: 'nachtrit', nl: 'Nachtrit', en: 'Night Ride', scene: 'nightride', type: 'film', year: 2026, len: 98, rating: 7.4, age: 16,
    g: ['Actie', 'Thriller'], ge: ['Action', 'Thriller'],
    d: 'Eén nacht, één rit, en een passagier die niet is wie ze zegt.', de: 'One night, one ride, and a passenger who isn’t who she says she is.',
    font: FONT.display, weight: 900, ls: .02, upper: true, italic: true, sx: .82, pos: 'top', size: 38, color: '#ffe7f6' },
  { id: 'polder', nl: 'Polder Noir', en: 'Polder Noir', scene: 'polder', type: 'serie', year: 2025, seasons: 3, rating: 8.4, age: 16,
    g: ['Misdaad', 'Drama'], ge: ['Crime', 'Drama'],
    d: 'In een dorp waar iedereen elkaar kent, verdwijnt de burgemeester zonder spoor.', de: 'In a village where everyone knows everyone, the mayor vanishes without a trace.',
    font: FONT.bonum, weight: 700, ls: .16, upper: true, pos: 'bottom', size: 25, lines: { nl: ['Polder', 'Noir'], en: ['Polder', 'Noir'] } },
  { id: 'stillestad', nl: 'Stille Stad', en: 'Silent City', scene: 'city', type: 'serie', year: 2026, seasons: 1, rating: 8.1, age: 12,
    g: ['Drama'], ge: ['Drama'],
    d: 'Als de hele stad één nacht zonder stroom zit, komen oude geheimen boven.', de: 'When the whole city loses power for one night, old secrets surface.',
    font: FONT.display, weight: 700, ls: .22, upper: true, pos: 'top', size: 22 },
  { id: 'kustlijn', nl: 'Kustlijn', en: 'Coastline', scene: 'coast', type: 'serie', year: 2024, seasons: 4, rating: 7.8, age: 6,
    g: ['Drama', 'Familie'], ge: ['Drama', 'Family'],
    d: 'Drie generaties, één vuurtoren en een zomer die alles verandert.', de: 'Three generations, one lighthouse and a summer that changes everything.',
    font: FONT.pop, weight: 500, ls: .04, upper: false, lower: true, pos: 'top', size: 30 },
  { id: 'stationzero', nl: 'Station Zero', en: 'Station Zero', scene: 'space', type: 'film', year: 2026, len: 131, rating: 8.2, age: 12,
    g: ['Sciencefiction', 'Avontuur'], ge: ['Sci-Fi', 'Adventure'],
    d: 'De bemanning van een verlaten ruimtestation is niet zo alleen als ze dacht.', de: 'The crew of an abandoned space station is not as alone as they thought.',
    font: FONT.adv, weight: 700, ls: .18, upper: true, pos: 'top', size: 24, lines: { nl: ['Station', 'Zero'], en: ['Station', 'Zero'] } },
  { id: 'archief', nl: 'Het Archief', en: 'The Archive', scene: 'archive', type: 'serie', year: 2025, seasons: 2, rating: 8.3, age: 12,
    g: ['Mysterie', 'Thriller'], ge: ['Mystery', 'Thriller'],
    d: 'Een archivaris vindt een dossier over zichzelf, gedateerd volgende week.', de: 'An archivist finds a file about himself, dated next week.',
    font: FONT.bask, weight: 400, ls: .12, upper: true, pos: 'bottom', size: 26 },
  { id: 'glas', nl: 'Glazen Rijk', en: 'Glass Kingdom', scene: 'crystal', type: 'serie', year: 2024, seasons: 3, rating: 8.4, age: 12,
    g: ['Fantasy', 'Drama'], ge: ['Fantasy', 'Drama'],
    d: 'Een architect ontdekt dat de glazen stad die ze ontwierp een geheim verbergt.', de: 'An architect discovers that the glass city she designed hides a secret.',
    font: FONT.display, weight: 200, ls: .3, upper: true, pos: 'bottom', size: 22, lines: { nl: ['Glazen', 'Rijk'], en: ['Glass', 'Kingdom'] } },
  { id: 'vuurlinie', nl: 'Vuurlinie', en: 'Fire Line', scene: 'fire', type: 'film', year: 2025, len: 117, rating: 7.2, age: 12,
    g: ['Actie', 'Drama'], ge: ['Action', 'Drama'],
    d: 'Een brandweerploeg staat tussen een bosbrand en een heel dorp.', de: 'A fire crew stands between a wildfire and an entire village.',
    font: FONT.display, weight: 900, ls: .06, upper: true, pos: 'bottom', size: 32, color: '#fff3e0' },
  { id: 'diepzee', nl: 'Diepzee', en: 'The Deep', scene: 'deep', type: 'film', year: 2024, len: 95, rating: 7.6, age: 6,
    g: ['Documentaire'], ge: ['Documentary'],
    d: 'Een reis naar plekken in de oceaan waar nog nooit een camera was.', de: 'A journey to places in the ocean no camera has been before.',
    font: FONT.pop, weight: 300, ls: .3, upper: true, pos: 'top', size: 24 },
  { id: 'wolfsuur', nl: 'Wolfsuur', en: 'Wolf Hour', scene: 'wolf', type: 'film', year: 2026, len: 104, rating: 7.1, age: 16,
    g: ['Horror', 'Thriller'], ge: ['Horror', 'Thriller'],
    d: 'Een boswachter hoort elke nacht om drie uur hetzelfde geluid.', de: 'A ranger hears the same sound every night at three.',
    font: FONT.serif, weight: 600, ls: .1, upper: true, pos: 'top', size: 27 },
  { id: 'zomer', nl: 'Zomer aan Zee', en: 'Summer by the Sea', scene: 'summer', type: 'film', year: 2025, len: 101, rating: 6.9, age: 0,
    g: ['Komedie', 'Romantiek'], ge: ['Comedy', 'Romance'],
    d: 'Twee strandhuisjes, één misverstand en een heel lange zomer.', de: 'Two beach huts, one misunderstanding and a very long summer.',
    font: FONT.pop, weight: 700, ls: 0, upper: false, pos: 'top', size: 26, color: '#ffffff', lines: { nl: ['Zomer', 'aan Zee'], en: ['Summer', 'by the Sea'] }, shadow: '#c2410c' },
  { id: 'dex', nl: 'Draakje Dex', en: 'Dex the Dragon', scene: 'dragon', type: 'serie', year: 2026, seasons: 2, rating: 7.7, age: 0, kids: true,
    g: ['Animatie', 'Kids'], ge: ['Animation', 'Kids'],
    d: 'Dex is een klein draakje dat liever bakt dan vuur spuwt.', de: 'Dex is a little dragon who would rather bake than breathe fire.',
    font: FONT.pop, weight: 700, ls: .01, upper: false, pos: 'top', size: 28, color: '#fff', shadow: '#1f7a43', lines: { nl: ['Draakje', 'Dex'], en: ['Dex the', 'Dragon'] } },
  { id: 'piraten', nl: 'Ruimtepiraten', en: 'Space Pirates', scene: 'pirates', type: 'film', year: 2025, len: 86, rating: 7.3, age: 0, kids: true,
    g: ['Animatie', 'Avontuur'], ge: ['Animation', 'Adventure'],
    d: 'Een stel kinderen bouwt een raket van karton en belandt echt in de ruimte.', de: 'A bunch of kids build a cardboard rocket and actually end up in space.',
    font: FONT.pop, weight: 700, ls: .01, upper: false, pos: 'bottom', size: 26, color: '#ffe066', shadow: '#3b0d8c', lines: { nl: ['Ruimte-', 'piraten'], en: ['Space', 'Pirates'] } },
  { id: 'ekster', nl: 'Codenaam Ekster', en: 'Codename Magpie', scene: 'magpie', type: 'serie', year: 2026, seasons: 1, rating: 8.0, age: 16,
    g: ['Spionage', 'Thriller'], ge: ['Spy', 'Thriller'],
    d: 'Een vertaalster raakt verstrikt in een spel van agenten en dubbelagenten.', de: 'A translator gets caught in a game of agents and double agents.',
    font: FONT.display, weight: 800, ls: .26, upper: true, pos: 'bottom', size: 18, color: '#e8c27a', lines: { nl: ['Codenaam', 'Ekster'], en: ['Codename', 'Magpie'] } },
  { id: 'erfenis', nl: 'De Erfenis', en: 'The Inheritance', scene: 'manor', type: 'serie', year: 2025, seasons: 2, rating: 7.9, age: 12,
    g: ['Drama'], ge: ['Drama'],
    d: 'Vijf broers en zussen, één landhuis en een testament vol verrassingen.', de: 'Five siblings, one manor and a will full of surprises.',
    font: FONT.serif, weight: 500, ls: .08, upper: false, pos: 'top', size: 28 },
  { id: 'kortsluiting', nl: 'Kortsluiting', en: 'Short Circuit', scene: 'circuit', type: 'film', year: 2026, len: 109, rating: 7.0, age: 12,
    g: ['Thriller', 'Sciencefiction'], ge: ['Thriller', 'Sci-Fi'],
    d: 'Een hacker heeft acht uur om een stad weer online te krijgen.', de: 'A hacker has eight hours to bring a city back online.',
    font: FONT.adv, weight: 700, ls: .08, upper: true, pos: 'bottom', size: 22, color: '#fef08a' },
];
const TBY = Object.fromEntries(TITLES.map(t => [t.id, t]));

function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function svgURL(svg) { return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg).replace(/'/g, '%27').replace(/\(/g, '%28').replace(/\)/g, '%29'); }
function hashStr(s) { let h = 2166136261; for (const c of s) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } return h >>> 0; }

const _cache = {};
function sceneSVG(id, w, h, seed = 0) {
  const t = TBY[id]; const r = rng(hashStr(id) + seed * 7919);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" preserveAspectRatio="xMidYMid slice">${SCENES[t.scene](w, h, r)}</svg>`;
}
// titel op de poster
function posterTitle(t, lang) {
  let lines = t.lines ? t.lines[lang] : [lang === 'en' ? t.en : t.nl];
  if (t.upper) lines = lines.map(s => s.toUpperCase()); else if (t.lower) lines = lines.map(s => s.toLowerCase());
  const sz = t.size, lh = sz * 1.02;
  const n = lines.length;
  const y0 = t.pos === 'top' ? 34 + sz * .75 : 262 - (n - 1) * lh;
  const col = t.color || '#fff';
  const sh = t.shadow ? `<filter id="ts"><feDropShadow dx="0" dy="1.5" stdDeviation="0" flood-color="${t.shadow}"/></filter>` : `<filter id="ts"><feDropShadow dx="0" dy="1" stdDeviation="2.5" flood-color="#000" flood-opacity=".55"/></filter>`;
  const tx = lines.map((s, i) => {
    let len = s.length * sz * (t.upper ? .62 : .52) * (t.sx || 1) + s.length * sz * t.ls;
    const fit = len > 176 ? ` textLength="176" lengthAdjust="spacingAndGlyphs"` : '';
    return `<text x="100" y="${f1(y0 + i * lh)}" text-anchor="middle" font-family="${esc(t.font)}" font-weight="${t.weight}" font-size="${sz}" letter-spacing="${f1(t.ls * sz)}" fill="${col}"${t.italic ? ' font-style="italic"' : ''}${fit}${t.sx ? ` transform="translate(100 0) scale(${t.sx} 1) translate(-100 0)"` : ''}>${esc(s)}</text>`;
  }).join('');
  // nep-aftiteling (onleesbaar blokje, zoals op echte affiches)
  const bill = t.pos === 'top' ? `<g fill="${col}" opacity=".45">${[0, 1].map(k => `<rect x="${32 + k * 6}" y="${280 + k * 4}" width="${136 - k * 12}" height="1.6" rx=".8"/>`).join('')}</g>` : '';
  return `<defs>${sh}</defs><g filter="url(#ts)">${tx}</g>${bill}`;
}
function posterURL(id, lang) {
  const k = `p:${id}:${lang}`; if (_cache[k]) return _cache[k];
  const t = TBY[id]; const r = rng(hashStr(id));
  const shade = t.pos === 'top'
    ? `<linearGradient id="sh" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#000" stop-opacity=".45"/><stop offset=".35" stop-color="#000" stop-opacity="0"/></linearGradient>`
    : `<linearGradient id="sh" x1="0" y1="0" x2="0" y2="1"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".7"/></linearGradient>`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300" width="400" height="600"><svg viewBox="0 0 200 300" width="200" height="300">${SCENES[t.scene](200, 300, r)}</svg><defs>${shade}</defs><rect width="200" height="300" fill="url(#sh)"/>${posterTitle(t, lang)}</svg>`;
  return (_cache[k] = svgURL(svg));
}
function backdropURL(id, seed = 0, w = 1600, h = 900) {
  const k = `b:${id}:${seed}:${w}x${h}`; if (_cache[k]) return _cache[k];
  return (_cache[k] = svgURL(sceneSVG(id, w, h, seed)));
}
// titel als "logo" (op hero/detail), in de typografie van de poster
function titleLogo(id, lang, px, align = 'center', maxw) {
  const t = TBY[id];
  let s = lang === 'en' ? t.en : t.nl;
  if (t.upper) s = s.toUpperCase(); else if (t.lower) s = s.toLowerCase();
  return `<div style="font-family:${t.font};font-weight:${t.weight};font-size:${px}px;letter-spacing:${t.ls}em;line-height:1.02;text-align:${align};color:${t.color || '#fff'};${t.italic ? 'font-style:italic;' : ''}${t.sx ? `transform:scaleX(${t.sx});transform-origin:${align === 'center' ? '50%' : '0'} 50%;` : ''}text-shadow:0 2px 18px rgba(0,0,0,.55)${maxw ? `;max-width:${maxw}px` : ''}">${esc(s)}</div>`;
}

// ---------- fictieve zenders en programma's ----------
const CHANNELS = [
  { n: 'Kade 24', c: '#ff7a1a', mark: 'sq', now: ['Kade Journaal', 'Kade News'], next: ['Weekoverzicht', 'Week in Review'], p: .62 },
  { n: 'Veldsport', c: '#22c55e', mark: 'ball', now: ['Voetbal: halve finale', 'Football: semi-final'], next: ['Sportcafé', 'Sports Café'], p: .41 },
  { n: 'Lumo', c: '#f472b6', mark: 'dot', now: ['De Keukenbrigade', 'The Kitchen Brigade'], next: ['Avondquiz', 'Evening Quiz'], p: .78 },
  { n: 'Kompas Docu', c: '#38bdf8', mark: 'tri', now: ['Wilde Wadden', 'Wild Wetlands'], next: ['Oceaanreus', 'Ocean Giant'], p: .3 },
  { n: 'Pixel Kids', c: '#facc15', mark: 'px', now: ['Draakje Dex', 'Dex the Dragon'], next: ['Slaapliedjes', 'Lullabies'], p: .55 },
  { n: 'Cinevak', c: '#2dd4bf', mark: 'ring', now: ['De Laatste Haven', 'The Last Harbor'], next: ['Wolfsuur', 'Wolf Hour'], p: .2 },
  { n: 'Vonk', c: '#a78bfa', mark: 'bolt', now: ['Vonk Live Sessies', 'Vonk Live Sessions'], next: ['De Hitlijst', 'The Chart Show'], p: .67 },
  { n: 'Duin TV', c: '#fbbf24', mark: 'wave', now: ['Stadsverhalen', 'City Stories'], next: ['Strandweer', 'Beach Weather'], p: .47 },
  { n: 'Motorpark', c: '#fb923c', mark: 'flag', now: ['Rallyweekend', 'Rally Weekend'], next: ['Garagepraat', 'Garage Talk'], p: .36 },
  { n: 'Nachtnet', c: '#94a3b8', mark: 'moon', now: ['Nachtnieuws', 'Late News'], next: ['Klassiekers', 'Classics'], p: .52 },
];
function chMark(c, s) {
  const k = c.c;
  const m = {
    sq: `<rect x="2" y="2" width="20" height="20" rx="5" fill="${k}"/><path d="M6 15 q3-4 6 0 t6 0" stroke="#000" stroke-width="2.2" fill="none"/>`,
    ball: `<circle cx="12" cy="12" r="10" fill="${k}"/><path d="M12 6 l4 3 -1.5 5h-5L8 9z" fill="#000"/>`,
    dot: `<circle cx="12" cy="12" r="10" fill="${k}"/><circle cx="12" cy="12" r="4" fill="#000"/>`,
    tri: `<path d="M12 2 L22 21 H2Z" fill="${k}"/><path d="M12 9 L16 17 H8Z" fill="#000"/>`,
    px: `<rect x="2" y="2" width="9" height="9" rx="2" fill="${k}"/><rect x="13" y="2" width="9" height="9" rx="2" fill="#fff"/><rect x="2" y="13" width="9" height="9" rx="2" fill="#fff"/><rect x="13" y="13" width="9" height="9" rx="2" fill="${k}"/>`,
    ring: `<circle cx="12" cy="12" r="8.5" stroke="${k}" stroke-width="4" fill="none"/><circle cx="12" cy="12" r="2.5" fill="${k}"/>`,
    bolt: `<path d="M14 1 L4 14 h7 l-2 9 L20 9 h-7z" fill="${k}"/>`,
    wave: `<rect x="2" y="2" width="20" height="20" rx="10" fill="${k}"/><path d="M4 14 q4-5 8 0 t8 0 v8 H4z" fill="#000" opacity=".8"/>`,
    flag: `<rect x="3" y="3" width="18" height="18" rx="3" fill="${k}"/><path d="M7 7h3v3H7zM13 7h3v3h-3zM10 10h3v3h-3zM7 13h3v3H7zM13 13h3v3h-3z" fill="#000"/>`,
    moon: `<circle cx="12" cy="12" r="10" fill="${k}"/><circle cx="16" cy="9" r="8" fill="#000"/>`,
  }[c.mark];
  return `<svg viewBox="0 0 24 24" width="${s}" height="${s}" style="flex:none">${m}</svg>`;
}
// zenderlogo: merkje + naam
function chLogo(c, px, stack = false) {
  return `<div style="display:flex;${stack ? 'flex-direction:column;' : ''}align-items:center;justify-content:center;gap:${f1(px * .35)}px;font-family:${FONT.display};font-weight:800;font-size:${px}px;letter-spacing:-.01em;color:#fff;white-space:nowrap;line-height:1">${chMark(c, px * 1.25)}<span>${esc(c.n)}</span></div>`;
}

// profielavatars (SF Symbol-achtig op kleurverloop, zoals PlaylistAvatar), plus getekende kinderavatars
const PAL = [['#E50914', '#7A0008'], ['#2563EB', '#1E1B4B'], ['#10B981', '#064E3B'], ['#F59E0B', '#9A3412'], ['#A855F7', '#3B0764'], ['#EC4899', '#831843'], ['#14B8A6', '#0C4A6E'], ['#64748B', '#0F172A']];
const SYM = {
  tv: '<rect x="3" y="6" width="18" height="12" rx="2.2" fill="none" stroke="#fff" stroke-width="2"/><path d="M8 21h8M9 3l3 3 3-3" stroke="#fff" stroke-width="2" stroke-linecap="round" fill="none"/>',
  popcorn: '<path d="M6 10 L8 21 H16 L18 10Z" fill="#fff"/><path d="M9.5 10.5 L10.5 21 M14.5 10.5 L13.5 21" stroke="#0004" stroke-width="1.4"/><circle cx="8" cy="8" r="2.6" fill="#fff"/><circle cx="12" cy="6.5" r="3" fill="#fff"/><circle cx="16" cy="8" r="2.6" fill="#fff"/>',
  star: '<path d="M12 2.5l2.9 6 6.6.8-4.9 4.5 1.3 6.5L12 17l-5.9 3.3 1.3-6.5L2.5 9.3l6.6-.8z" fill="#fff"/>',
  moon: '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z" fill="#fff"/><path d="M17 3l.6 1.6L19 5l-1.4.5L17 7l-.6-1.5L15 5l1.4-.4z" fill="#fff"/>',
  flame: '<path d="M12 2c1 4 6 6 6 12a6 6 0 0 1-12 0c0-3 2-5 3-6 0 2 1 3 2 3 0-3-1-6 1-9z" fill="#fff"/>',
  game: '<path d="M7 8h10a5 5 0 0 1 4.8 6.4l-.9 3a2.5 2.5 0 0 1-4.3.9L14.5 16h-5l-2.1 2.3a2.5 2.5 0 0 1-4.3-.9l-.9-3A5 5 0 0 1 7 8z" fill="#fff"/><path d="M7 11v4M5 13h4" stroke="#0006" stroke-width="1.6"/><circle cx="16" cy="12" r="1.1" fill="#0006"/><circle cx="18" cy="14" r="1.1" fill="#0006"/>',
};
function avatar(a, s, radius = '50%') {
  if (a.kid) return `<img src="${a.kid}" style="width:${s}px;height:${s}px;border-radius:${radius};display:block;object-fit:cover">`;
  const p = PAL[a.pal];
  return `<div style="width:${s}px;height:${s}px;border-radius:${radius};background:linear-gradient(135deg,${p[0]},${p[1]});display:grid;place-items:center;flex:none"><svg viewBox="0 0 24 24" width="${f1(s * .5)}" height="${f1(s * .5)}">${SYM[a.sym]}</svg></div>`;
}
const AVDIR = '../../Shared/Resources/Avatars/';
const PROFILES = [
  { name: 'Sanne', nameEn: 'Sanne', pal: 0, sym: 'tv' },
  { name: 'Daan', nameEn: 'Daan', pal: 1, sym: 'popcorn' },
  { name: 'Noor', nameEn: 'Noor', kid: AVDIR + 'kid03.png', age: 12 },
  { name: 'Mees', nameEn: 'Mees', kid: AVDIR + 'kid16.png', age: 6 },
  { name: 'Gast', nameEn: 'Guest', pal: 4, sym: 'star' },
];

// kleine QR-achtige code (decoratief; niet scanbaar)
function fakeQR(n = 29, seed = 7) {
  const r = rng(seed); const m = [];
  for (let y = 0; y < n; y++) { m.push([]); for (let x = 0; x < n; x++) m[y].push(r() < .48 ? 1 : 0); }
  const fp = (ox, oy) => { for (let y = -1; y < 8; y++) for (let x = -1; x < 8; x++) { const X = ox + x, Y = oy + y; if (X < 0 || Y < 0 || X >= n || Y >= n) continue; const d = Math.max(Math.abs(x - 3), Math.abs(y - 3)); m[Y][X] = (d === 3 || d <= 1) ? 1 : 0; } };
  fp(0, 0); fp(n - 7, 0); fp(0, n - 7);
  for (let i = 8; i < n - 8; i++) { m[6][i] = i % 2 ? 0 : 1; m[i][6] = i % 2 ? 0 : 1; }
  // uitlijnpatroon
  const ax = n - 9; for (let y = -2; y <= 2; y++) for (let x = -2; x <= 2; x++) { const d = Math.max(Math.abs(x), Math.abs(y)); m[ax + y][ax + x] = d === 1 ? 0 : 1; }
  let s = ''; for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (m[y][x]) s += `<rect x="${x}" y="${y}" width="1.02" height="1.02"/>`;
  return `<svg viewBox="0 0 ${n} ${n}" width="100%" height="100%" shape-rendering="crispEdges"><g fill="#000">${s}</g></svg>`;
}
