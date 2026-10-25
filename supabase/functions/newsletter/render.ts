// Bingr nieuwsbrief: de mail in de huisstijl (supabase/functions/_shared/layout.ts): zwart, BINGR met rode streep (geen
// app-icoon), kaart #141414 met rode rand. Alle tekst uit TMDB gaat door esc(); afbeeldingen alleen van image.tmdb.org
// met een gecontroleerd pad (logic.ts imgPath). Tabellen met inline stijlen (Gmail, Outlook, Apple Mail) + platte tekst.
// Posters met vaste breedte en alt-tekst; elke poster en titel linkt naar de universele link bingr.online/titel/ (opent
// de app als die er is, anders de deelpagina met "Open in Bingr"). Geen trackers of persoonsgegevens in links.
import { esc, FONT, footerHtml, footerText, greeting, greetingText, layout, RED } from "../_shared/layout.ts";
import { type Edition, img, type Item, type Lang, titleUrl } from "./logic.ts";

const IMDB_YELLOW = "#F5C518";

type T = {
  eyebrow: string; title: string; intro: string; featured: string; watch: string; info: string; fresh: string; soon: string;
  popular: string; movie: string; tv: string; honest: string; reason: string; unsub: string; tmdb: string; preheader: string;
  top10: string; top10Intro: string; movies: string; series: string; trakt: string; omdb: string; justwatch: string;
  subject: (t: string) => string; subjectNone: string; empty: string;
};
export const TEXT: Record<Lang, T> = {
  nl: {
    eyebrow: "Nieuw om te kijken", title: "Wat is er nieuw aan films en series", intro: "Een greep uit wat net verscheen op streamingdiensten in Nederland, wat binnenkort uitkomt en wat deze week veel bekeken wordt.",
    featured: "Uitgelicht", watch: "Bekijk in Bingr", info: "Meer info", fresh: "Nieuw om te kijken", soon: "Binnenkort", popular: "Populair",
    movie: "Film", tv: "Serie",
    top10: "Top 10 deze week", top10Intro: "Wat nu trending is aan films en series.", movies: "Films", series: "Series",
    trakt: "Top 10 mede op basis van Trakt.", omdb: "IMDb-scores via OMDb.", justwatch: "Streaminggegevens: JustWatch.",
    honest: "Bingr levert zelf geen films of series. Of een titel bij jou te zien is, hangt af van je eigen bron.",
    reason: "Je krijgt deze nieuwsbrief omdat je een Bingr-account hebt.", unsub: "Geen nieuwsbrief meer? Afmelden",
    tmdb: "Film- en seriegegevens: TMDB. Deze mail gebruikt de TMDB API, maar is niet goedgekeurd of gecertificeerd door TMDB.",
    preheader: "Nieuw om te kijken", subject: (t) => `Nieuw om te kijken: ${t} en meer`, subjectNone: "Nieuw om te kijken bij Bingr",
    empty: "Deze week geen nieuwe titels gevonden.",
  },
  en: {
    eyebrow: "New to watch", title: "What's new in movies and series", intro: "A selection of what just arrived on streaming services in the Netherlands, what's coming soon and what people are watching this week.",
    featured: "Featured", watch: "Watch in Bingr", info: "More info", fresh: "New to watch", soon: "Coming soon", popular: "Popular",
    movie: "Movie", tv: "Series",
    top10: "Top 10 this week", top10Intro: "What's trending in movies and series right now.", movies: "Movies", series: "Series",
    trakt: "Top 10 partly based on Trakt.", omdb: "IMDb ratings via OMDb.", justwatch: "Streaming data: JustWatch.",
    honest: "Bingr doesn't provide any movies or series itself. Whether you can watch a title depends on your own source.",
    reason: "You're receiving this newsletter because you have a Bingr account.", unsub: "Don't want the newsletter? Unsubscribe",
    tmdb: "Movie and series data: TMDB. This email uses the TMDB API but is not endorsed or certified by TMDB.",
    preheader: "New to watch", subject: (t) => `New to watch: ${t} and more`, subjectNone: "New to watch on Bingr",
    empty: "No new titles found this week.",
  },
};

