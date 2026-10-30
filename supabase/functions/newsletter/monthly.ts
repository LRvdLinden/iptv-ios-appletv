// Bingr maandoverzicht "Volgende maand op Bingr" / "Coming next month" (docs/NEWSLETTER.md, sectie Maandoverzicht): op de
// laatste dag van elke maand om 18:00 Europe/Amsterdam (ook bij zomer-/wintertijd) wat er de volgende maand nieuw komt:
// films in de bioscoop, nieuw op streaming en digitaal, nieuwe series en nieuwe seizoenen. Zelfde ontvangers, afmeldlink,
// verzending (newsletter_editions met kind = 'monthly', newsletter_deliveries) en opmaak (render.ts) als de nieuwsbrief.
// Planning, selectie en opmaak zijn puur (geen database), zodat alles met `deno test` te controleren is (monthly_test.ts).
import { esc, footerHtml, footerText, greeting, greetingText, layout } from "../_shared/layout.ts";
import {
  amsterdam, type GenreMap, GRACE_HOURS, interleave, type Item, type Kind, type Lang, ref, REGION, SHOW, titleUrl, TMDB_LANG, toItem,
  withGenre,
} from "./logic.ts";
import { featuredHtml, grid, sectionIntro, sectionTitle, scoreText, shortDate, shortTitle, TEXT, TITLE_MAX } from "./render.ts";
import { fetchGenres, pool, tmdbGet } from "./tmdb.ts";

// ---------- planning ----------

/** Lokaal uur (Europe/Amsterdam) op de laatste dag van de maand. */
export const MONTHLY_HOUR = 18;
const pad = (n: number) => String(n).padStart(2, "0");
/** yyyy-mm-dd + 1 dag (kalender, los van tijdzones). */
export const nextDay = (d: string) => new Date(Date.parse(`${d}T12:00:00Z`) + 86400_000).toISOString().slice(0, 10);
export const isLastDayOfMonth = (d: string) => nextDay(d).endsWith("-01");
/** "2026-10-31" -> "2026-11"; "2026-12-31" -> "2027-01". */
export function monthAfter(d: string): string {
  const y = Number(d.slice(0, 4)), m = Number(d.slice(5, 7));
  return m === 12 ? `${y + 1}-01` : `${y}-${pad(m + 1)}`;
}
/** Sleutel van een maandeditie: de maand waar hij over gaat, bv. "2026-11" (uniek in newsletter_editions). */
export const validMonth = (k: unknown): k is string => typeof k === "string" && /^\d{4}-(0[1-9]|1[0-2])$/.test(k);
/** Eerste en laatste dag van een maand ("2028-02" -> 2028-02-01 … 2028-02-29). */
export function monthRange(key: string): { first: string; last: string } {
  const y = Number(key.slice(0, 4)), m = Number(key.slice(5, 7));
  return { first: `${key}-01`, last: `${key}-${pad(new Date(Date.UTC(y, m, 0)).getUTCDate())}` };
}
export const inMonth = (d: string | null | undefined, key: string) => typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d) && d.slice(0, 7) === key;

/**
 * Moet de maandeditie nu (beginnen met) versturen? Alleen op de laatste dag van de maand om 18:00 lokale tijd (met
 * GRACE_HOURS speling als een ronde mislukt): dan {key: volgende maand, at}. pg_cron draait in UTC (elk uur); de functie
 * rekent zelf naar Europe/Amsterdam, dus 16:00 UTC in de zomer en 17:00 UTC in de winter. Eén keer per maand: de sleutel
 * is uniek in newsletter_editions.
 */
