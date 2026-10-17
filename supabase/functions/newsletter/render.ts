// Bingr nieuwsbrief: de mail in de huisstijl (supabase/functions/_shared/layout.ts): zwart, BINGR met rode streep (geen
// app-icoon), kaart #141414 met rode rand. Alle tekst uit TMDB gaat door esc(); afbeeldingen alleen van image.tmdb.org
// met een gecontroleerd pad (logic.ts imgPath). Tabellen met inline stijlen (Gmail, Outlook, Apple Mail) + platte tekst.
import { esc, FONT, footerHtml, footerText, greeting, greetingText, layout, RED } from "../_shared/layout.ts";
import { type Edition, img, type Item, type Lang, titleUrl } from "./logic.ts";

type T = {
  eyebrow: string; title: string; intro: string; featured: string; watch: string; info: string; fresh: string; soon: string;
  popular: string; movie: string; tv: string; honest: string; reason: string; unsub: string; tmdb: string; preheader: string;
  subject: (t: string) => string; subjectNone: string; empty: string;
};
export const TEXT: Record<Lang, T> = {
  nl: {
    eyebrow: "Nieuw om te kijken", title: "Wat is er nieuw aan films en series", intro: "Een greep uit wat net verscheen op streamingdiensten in Nederland, wat binnenkort uitkomt en wat deze week veel bekeken wordt.",
    featured: "Uitgelicht", watch: "Bekijk in Bingr", info: "Meer info", fresh: "Nieuw om te kijken", soon: "Binnenkort", popular: "Populair deze week",
    movie: "Film", tv: "Serie",
    honest: "Bingr levert zelf geen films of series. Of een titel bij jou te zien is, hangt af van je eigen bron.",
    reason: "Je krijgt deze nieuwsbrief omdat je een Bingr-account hebt.", unsub: "Geen nieuwsbrief meer? Afmelden",
    tmdb: "Film- en seriegegevens: TMDB. Bingr gebruikt de TMDB API, maar is niet goedgekeurd of gecertificeerd door TMDB.",
    preheader: "Nieuw om te kijken", subject: (t) => `Nieuw om te kijken: ${t} en meer`, subjectNone: "Nieuw om te kijken bij Bingr",
    empty: "Deze week geen nieuwe titels gevonden.",
  },
  en: {
    eyebrow: "New to watch", title: "What's new in movies and series", intro: "A selection of what just arrived on streaming services in the Netherlands, what's coming soon and what people are watching this week.",
    featured: "Featured", watch: "Watch in Bingr", info: "More info", fresh: "New to watch", soon: "Coming soon", popular: "Popular this week",
    movie: "Movie", tv: "Series",
    honest: "Bingr doesn't provide any movies or series itself. Whether you can watch a title depends on your own source.",
    reason: "You're receiving this newsletter because you have a Bingr account.", unsub: "Don't want the newsletter? Unsubscribe",
    tmdb: "Movie and series data: TMDB. Bingr uses the TMDB API but is not endorsed or certified by TMDB.",
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

/** Posterkaart (raster en Binnenkort): poster, titel, eronder soort · jaar of de datum. */
function card(lang: Lang, i: Item, label: string, width: number) {
  const url = titleUrl(i), p = img(i.poster, "w342");
  return `<a href="${esc(url)}" style="text-decoration:none;color:#ffffff">${p ? `<img src="${esc(p)}" width="${width}" alt="${esc(i.title)}" style="display:block;width:100%;max-width:${width}px;height:auto;border:0;border-radius:6px;background:#1f1f1f">` : ""}
<div style="margin:8px 0 0;font-size:13px;line-height:17px;font-weight:700;color:#ffffff;word-break:break-word">${esc(i.title)}</div></a>
<div style="margin:2px 0 0;font-size:12px;line-height:16px;color:${label.startsWith("!") ? RED : "#8c8c8c"};font-weight:${label.startsWith("!") ? 700 : 400}">${esc(label.replace(/^!/, ""))}</div>`;
}
function grid(lang: Lang, items: Item[], cols: number, label: (i: Item) => string) {
  const w = Math.floor((500 - (cols - 1) * 12) / cols);
  const rows: string[] = [];
  for (let r = 0; r < items.length; r += cols) {
    const cells = items.slice(r, r + cols).map((i) => `<td width="${w}" valign="top" style="width:${w}px;vertical-align:top;padding:0 0 18px">${card(lang, i, label(i), w)}</td>`);
    while (cells.length < cols) cells.push(`<td width="${w}" style="width:${w}px">&nbsp;</td>`);
    rows.push(`<tr>${cells.join(`<td width="12" style="width:12px;font-size:0;line-height:0">&nbsp;</td>`)}</tr>`);
  }
  return `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${rows.join("")}</table></td></tr>`;
}
function popularList(lang: Lang, items: Item[]) {
  const rows = items.map((i, n) => {
    const url = titleUrl(i), p = img(i.poster, "w92");
    return `<tr><td width="34" valign="middle" style="width:34px;padding:6px 0;font-size:26px;line-height:30px;font-weight:900;color:#3a3a3a">${n + 1}</td>
<td width="46" valign="middle" style="width:46px;padding:6px 12px 6px 0">${p ? `<a href="${esc(url)}"><img src="${esc(p)}" width="46" alt="" style="display:block;width:46px;height:auto;border:0;border-radius:4px;background:#1f1f1f"></a>` : ""}</td>
<td valign="middle" style="padding:6px 0;border-bottom:1px solid #222222"><a href="${esc(url)}" style="font-size:15px;line-height:20px;font-weight:700;color:#ffffff;text-decoration:none">${esc(i.title)}</a><div style="font-size:12px;line-height:16px;color:#8c8c8c">${esc(kindYear(lang, i))}</div></td></tr>`;
  });
  return `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${rows.join("")}</table></td></tr>`;
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
  if (e.fresh.length) parts.push(sectionTitle(t.fresh), grid(o.lang, e.fresh, 3, (i) => kindYear(o.lang, i)));
  if (e.soon.length) parts.push(sectionTitle(t.soon), grid(o.lang, e.soon, 4, (i) => "!" + shortDate(o.lang, i.date)));
  if (e.popular.length) parts.push(sectionTitle(t.popular), popularList(o.lang, e.popular));
  if (!parts.length) parts.push(`<tr><td style="padding:18px 0 0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(t.empty)}</td></tr>`);
  const content = `${greeting(o.lang, o.firstName)}<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(t.eyebrow)}</div>
<h1 style="margin:8px 0 10px;font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(t.title)}</h1>
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(t.intro)}</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${parts.join("\n")}</table>
<p style="margin:24px 0 0;padding:14px 16px;background:#1f1f1f;border-radius:8px;font-size:13px;line-height:19px;color:#b3b3b3">${esc(t.honest)}</p>`;
  const [unsubQ, unsubA] = t.unsub.split("? ");
  const reasonHtml = `${esc(t.reason)}<br>${esc(unsubQ)}? <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(unsubA)}</a>`;
  const footer = footerHtml({ lang: o.lang, reasonHtml, year: o.year }) +
    `<br><span style="color:#5c5c5c;font-size:11px;line-height:16px">${esc(t.tmdb)} <a href="https://www.themoviedb.org" style="color:#737373">themoviedb.org</a></span>`;
  const titles = [e.featured, ...e.fresh].filter(Boolean).slice(0, 3).map((i) => i!.title);
  const subject = subjectOf(o.lang, e, o.preview);
  const html = layout({
    lang: o.lang, docTitle: subject, preheader: titles.length ? `${t.preheader}: ${titles.join(", ")}` : t.preheader,
    label: "", contentHtml: content, footerHtml: footer,
  });
  return { subject, html, text: textOf(o) };
}

/** Platte-tekstversie. */
export function textOf(o: RenderOpts): string {
  const t = TEXT[o.lang], e = o.edition, out: string[] = [];
  const g = greetingText(o.lang, o.firstName);
  if (g) out.push(g, "");
  out.push(t.title, "", t.intro, "");
  const line = (i: Item, extra = "") => `- ${i.title}${extra ? ` (${extra})` : ""}: ${titleUrl(i)}`;
  if (e.featured) out.push(`${t.featured}: ${e.featured.title} (${kindYear(o.lang, e.featured)})`, e.featured.overview, `${t.watch}: ${titleUrl(e.featured)}`, "");
  if (e.fresh.length) out.push(t.fresh, ...e.fresh.map((i) => line(i, kindYear(o.lang, i))), "");
  if (e.soon.length) out.push(t.soon, ...e.soon.map((i) => line(i, shortDate(o.lang, i.date))), "");
  if (e.popular.length) out.push(t.popular, ...e.popular.map((i, n) => `${n + 1}. ${i.title}: ${titleUrl(i)}`), "");
  out.push(t.honest, "", footerText({ lang: o.lang, reason: t.reason, year: o.year }), `${t.unsub}: ${o.unsubscribeUrl}`, t.tmdb);
  return out.filter((x, n, a) => !(x === "" && a[n - 1] === "")).join("\n");
}