const MONTHS: Record<Lang, string[]> = {
  nl: ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"],
  en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
};
/** "17 okt" / "Oct 17" uit yyyy-mm-dd. */
export function shortDate(lang: Lang, d: string | null): string {
  if (!d || !/^\d{4}-\d{2}-\d{2}$/.test(d)) return "";
  const m = MONTHS[lang][Number(d.slice(5, 7)) - 1] ?? "", n = Number(d.slice(8, 10));
  return lang === "nl" ? `${n} ${m}` : `${m} ${n}`;
}
const kindYear = (lang: Lang, i: Item) => [TEXT[lang][i.type === "tv" ? "tv" : "movie"], i.year ? String(i.year) : ""].filter(Boolean).join(" · ");
/** "2025 · Drama" (soort staat al in de kop van de Top 10). */
const yearGenre = (i: Item) => [i.year ? String(i.year) : "", i.genre ?? ""].filter(Boolean).join(" · ");
/** "Serie · 2025 · Drama". */
const kindYearGenre = (lang: Lang, i: Item) => [kindYear(lang, i), i.genre ?? ""].filter(Boolean).join(" · ");
/** Score: IMDb (via OMDb) als die er is, anders TMDB; nl met komma. "" zonder score. */
export function scoreText(lang: Lang, i: Item): string {
  const v = typeof i.imdb === "number" ? i.imdb : typeof i.score === "number" ? i.score : null;
  if (v === null || !(v > 0 && v <= 10)) return "";
  const n = v.toFixed(1);
  return `${typeof i.imdb === "number" ? "IMDb" : "TMDB"} ${lang === "nl" ? n.replace(".", ",") : n}`;
}
const scoreHtml = (lang: Lang, i: Item) => {
  const t = scoreText(lang, i);
  if (!t) return "";
  const imdb = t.startsWith("IMDb");
  return `<div style="margin:3px 0 0;font-size:11px;line-height:15px;font-weight:700;color:${imdb ? IMDB_YELLOW : "#b3b3b3"}">&#9733;&nbsp;${esc(t)}</div>`;
};

const sectionTitle = (s: string) =>
  `<tr><td style="padding:30px 0 12px"><div style="font-size:18px;line-height:24px;font-weight:800;color:#ffffff">${esc(s)}</div><div style="height:3px;width:36px;background:${RED};border-radius:2px;margin-top:6px;font-size:0;line-height:0">&nbsp;</div></td></tr>`;