export function monthlyDue(ms: number): { key: string; at: string } | null {
  for (let back = 0; back <= GRACE_HOURS; back++) {
    const t = Math.floor(ms / 3600_000) * 3600_000 - back * 3600_000;
    const l = amsterdam(t);
    if (l.minute === 0 && l.hour === MONTHLY_HOUR && isLastDayOfMonth(l.date)) return { key: monthAfter(l.date), at: new Date(t).toISOString() };
  }
  return null;
}
/** Het volgende moment ná ms (strikt later): {key, at (ISO, UTC)}. */
export function nextMonthly(ms: number): { key: string; at: string } {
  let t = Math.floor(ms / 3600_000) * 3600_000 + 3600_000;
  for (let i = 0; i < 24 * 33; i++, t += 3600_000) {
    const l = amsterdam(t);
    if (l.minute === 0 && l.hour === MONTHLY_HOUR && isLastDayOfMonth(l.date)) return { key: monthAfter(l.date), at: new Date(t).toISOString() };
  }
  throw new Error("geen volgend moment");
}

// ---------- selectie (TMDB) ----------

export type MonthlyEdition = { month: string; featured: Item | null; cinema: Item[]; streaming: Item[]; series: Item[] };
export type MonthlyContent = Record<Lang, MonthlyEdition>;
/** Kandidaten per sectie (meer dan getoond, zodat er na het ontdubbelen genoeg overblijft). */
export const MONTHLY_LIMIT = 12;
/** TMDB-releasetypes: 2 = bioscoop (beperkt), 3 = bioscoop, 4 = digitaal, 5 = fysiek. */
export const CINEMA_TYPES = [2, 3], STREAMING_TYPES = [4, 5];
/** Geen nieuws, reality, soaps en talkshows (die hebben elke maand afleveringen). */
export const NO_TV_GENRES = "10763,10764,10766,10767";

/** TMDB-verzoeken voor de maand `key` ("2026-11"). */
export function monthlyQueries(lang: Lang, key: string) {
  const { first, last } = monthRange(key), language = TMDB_LANG[lang];
  const base = { language, include_adult: "false", sort_by: "popularity.desc", page: "1" };
  const movies = { ...base, region: REGION, "release_date.gte": first, "release_date.lte": last };
  return {
    cinema: ["/discover/movie", { ...movies, with_release_type: "2|3" }],
    streaming: ["/discover/movie", { ...movies, with_release_type: "4|5" }],
    newTv: ["/discover/tv", { ...base, "first_air_date.gte": first, "first_air_date.lte": last, without_genres: NO_TV_GENRES }],
    // series met een aflevering in de maand; of er een nieuw seizoen begint, staat in /tv/{id} (seasonStart)
    seasonTv: ["/discover/tv", { ...base, "air_date.gte": first, "air_date.lte": last, without_genres: NO_TV_GENRES }],
  } as const satisfies Record<string, readonly [string, Record<string, string>]>;
}

/** Vroegste Nederlandse releasedatum van een van de `types` in de maand (TMDB /movie/{id}/release_dates), of null. */
export function nlRelease(j: unknown, types: number[], key: string): string | null {
  const res = (j as { results?: unknown })?.results;
  let best: string | null = null;
  for (const c of Array.isArray(res) ? res : []) {
    if ((c as { iso_3166_1?: unknown })?.iso_3166_1 !== REGION) continue;
    const list = (c as { release_dates?: unknown }).release_dates;
    for (const r of Array.isArray(list) ? list : []) {
      const t = Number((r as { type?: unknown })?.type), d = String((r as { release_date?: unknown })?.release_date ?? "").slice(0, 10);
      if (!types.includes(t) || !inMonth(d, key)) continue;
      if (!best || d < best) best = d;
    }
  }
  return best;
}
/** Nieuw seizoen (nummer 2 of hoger) dat in de maand begint (TMDB /tv/{id}: seasons[].air_date), of null. */
export function seasonStart(j: unknown, key: string): { season: number; date: string } | null {
  const s = (j as { seasons?: unknown })?.seasons;
  let best: { season: number; date: string } | null = null;
  for (const x of Array.isArray(s) ? s : []) {
    const n = Number((x as { season_number?: unknown })?.season_number), d = String((x as { air_date?: unknown })?.air_date ?? "");
    if (!Number.isInteger(n) || n < 2 || n > 200 || !inMonth(d, key)) continue;
    if (!best || d < best.date) best = { season: n, date: d };
  }
  return best;
}

export type MonthlyLists = { cinema: Item[]; streaming: Item[]; newTv: Item[]; seasons: Item[] };
/**
 * Inhoud van één maandeditie: alleen titels met een datum in de maand, populairste eerst, per sectie max. MONTHLY_LIMIT
 * kandidaten, geen titel in twee secties (bioscoop gaat voor streaming). Uitgelicht: de eerste titel met achtergrond (en
 * liefst omschrijving), om en om uit bioscoop, streaming en series.
 */
export function buildMonthly(l: MonthlyLists, key: string): MonthlyEdition {
  const seen = new Set<string>();
  const take = (list: Item[]) => {
    const out: Item[] = [];
    for (const x of list) {
      if (out.length >= MONTHLY_LIMIT) break;
      if (!inMonth(x.date, key) || seen.has(ref(x))) continue;
      seen.add(ref(x));
      out.push(x);
    }
    return out;
  };
  const cinema = take(l.cinema), streaming = take(l.streaming), series = take(interleave(l.newTv, l.seasons));
  const all: Item[] = [];
  for (let i = 0; i < MONTHLY_LIMIT; i++) for (const x of [cinema[i], streaming[i], series[i]]) if (x) all.push(x);
  const featured = all.find((x) => x.backdrop && x.overview) ?? all.find((x) => x.backdrop) ?? null;
  return { month: key, featured, cinema, streaming, series };
}

/** Wat de mail toont (HTML, tekst, voorbeeld en testmail): per sectie max. 6 (3 × 2), geen titel twee keer, op datum. */
export function shownMonthly(e: MonthlyEdition): MonthlyEdition {
  const used = new Set<string>(e.featured ? [ref(e.featured)] : []);
  const take = (list: Item[] | undefined) => {
    const out: Item[] = [];
    for (const x of list ?? []) {
      if (out.length >= SHOW.perSection || used.has(ref(x))) continue;
      used.add(ref(x));
      out.push(x);
    }
    return out.sort((a, b) => (a.date ?? "").localeCompare(b.date ?? "") || a.title.localeCompare(b.title));
  };
  const cinema = take(e.cinema), streaming = take(e.streaming), series = take(e.series);
  return { ...e, cinema, streaming, series };
}

export function mapMonthly(e: MonthlyEdition, f: (i: Item) => Item): MonthlyEdition {
  return { ...e, featured: e.featured ? f(e.featured) : null, cinema: e.cinema.map(f), streaming: e.streaming.map(f), series: e.series.map(f) };
}
/** Engelse versie: dezelfde titels, Engelse titel en omschrijving (onbekend: zonder omschrijving, nooit Nederlandse tekst). */
export function translateMonthly(nl: MonthlyEdition, en: Item[][]): MonthlyEdition {
  const by = new Map<string, Item>();
  for (const l of en) for (const i of l) by.set(ref(i), i);
  return mapMonthly(nl, (i) => {
    const e = by.get(ref(i)), base = { ...i };
    delete base.genre;
    return e ? { ...base, title: e.title, overview: e.overview } : { ...base, overview: "" };
  });
}

type Fetch = typeof fetch;
async function list(q: readonly [string, Record<string, string>], key: string, kind: Kind, f: Fetch): Promise<Item[]> {
  const j = await tmdbGet(q[0], q[1], key, f);
  const res = Array.isArray(j?.results) ? j!.results as Record<string, unknown>[] : [];
  return res.map((r) => toItem(r, kind)).filter((x): x is Item => !!x);
}
/** Hoeveel kandidaten per lijst een detailverzoek krijgen (releasedatum in NL / begin van het seizoen). */
export const DETAIL_MAX = 16;

/**
 * Inhoud voor nl en en van de maand `key`. Films: de Nederlandse releasedatum (bioscoop 2|3, digitaal 4|5) uit
 * /movie/{id}/release_dates (TMDB-discover geeft de wereldwijde datum terug). Nieuwe seizoenen: series met een
 * aflevering in de maand (air_date) waarvan een seizoen 2+ in de maand begint (/tv/{id}). Genres per taal.
 */