function buttons(lang: Lang, url: string) {
  const t = TEXT[lang];
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0 0"><tr>
<td bgcolor="${RED}" style="border-radius:6px;background:${RED}"><a href="${esc(url)}" style="display:inline-block;padding:12px 22px;font-family:${FONT};font-size:15px;font-weight:700;line-height:20px;color:#ffffff;text-decoration:none;border-radius:6px">&#9654;&nbsp; ${esc(t.watch)}</a></td>
<td width="10" style="width:10px;font-size:0;line-height:0">&nbsp;</td>
<td bgcolor="#2a2a2a" style="border-radius:6px;background:#2a2a2a"><a href="${esc(url)}" style="display:inline-block;padding:12px 22px;font-family:${FONT};font-size:15px;font-weight:700;line-height:20px;color:#ffffff;text-decoration:none;border-radius:6px">${esc(t.info)}</a></td>
</tr></table>`;
}

function featuredHtml(lang: Lang, i: Item) {
  const url = titleUrl(i), bg = img(i.backdrop, "w780");
  return `<tr><td style="padding:22px 0 0">
${bg ? `<a href="${esc(url)}" style="text-decoration:none"><img src="${esc(bg)}" width="500" alt="${esc(i.title)}" style="display:block;width:100%;max-width:500px;height:auto;border:0;border-radius:8px;background:#1f1f1f"></a>` : ""}
<div style="margin:16px 0 0;font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:${RED}">${esc(TEXT[lang].featured)} · ${esc(kindYear(lang, i))}</div>
<div style="margin:6px 0 0;font-size:22px;line-height:28px;font-weight:800;color:#ffffff"><a href="${esc(url)}" style="color:#ffffff;text-decoration:none">${esc(i.title)}</a></div>
${i.overview ? `<p style="margin:8px 0 0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(i.overview)}</p>` : ""}
${buttons(lang, url)}
</td></tr>`;
}

type CardOpts = { rank?: number; score?: boolean };
/** Posterkaart (rasters): poster (vaste breedte, alt = titel), eventueel rangnummer, titel, eronder een regel (soort · jaar,
 *  of de datum met "!" ervoor in rood) en eventueel de score. Poster en titel linken naar de titel in Bingr. */
function card(lang: Lang, i: Item, label: string, width: number, o: CardOpts = {}) {
  const url = titleUrl(i), p = img(i.poster, width <= 100 ? "w185" : "w342");
  const small = width <= 100;
  const rank = o.rank ? `<span style="color:${RED};font-weight:900">${o.rank}</span>&nbsp; ` : "";
  return `<a href="${esc(url)}" style="text-decoration:none;color:#ffffff">${p ? `<img src="${esc(p)}" width="${width}" alt="${esc(i.title)}" style="display:block;width:100%;max-width:${width}px;height:auto;border:0;border-radius:6px;background:#1f1f1f">` : ""}
<div style="margin:8px 0 0;font-size:${small ? 12 : 13}px;line-height:${small ? 16 : 17}px;font-weight:700;color:#ffffff;word-break:break-word">${rank}${esc(i.title)}</div></a>
${label.replace(/^!/, "") ? `<div style="margin:2px 0 0;font-size:${small ? 11 : 12}px;line-height:${small ? 15 : 16}px;color:${label.startsWith("!") ? RED : "#8c8c8c"};font-weight:${label.startsWith("!") ? 700 : 400}">${esc(label.replace(/^!/, ""))}</div>` : ""}${o.score ? scoreHtml(lang, i) : ""}`;
}
function grid(lang: Lang, items: Item[], cols: number, label: (i: Item) => string, o: { ranked?: boolean; score?: boolean } = {}) {
  const gap = cols >= 5 ? 8 : 12;
  const w = Math.floor((500 - (cols - 1) * gap) / cols);
  const rows: string[] = [];
  for (let r = 0; r < items.length; r += cols) {
    const cells = items.slice(r, r + cols).map((i, n) =>
      `<td width="${w}" valign="top" style="width:${w}px;vertical-align:top;padding:0 0 18px">${card(lang, i, label(i), w, { rank: o.ranked ? r + n + 1 : undefined, score: o.score })}</td>`);
    while (cells.length < cols) cells.push(`<td width="${w}" style="width:${w}px">&nbsp;</td>`);
    rows.push(`<tr>${cells.join(`<td width="${gap}" style="width:${gap}px;font-size:0;line-height:0">&nbsp;</td>`)}</tr>`);
  }
  return `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${rows.join("")}</table></td></tr>`;
}
const subTitle = (s: string) =>
  `<tr><td style="padding:4px 0 10px;font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(s)}</td></tr>`;
const sectionIntro = (s: string) =>
  `<tr><td style="padding:0 0 14px;font-size:14px;line-height:21px;color:#b3b3b3">${esc(s)}</td></tr>`;

/** Top 10: films en series apart, elk twee rijen van 5 posters met rangnummer, jaar · genre en score. */
function top10Html(lang: Lang, e: Edition): string[] {
  const t = TEXT[lang], m = e.top10?.movies ?? [], s = e.top10?.tv ?? [];
  if (!m.length && !s.length) return [];
  const out = [sectionTitle(t.top10), sectionIntro(t.top10Intro)];
  if (m.length) out.push(subTitle(t.movies), grid(lang, m, 5, yearGenre, { ranked: true, score: true }));
  if (s.length) out.push(subTitle(t.series), grid(lang, s, 5, yearGenre, { ranked: true, score: true }));
  return out;
}

export type RenderOpts = { lang: Lang; edition: Edition; firstName?: string; unsubscribeUrl: string; year?: number; preview?: boolean };

export function subjectOf(lang: Lang, e: Edition, preview = false) {
  const s = e.featured ? TEXT[lang].subject(e.featured.title) : TEXT[lang].subjectNone;
  return (preview ? "[Voorbeeld] " : "") + s;
}

/** De hele mail: {subject, html, text}. */
export function renderNewsletter(o: RenderOpts): { subject: string; html: string; text: string } {
  const t = TEXT[o.lang], e = o.edition;
  const parts: string[] = [];
  if (e.featured) parts.push(featuredHtml(o.lang, e.featured));
  parts.push(...top10Html(o.lang, e));
  if (e.fresh.length) parts.push(sectionTitle(t.fresh), grid(o.lang, e.fresh, 3, (i) => kindYear(o.lang, i)));
  if (e.soon.length) parts.push(sectionTitle(t.soon), grid(o.lang, e.soon, 4, (i) => "!" + shortDate(o.lang, i.date)));
  if (e.popular.length) parts.push(sectionTitle(t.popular), grid(o.lang, e.popular, 3, (i) => kindYearGenre(o.lang, i), { score: true }));
  if (!parts.length) parts.push(`<tr><td style="padding:18px 0 0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(t.empty)}</td></tr>`);
  const content = `${greeting(o.lang, o.firstName)}<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(t.eyebrow)}</div>
<h1 style="margin:8px 0 10px;font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(t.title)}</h1>
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(t.intro)}</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${parts.join("\n")}</table>
<p style="margin:24px 0 0;padding:14px 16px;background:#1f1f1f;border-radius:8px;font-size:13px;line-height:19px;color:#b3b3b3">${esc(t.honest)}</p>`;
  const [unsubQ, unsubA] = t.unsub.split("? ");
  const reasonHtml = `${esc(t.reason)}<br>${esc(unsubQ)}? <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(unsubA)}</a>`;
  const footer = footerHtml({ lang: o.lang, reasonHtml, year: o.year }) +
    `<br><span style="color:#5c5c5c;font-size:11px;line-height:16px">${credits(o.lang, e).map(esc).join(" ")}</span>`;
  const titles = [e.featured, ...e.fresh].filter(Boolean).slice(0, 3).map((i) => i!.title);
  const subject = subjectOf(o.lang, e, o.preview);
  const html = layout({
    lang: o.lang, docTitle: subject, preheader: titles.length ? `${t.preheader}: ${titles.join(", ")}` : t.preheader,
    label: "", contentHtml: content, footerHtml: footer,
  });
  return { subject, html, text: textOf(o) };
}

/** Bronvermelding: altijd TMDB; Trakt, OMDb (IMDb-scores) en JustWatch (streaming in "Nieuw") alleen als ze gebruikt zijn. */
export function credits(lang: Lang, e: Edition): string[] {
  const t = TEXT[lang], out = [t.tmdb];
  const top = [...(e.top10?.movies ?? []), ...(e.top10?.tv ?? [])];
  if (e.fresh.length) out.push(t.justwatch);
  if (e.credits?.trakt && top.length) out.push(t.trakt);
  if ([...top, ...e.popular].some((i) => typeof i.imdb === "number")) out.push(t.omdb);
  return out;
}

/** Platte-tekstversie. */
export function textOf(o: RenderOpts): string {
  const t = TEXT[o.lang], e = o.edition, out: string[] = [];
  const g = greetingText(o.lang, o.firstName);
  if (g) out.push(g, "");
  out.push(t.title, "", t.intro, "");
  const line = (i: Item, extra = "") => `- ${i.title}${extra ? ` (${extra})` : ""}: ${titleUrl(i)}`;
  if (e.featured) out.push(`${t.featured}: ${e.featured.title} (${kindYear(o.lang, e.featured)})`, e.featured.overview, `${t.watch}: ${titleUrl(e.featured)}`, "");
  const ranked = (i: Item, n: number) => {
    const extra = [yearGenre(i), scoreText(o.lang, i)].filter(Boolean).join(", ");
    return `${n + 1}. ${i.title}${extra ? ` (${extra})` : ""}: ${titleUrl(i)}`;
  };
  const tm = e.top10?.movies ?? [], ts = e.top10?.tv ?? [];
  if (tm.length || ts.length) {
    out.push(t.top10);
    if (tm.length) out.push(`${t.movies}:`, ...tm.map(ranked));
    if (ts.length) out.push(`${t.series}:`, ...ts.map(ranked));
    out.push("");
  }
  if (e.fresh.length) out.push(t.fresh, ...e.fresh.map((i) => line(i, kindYear(o.lang, i))), "");
  if (e.soon.length) out.push(t.soon, ...e.soon.map((i) => line(i, shortDate(o.lang, i.date))), "");
  if (e.popular.length) out.push(t.popular, ...e.popular.map((i) => line(i, [kindYearGenre(o.lang, i), scoreText(o.lang, i)].filter(Boolean).join(", "))), "");
  out.push(t.honest, "", footerText({ lang: o.lang, reason: t.reason, year: o.year }), `${t.unsub}: ${o.unsubscribeUrl}`, ...credits(o.lang, e));
  return out.filter((x, n, a) => !(x === "" && a[n - 1] === "")).join("\n");
}