export async function buildMonthlyContent(key: string, tmdbKey: string, f: Fetch = fetch): Promise<MonthlyContent> {
  if (!validMonth(key)) throw new Error("bad_month");
  const qn = monthlyQueries("nl", key), qe = monthlyQueries("en", key);
  const [nc, ns, nn, nse, ec, es, en, ese, gNl, gEn] = await Promise.all([
    list(qn.cinema, tmdbKey, "movie", f), list(qn.streaming, tmdbKey, "movie", f), list(qn.newTv, tmdbKey, "tv", f), list(qn.seasonTv, tmdbKey, "tv", f),
    list(qe.cinema, tmdbKey, "movie", f), list(qe.streaming, tmdbKey, "movie", f), list(qe.newTv, tmdbKey, "tv", f), list(qe.seasonTv, tmdbKey, "tv", f),
    fetchGenres("nl", tmdbKey, f), fetchGenres("en", tmdbKey, f),
  ]);
  // films: Nederlandse releasedatum per soort
  const movies = [...new Map([...nc.slice(0, DETAIL_MAX), ...ns.slice(0, DETAIL_MAX)].map((x) => [x.id, x])).values()];
  const rd = new Map<number, unknown>();
  await pool(movies, 5, async (x) => { rd.set(x.id, await tmdbGet(`/movie/${x.id}/release_dates`, {}, tmdbKey, f).catch(() => null)); });
  const dated = (xs: Item[], types: number[]) => xs.slice(0, DETAIL_MAX).flatMap((x) => {
    const j = rd.get(x.id);
    // verzoek mislukt: de datum uit discover als die in de maand valt
    const d = j ? nlRelease(j, types, key) : inMonth(x.date, key) ? x.date : null;
    return d ? [{ ...x, date: d }] : [];
  });
  // nieuwe seizoenen
  const fresh = new Set(nn.map(ref));
  const cand = nse.filter((x) => !fresh.has(ref(x)) && !inMonth(x.date, key)).slice(0, DETAIL_MAX);
  const seasons = (await pool(cand, 4, async (x): Promise<Item | null> => {
    const s = seasonStart(await tmdbGet(`/tv/${x.id}`, { language: TMDB_LANG.nl }, tmdbKey, f).catch(() => null), key);
    return s ? { ...x, date: s.date, season: s.season } : null;
  })).filter((x): x is Item => !!x);
  const nl = buildMonthly({ cinema: dated(nc, CINEMA_TYPES), streaming: dated(ns, STREAMING_TYPES), newTv: nn, seasons }, key);
  const enEd = translateMonthly(nl, [ec, es, en, ese]);
  const g = (m: GenreMap) => (i: Item) => withGenre(i, m);
  return { nl: mapMonthly(nl, g(gNl)), en: mapMonthly(enEd, g(gEn)) };
}

// ---------- opmaak ----------

const MONTH_NAMES: Record<Lang, string[]> = {
  nl: ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"],
  en: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
};
/** "2026-11" -> "november" / "November". */
export const monthName = (lang: Lang, key: string) => MONTH_NAMES[lang][Number(key.slice(5, 7)) - 1] ?? "";

type MT = {
  eyebrow: string; title: (m: string) => string; intro: string; cinema: string; streaming: string; series: string;
  cinemaIntro: string; streamingIntro: string; seriesIntro: string; from: (d: string) => string; season: (n: number) => string;
  reason: string; unsub: string; subject: (t: string, m: string) => string; subjectNone: (m: string) => string;
  preheader: (m: string) => string; empty: string;
};
export const MTEXT: Record<Lang, MT> = {
  nl: {
    eyebrow: "Volgende maand op Bingr", title: (m) => `Dit komt er in ${m}`,
    intro: "Welke films er volgende maand in de bioscoop komen, wat er nieuw verschijnt op streaming en digitaal, en welke series en nieuwe seizoenen beginnen.",
    cinema: "Films in de bioscoop", streaming: "Nieuw op streaming en digitaal", series: "Nieuwe series en nieuwe seizoenen",
    cinemaIntro: "Vanaf deze datum in de Nederlandse bioscoop.", streamingIntro: "Vanaf deze datum digitaal te huur, te koop of te streamen.",
    seriesIntro: "Nieuwe series en series met een nieuw seizoen.",
    from: (d) => `vanaf ${d}`, season: (n) => `seizoen ${n}`,
    reason: "Je krijgt dit maandoverzicht omdat je bent ingeschreven voor de nieuwsbrief van Bingr.",
    unsub: "Geen nieuwsbrief en maandoverzicht meer? Afmelden",
    subject: (t, m) => `Volgende maand op Bingr: ${t} en meer in ${m}`, subjectNone: (m) => `Volgende maand op Bingr: dit komt er in ${m}`,
    preheader: (m) => `Nieuw in ${m}`, empty: "Voor volgende maand zijn nog geen nieuwe titels bekend.",
  },
  en: {
    eyebrow: "Coming next month", title: (m) => `Coming in ${m}`,
    intro: "Which movies hit cinemas next month, what's new on streaming and digital, and which series and new seasons begin.",
    cinema: "In cinemas", streaming: "New on streaming and digital", series: "New series and new seasons",
    cinemaIntro: "In Dutch cinemas from this date.", streamingIntro: "Available digitally to rent, buy or stream from this date.",
    seriesIntro: "New series and series with a new season.",
    from: (d) => `from ${d}`, season: (n) => `season ${n}`,
    reason: "You're receiving this monthly overview because you're subscribed to the Bingr newsletter.",
    unsub: "Don't want the newsletter and monthly overview? Unsubscribe",
    subject: (t, m) => `Coming next month: ${t} and more in ${m}`, subjectNone: (m) => `Coming next month on Bingr: what's new in ${m}`,
    preheader: (m) => `New in ${m}`, empty: "No new titles are known for next month yet.",
  },
};

const kindOf = (lang: Lang, i: Item) => TEXT[lang][i.type === "tv" ? "tv" : "movie"];
/** "vanaf 14 nov · Drama" / "from Nov 14 · Drama" (zonder genre: soort). */
export function fromLabel(lang: Lang, i: Item): string {
  const d = shortDate(lang, i.date);
  return [d ? MTEXT[lang].from(d) : "", i.genre ?? kindOf(lang, i)].filter(Boolean).join(" · ");
}
/** Getoonde titel onder de poster: bij een nieuw seizoen met "· seizoen 3" (de titel zelf wordt dan korter afgekapt). */
export function cardTitle(lang: Lang, i: Item): string {
  if (!i.season) return shortTitle(i.title);
  const suffix = ` · ${MTEXT[lang].season(i.season)}`;
  return shortTitle(i.title, TITLE_MAX - suffix.length) + suffix;
}

export type MonthlyRenderOpts = { lang: Lang; edition: MonthlyEdition; firstName?: string; unsubscribeUrl: string; year?: number; preview?: boolean };

export function monthlySubject(lang: Lang, e: MonthlyEdition, preview = false) {
  const m = monthName(lang, e.month);
  return (preview ? "[Voorbeeld] " : "") + (e.featured ? MTEXT[lang].subject(e.featured.title, m) : MTEXT[lang].subjectNone(m));
}

/** De hele mail: {subject, html, text}. Uitgelicht (liggend), dan bioscoop, streaming en series in rasters van 3 × 2. */
export function renderMonthly(o: MonthlyRenderOpts): { subject: string; html: string; text: string } {
  const t = TEXT[o.lang], mt = MTEXT[o.lang], e = shownMonthly(o.edition), m = monthName(o.lang, e.month);
  const label = (i: Item) => fromLabel(o.lang, i);
  const opts = { red: true, titleOf: (i: Item) => cardTitle(o.lang, i) };
  const parts: string[] = [];
  if (e.featured) {
    const f = e.featured, d = shortDate(o.lang, f.date);
    const meta = [kindOf(o.lang, f), f.season ? mt.season(f.season) : "", d ? mt.from(d) : ""].filter(Boolean).join(" · ");
    parts.push(featuredHtml(o.lang, f, meta));
  }
  for (const [items, title, intro] of [[e.cinema, mt.cinema, mt.cinemaIntro], [e.streaming, mt.streaming, mt.streamingIntro], [e.series, mt.series, mt.seriesIntro]] as const) {
    if (items.length) parts.push(sectionTitle(title), sectionIntro(intro), grid(o.lang, items, label, opts));
  }
  if (!parts.length) parts.push(`<tr><td style="padding:18px 0 0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(mt.empty)}</td></tr>`);
  const content = `${greeting(o.lang, o.firstName)}<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(mt.eyebrow)}</div>
<h1 style="margin:8px 0 10px;font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(mt.title(m))}</h1>
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(mt.intro)}</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${parts.join("\n")}</table>
<p style="margin:24px 0 0;padding:14px 16px;background:#1f1f1f;border-radius:8px;font-size:13px;line-height:19px;color:#b3b3b3">${esc(t.honest)}</p>`;
  const [unsubQ, unsubA] = mt.unsub.split("? ");
  const reasonHtml = `${esc(mt.reason)}<br>${esc(unsubQ)}? <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(unsubA)}</a>`;
  const footer = footerHtml({ lang: o.lang, reasonHtml, year: o.year }) +
    `<br><span style="color:#5c5c5c;font-size:11px;line-height:16px">${esc(t.tmdb)}</span>`;
  const titles = [e.featured, ...e.cinema, ...e.streaming, ...e.series].filter(Boolean).slice(0, 3).map((i) => i!.title);
  const subject = monthlySubject(o.lang, e, o.preview);
  const html = layout({
    lang: o.lang, docTitle: subject, preheader: titles.length ? `${mt.preheader(m)}: ${titles.join(", ")}` : mt.preheader(m),
    label: "", contentHtml: content, footerHtml: footer,
  });
  return { subject, html, text: monthlyText(o) };
}

/** Platte-tekstversie. */
export function monthlyText(o: MonthlyRenderOpts): string {
  const t = TEXT[o.lang], mt = MTEXT[o.lang], e = shownMonthly(o.edition), m = monthName(o.lang, e.month), out: string[] = [];
  const g = greetingText(o.lang, o.firstName);
  if (g) out.push(g, "");
  out.push(mt.title(m), "", mt.intro, "");
  const line = (i: Item) => {
    const name = i.season ? `${i.title} (${mt.season(i.season)})` : i.title;
    const extra = [fromLabel(o.lang, i), scoreText(o.lang, i)].filter(Boolean).join(", ");
    return `- ${name}${extra ? ` (${extra})` : ""}: ${titleUrl(i)}`;
  };
  if (e.featured) out.push(`${t.featured}: ${line(e.featured).slice(2)}`, ...(e.featured.overview ? [e.featured.overview] : []), "");
  for (const [items, title] of [[e.cinema, mt.cinema], [e.streaming, mt.streaming], [e.series, mt.series]] as const) {
    if (items.length) out.push(title, ...items.map(line), "");
  }
  if (!e.featured && !e.cinema.length && !e.streaming.length && !e.series.length) out.push(mt.empty, "");
  out.push(t.honest, "", footerText({ lang: o.lang, reason: mt.reason, year: o.year }), `${mt.unsub}: ${o.unsubscribeUrl}`, t.tmdb);
  return out.filter((x, n, a) => !(x === "" && a[n - 1] === "")).join("\n");
}

/** Lege editie (bv. een oude rij zonder inhoud). */
export const emptyMonthly = (month: string): MonthlyEdition => ({ month, featured: null, cinema: [], streaming: [], series: [] });
export const monthlyFor = (c: Partial<MonthlyContent> | null | undefined, lang: Lang, month: string): MonthlyEdition =>
  c?.[lang] ?? c?.nl ?? emptyMonthly(month);
