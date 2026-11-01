// Bingr maandrecap "Jouw maand op Bingr" / "Your month on Bingr" (docs/NEWSLETTER.md, sectie Maandrecap): een persoonlijke
// mail op de 1e van de maand om 20:00 lokale tijd van het account over wat er de vorige maand gekeken is (zoals de "month in
// review" van Trakt). ALLEEN voor Lifetime-accounts (de statistieken horen bij Lifetime). Gegevens uit public.watch_month (supabase/schema.sql), opgeteld over de profielen. Zelfde ontvangers,
// afmeldlink en huisstijl als de nieuwsbrief; eigen wachtrij recap_deliveries (één mail per account en maand).
// Alles hier is puur (geen database, geen netwerk), zodat het met `deno test` te controleren is (recap_test.ts).
// Privacy: kijkgegevens komen nooit in logs; de functie logt alleen aantallen.
import { esc, footerHtml, footerText, greetingPara, layout, personName, RED } from "../_shared/layout.ts";
import { img, imgPath, type Lang, SITE, titleUrl } from "./logic.ts";
import { shortDate, shortTitle, TEXT } from "./render.ts";
import { monthName } from "./monthly.ts";

// ---------- planning ----------

/** Lokaal uur van de verzending op de 1e van de maand. */
export const RECAP_HOUR = 20;
/** Mislukt een ronde (storing, limiet), dan nog zoveel uur later op dezelfde dag (21:xx en 22:xx lokaal). */
export const RECAP_GRACE = 2;
export const DEFAULT_TZ = "Europe/Amsterdam";
const pad = (n: number) => String(n).padStart(2, "0");

const fmts = new Map<string, Intl.DateTimeFormat>();
/** Geldige IANA-tijdzone (zoals de apps die meesturen bij stream_start)? */
export function validTz(tz: unknown): tz is string {
  if (typeof tz !== "string" || !tz || tz.length > 64 || !/^[A-Za-z0-9_+\-/]+$/.test(tz)) return false;
  try { fmtFor(tz); return true; } catch { return false; }
}
function fmtFor(tz: string): Intl.DateTimeFormat {
  let f = fmts.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", weekday: "short", hourCycle: "h23" });
    fmts.set(tz, f);
  }
  return f;
}
const DOW: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
export type LocalTime = { date: string; day: number; hour: number; minute: number; dow: number };
/** Lokale datum en tijd in een tijdzone (onbekend: Europe/Amsterdam). */
export function localIn(ms: number, tz: string): LocalTime {
  const p: Record<string, string> = {};
  for (const x of fmtFor(validTz(tz) ? tz : DEFAULT_TZ).formatToParts(new Date(ms))) p[x.type] = x.value;
  return { date: `${p.year}-${p.month}-${p.day}`, day: Number(p.day), hour: Number(p.hour) % 24, minute: Number(p.minute), dow: DOW[p.weekday] ?? 0 };
}

/** Land -> tijdzone (landen met meer zones: de grootste stad). Alleen voor accounts zonder tijdzone van de app. */
export const COUNTRY_TZ: Record<string, string> = {
  NL: "Europe/Amsterdam", BE: "Europe/Brussels", LU: "Europe/Luxembourg", DE: "Europe/Berlin", FR: "Europe/Paris", ES: "Europe/Madrid",
  IT: "Europe/Rome", AT: "Europe/Vienna", CH: "Europe/Zurich", GB: "Europe/London", IE: "Europe/Dublin", PT: "Europe/Lisbon",
  DK: "Europe/Copenhagen", SE: "Europe/Stockholm", NO: "Europe/Oslo", FI: "Europe/Helsinki", PL: "Europe/Warsaw", CZ: "Europe/Prague",
  SK: "Europe/Bratislava", HU: "Europe/Budapest", RO: "Europe/Bucharest", BG: "Europe/Sofia", GR: "Europe/Athens", HR: "Europe/Zagreb",
  SI: "Europe/Ljubljana", RS: "Europe/Belgrade", TR: "Europe/Istanbul", UA: "Europe/Kyiv", MA: "Africa/Casablanca", ZA: "Africa/Johannesburg",
  SR: "America/Paramaribo", CW: "America/Curacao", AW: "America/Aruba", BQ: "America/Kralendijk", SX: "America/Lower_Princes",
  US: "America/New_York", CA: "America/Toronto", MX: "America/Mexico_City", BR: "America/Sao_Paulo", AR: "America/Argentina/Buenos_Aires",
  AU: "Australia/Sydney", NZ: "Pacific/Auckland", IN: "Asia/Kolkata", ID: "Asia/Jakarta", AE: "Asia/Dubai", IL: "Asia/Jerusalem",
  JP: "Asia/Tokyo", CN: "Asia/Shanghai", TH: "Asia/Bangkok", PH: "Asia/Manila", SG: "Asia/Singapore",
};
/** Tijdzone van een account: die van de app (watch_month.tz), anders afgeleid uit het land, anders Europe/Amsterdam. */
export function recapTz(tz?: string | null, country?: string | null): string {
  if (validTz(tz)) return tz;
  const c = typeof country === "string" ? COUNTRY_TZ[country.toUpperCase()] : undefined;
  return c && validTz(c) ? c : DEFAULT_TZ;
}

/** "2026-11-01" -> "2026-10"; "2027-01-01" -> "2026-12". */
export function monthBefore(date: string): string {
  const y = Number(date.slice(0, 4)), m = Number(date.slice(5, 7));
  return m === 1 ? `${y - 1}-12` : `${y}-${pad(m - 1)}`;
}
export const validMonthKey = (k: unknown): k is string => typeof k === "string" && /^\d{4}-(0[1-9]|1[0-2])$/.test(k);

/**
 * Moet dit account nu zijn recap krijgen? Alleen op de 1e van de maand tussen 20:00 en 22:59 lokale tijd (20:xx, plus
 * RECAP_GRACE uur speling voor een mislukte ronde): dan de maand waar hij over gaat ("2026-10"), anders null.
 * pg_cron draait elk uur op minuut 0 UTC, dus in Amsterdam om 20:00 (19:00 UTC in de winter, 18:00 UTC in de zomer).
 */
export function recapDue(ms: number, tz: string): string | null {
  const l = localIn(ms, tz);
  if (l.day !== 1 || l.hour < RECAP_HOUR || l.hour > RECAP_HOUR + RECAP_GRACE) return null;
  return monthBefore(l.date);
}
/**
 * Eerste maand waarover een recap gaat. Oktober 2026 is maar deels bijgehouden (statistieken sinds 6/13 oktober, de
 * maandaggregatie pas sinds build 158) en een verzending op 1 november zou ongevraagd meteen na de deploy gaan; daarom is de
 * eerste recap die over november 2026, op dinsdag 1 december 2026 om 20:00 lokale tijd.
 */
export const RECAP_FIRST_MONTH = "2026-11";
/** Voor welke maanden kan er nu (in een tijdzone van UTC-12 tot UTC+14) een recap verstuurd worden? Leeg = niets te doen. */
export function recapMonthsNow(ms: number): string[] {
  const out = new Set<string>();
  for (let off = -12 * 60; off <= 14 * 60; off += 15) {
    const d = new Date(ms + off * 60_000);
    const h = d.getUTCHours();
    const m = monthBefore(d.toISOString().slice(0, 10));
    if (d.getUTCDate() === 1 && h >= RECAP_HOUR && h <= RECAP_HOUR + RECAP_GRACE && m >= RECAP_FIRST_MONTH) out.add(m);
  }
  return [...out].sort();
}
/** De volgende verzending (1e van de maand 20:00) in een tijdzone, strikt na ms: {key (maand waar hij over gaat), at (UTC)}. */
export function nextRecap(ms: number, tz = DEFAULT_TZ): { key: string; at: string } {
  let t = Math.floor(ms / 60_000) * 60_000 + 60_000;
  // per uur zoeken, dan het precieze moment (ook bij een zone met halve uren)
  for (let i = 0; i < 24 * 400; i++, t += 3600_000) {
    const l = localIn(t, tz);
    if (l.day === 1 && l.hour === RECAP_HOUR) {
      const exact = t - l.minute * 60_000;
      if (exact > ms && monthBefore(l.date) >= RECAP_FIRST_MONTH) return { key: monthBefore(l.date), at: new Date(exact).toISOString() };
    }
  }
  throw new Error("geen volgend moment");
}
/** Bewaren: 13 maanden (de lopende maand en de 12 ervoor, in UTC), zoals public.bingr_watch_month_cutoff. */
export function retainFrom(ms: number): string {
  const d = new Date(ms), y = d.getUTCFullYear(), m = d.getUTCMonth() + 1 - 12;
  const yy = m <= 0 ? y - 1 : y, mm = m <= 0 ? m + 12 : m;
  return `${yy}-${pad(mm)}`;
}
export const kept = (month: string, ms: number) => month >= retainFrom(ms);

/** Instellingen uit newsletter_settings: show_recap (standaard aan). De recap is altijd alleen voor Lifetime. */
export type RecapSettings = { enabled: boolean; audience: "lifetime" };
export const recapSettingsOf = (row: Record<string, unknown> | null | undefined): RecapSettings =>
  ({ enabled: row?.show_recap !== false, audience: "lifetime" });
/** Alleen Lifetime krijgt een recap (de statistieken horen bij Lifetime); zelfde regel als bingr_recap_candidates. */
export const recapAllowed = (plan: unknown) => plan === "lifetime";

// ---------- gegevens ----------

/** Eén rij uit bingr_recap_rows (titels en labels al ontsleuteld). */
export type RecapRow = {
  kind: "movie" | "episode" | "live"; item_key: string; title: string | null; plays: number; minutes: number; episodes: number;
  first_at: string; last_at: string; first_label?: string | null; last_label?: string | null;
  tmdb_id?: number | null; poster?: string | null; backdrop?: string | null; approx?: boolean;
};
export type RecapTitle = {
  type: "movie" | "tv"; key: string; title: string; plays: number; minutes: number; episodes: number;
  tmdbId?: number; year?: number | null; poster?: string | null; backdrop?: string | null;
  /** eerste/laatste keer (ISO), alleen bij Eerste en Laatste titel; approx = alleen de dag is zeker */
  at?: string; approx?: boolean;
  /** aflevering (uit de streamtitel): seizoen, nummer en naam */
  season?: number; episode?: number; episodeName?: string;
};
export type Recap = {
  month: string; tz: string;
  totals: { episodes: number; movies: number; minutes: number };
  hero: RecapTitle | null; first: RecapTitle | null; last: RecapTitle | null;
  series: RecapTitle[]; movies: RecapTitle[];
  channel: { title: string; minutes: number } | null;
  upNext: RecapTitle | null;
};
export const TOP = 3;

/** "Serie · S1:E2 · Naam", "Serie S01E02", "Serie - S1E2 - Naam" -> {season, episode, name?}; anders null. */
export function parseEpisode(label: string | null | undefined): { season: number; episode: number; name?: string } | null {
  if (typeof label !== "string") return null;
  const m = /S(\d{1,3})\s*[:.]?\s*E(\d{1,4})(?![A-Za-z0-9])/i.exec(label);
  if (!m) return null;
  const season = Number(m[1]), episode = Number(m[2]);
  if (!(season >= 0 && season < 500 && episode > 0 && episode < 5000)) return null;
  const rest = label.slice(m.index + m[0].length).replace(/^\s*[-–:|·]+\s*/, "").trim();
  const name = cleanText(rest, 80);
  return name && !/^S\d/i.test(name) ? { season, episode, name } : { season, episode };
}
const cleanText = (s: unknown, max: number) => {
  const v = String(s ?? "").replace(/[\u0000-\u001f\u007f<>]/g, " ").replace(/\s+/g, " ").trim();
  return Array.from(v).slice(0, max).join("").trim();
};
/** Weergavenaam van een titel uit de bron: "NL - The Bear (2022) [4K]" -> {title: "The Bear", year: 2022}. */
export function cleanTitle(raw: string | null | undefined): { title: string; year: number | null } {
  let s = cleanText(raw, 200).split(" · ")[0];
  s = s.replace(/^\s*(\|[A-Z]{2,3}\||\[[A-Z]{2,3}\]|[A-Z]{2,3}\s*[-:|])\s*/, "");
  s = s.replace(/\s*[[(](?:4K|UHD|FHD|HD|SD|HEVC|H\.?26[45]|1080p|720p|2160p|MULTI|NL|EN|SUB|DUB)[^\])]*[\])]\s*/gi, " ");
  s = s.replace(/\s+(?:4K|UHD|FHD|HEVC|1080p|720p|2160p)\b/gi, "");
  let year: number | null = null;
  const y = /\s*[([]?((?:19|20)\d{2})[)\]]?\s*$/.exec(s);
  if (y && s.length - y[0].length >= 2) { year = Number(y[1]); s = s.slice(0, y.index); }
  s = s.replace(/\s*[-–:|]+\s*$/, "").trim();
  return { title: s || cleanText(raw, 120), year };
}

const toTitle = (r: RecapRow): RecapTitle => {
  const c = cleanTitle(r.title), out: RecapTitle = {
    type: r.kind === "movie" ? "movie" : "tv", key: `${r.kind}:${r.item_key}`, title: c.title, year: c.year,
    plays: Math.max(0, Math.round(Number(r.plays) || 0)), minutes: Math.max(0, Number(r.minutes) || 0), episodes: Math.max(0, Math.round(Number(r.episodes) || 0)),
  };
  const id = Number(r.tmdb_id);
  if (Number.isInteger(id) && id > 0) out.tmdbId = id;
  if (imgPath(r.poster)) out.poster = r.poster;
  if (imgPath(r.backdrop)) out.backdrop = r.backdrop;
  return out;
};
const withEpisode = (t: RecapTitle, label: string | null | undefined): RecapTitle => {
  if (t.type !== "tv") return t;
  const e = parseEpisode(label);
  return e ? { ...t, season: e.season, episode: e.episode, ...(e.name ? { episodeName: e.name } : {}) } : t;
};
const ms = (iso: string) => { const n = Date.parse(iso); return Number.isFinite(n) ? n : 0; };

/**
 * De recap van één maand uit de rijen van bingr_recap_rows. null = niets gekeken (minder dan 1 minuut in totaal): dan geen
 * mail. Live tv telt mee in de minuten, maar niet in de toplijsten en niet als eerste/laatste titel; alleen "meest gekeken
 * zender". Toplijsten: max. TOP, meeste kijktijd eerst (bij gelijke tijd: vaakst gestart, dan titel).
 */
export function buildRecap(rows: RecapRow[], month: string, tz: string): Recap | null {
  const live = rows.filter((r) => r.kind === "live" && Number(r.minutes) >= 1 && r.title);
  const vod = rows.filter((r) => (r.kind === "movie" || r.kind === "episode") && Number(r.minutes) >= 1 && cleanTitle(r.title).title);
  const minutes = rows.reduce((s, r) => s + Math.max(0, Number(r.minutes) || 0), 0);
  if (minutes < 1 || (!vod.length && !live.length)) return null;
  const by = (a: RecapRow, b: RecapRow) => Number(b.minutes) - Number(a.minutes) || Number(b.plays) - Number(a.plays) || String(a.title).localeCompare(String(b.title));
  const series = vod.filter((r) => r.kind === "episode").sort(by);
  const movies = vod.filter((r) => r.kind === "movie").sort(by);
  const episodes = series.reduce((s, r) => s + (Number(r.episodes) > 0 ? Number(r.episodes) : Math.max(1, Number(r.plays) || 0)), 0);
  const firstRow = [...vod].sort((a, b) => ms(a.first_at) - ms(b.first_at))[0];
  const lastRow = [...vod].sort((a, b) => ms(b.last_at) - ms(a.last_at))[0];
  const first = firstRow ? { ...withEpisode(toTitle(firstRow), firstRow.first_label), at: firstRow.first_at, approx: !!firstRow.approx } : null;
  const last = lastRow ? { ...withEpisode(toTitle(lastRow), lastRow.last_label), at: lastRow.last_at, approx: !!lastRow.approx } : null;
  // volgende aflevering: van de laatst gekeken serie, als de aflevering bekend is (de naam vult TMDB in)
  const lastSeries = [...series].sort((a, b) => ms(b.last_at) - ms(a.last_at))[0];
  const le = lastSeries ? parseEpisode(lastSeries.last_label) : null;
  const upNext = lastSeries && le ? { ...toTitle(lastSeries), season: le.season, episode: le.episode + 1 } : null;
  const ch = [...live].sort(by)[0];
  const top = [...series.slice(0, 1), ...movies.slice(0, 1)].sort(by)[0];
  return {
    month, tz,
    totals: { episodes, movies: movies.length, minutes: Math.round(minutes) },
    hero: top ? toTitle(top) : null, first, last,
    series: series.slice(0, TOP).map(toTitle), movies: movies.slice(0, TOP).map(toTitle),
    channel: ch ? { title: cleanTitle(ch.title).title, minutes: Math.round(Number(ch.minutes)) } : null,
    upNext,
  };
}

/** Alle titels in de recap (voor TMDB), zonder dubbele. */
export function recapTitles(r: Recap): RecapTitle[] {
  const seen = new Map<string, RecapTitle>();
  for (const t of [r.hero, r.first, r.last, r.upNext, ...r.series, ...r.movies]) if (t && !seen.has(t.key)) seen.set(t.key, t);
  return [...seen.values()];
}
/** TMDB-gegevens (id, jaar, poster, achtergrond, eventueel de TMDB-titel) per sleutel overal in de recap toepassen. */
export function applyMeta(r: Recap, meta: Map<string, Partial<RecapTitle>>, next?: { name?: string; season?: number; episode?: number } | null): Recap {
  const f = (t: RecapTitle | null): RecapTitle | null => (t ? { ...t, ...(meta.get(t.key) ?? {}) } : null);
  const upNext = r.upNext && next !== null ? f(r.upNext) : null;
  return {
    ...r, hero: f(r.hero), first: f(r.first), last: f(r.last), series: r.series.map((t) => f(t)!), movies: r.movies.map((t) => f(t)!),
    upNext: upNext ? { ...upNext, ...(next?.season ? { season: next.season, episode: next.episode } : {}), ...(next?.name ? { episodeName: next.name } : {}) } : null,
  };
}

// ---------- opmaak ----------

type RT = {
  eyebrow: string; title: (m: string, y: string) => string; intro: (m: string) => string;
  episodes: string; movies: string; hours: string; hoursNote: string;
  first: (m: string) => string; last: (m: string) => string; upNext: string; series: string; films: string; channel: string;
  plays: (n: number) => string; eps: (n: number) => string; season: (s: number, e: number) => string;
  reason: string; unsub: string; subject: (m: string) => string; preheader: (m: string, h: string) => string; sample: string;
};
export const RTEXT: Record<Lang, RT> = {
  nl: {
    eyebrow: "Jouw maand op Bingr", title: (m, y) => `Jouw ${m} ${y}`, intro: (m) => `Zo zag jouw ${m} op Bingr eruit.`,
    episodes: "afleveringen", movies: "films", hours: "uur gekeken", hoursNote: "Uren inclusief live tv.",
    first: (m) => `Je eerste titel van ${m}`, last: (m) => `Je laatste titel van ${m}`, upNext: "Volgende aflevering",
    series: "Meest bekeken series", films: "Meest bekeken films", channel: "Meest gekeken zender",
    plays: (n) => `${n} keer`, eps: (n) => `${n} ${n === 1 ? "aflevering" : "afleveringen"}`, season: (s, e) => `S${s} · A${e}`,
    reason: "Je krijgt deze maandrecap omdat je bent ingeschreven voor de nieuwsbrief van Bingr. Alleen jij krijgt deze mail; de gegevens komen uit je eigen kijkstatistieken.",
    unsub: "Geen nieuwsbrief en maandrecap meer? Afmelden",
    subject: (m) => `Jouw ${m} op Bingr`, preheader: (m, h) => `${h} gekeken in ${m}: je toptitels, je eerste en je laatste.`,
    sample: "Voorbeeld met voorbeeldgegevens",
  },
  en: {
    eyebrow: "Your month on Bingr", title: (m, y) => `Your ${m} ${y}`, intro: (m) => `Here's what your ${m} on Bingr looked like.`,
    episodes: "episodes", movies: "movies", hours: "hours watched", hoursNote: "Hours include live TV.",
    first: (m) => `Your first title of ${m}`, last: (m) => `Your last title of ${m}`, upNext: "Up next",
    series: "Most watched series", films: "Most watched movies", channel: "Most watched channel",
    plays: (n) => `${n} ${n === 1 ? "play" : "plays"}`, eps: (n) => `${n} ${n === 1 ? "episode" : "episodes"}`, season: (s, e) => `S${s} · E${e}`,
    reason: "You're receiving this monthly recap because you're subscribed to the Bingr newsletter. Only you receive this email; the data comes from your own viewing statistics.",
    unsub: "Don't want the newsletter and monthly recap? Unsubscribe",
    subject: (m) => `Your ${m} on Bingr`, preheader: (m, h) => `${h} watched in ${m}: your top titles, your first and your last.`,
    sample: "Preview with sample data",
  },
};

/** "45 min", "9 u 34 min" / "9h 34m". */
export function duration(lang: Lang, minutes: number): string {
  const m = Math.max(0, Math.round(minutes)), h = Math.floor(m / 60), r = m % 60;
  if (lang === "nl") return h ? (r ? `${h} u ${r} min` : `${h} u`) : `${m} min`;
  return h ? (r ? `${h}h ${r}m` : `${h}h`) : `${m}m`;
}
/** Uren in de tegel: "3,5" (onder de 10, één decimaal) of "42"; nl met komma. */
export function hoursText(lang: Lang, minutes: number): string {
  const h = minutes / 60;
  const s = h < 10 ? (Math.round(h * 10) / 10).toFixed(1).replace(/\.0$/, "") : String(Math.round(h));
  return lang === "nl" ? s.replace(".", ",") : s;
}
const DAYS: Record<Lang, string[]> = { nl: ["zo", "ma", "di", "wo", "do", "vr", "za"], en: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] };
/** "zo 4 okt · 20:14" / "Sun Oct 4 · 20:14" in de tijdzone van het account; approx = alleen de dag. */
export function whenText(lang: Lang, iso: string | undefined, tz: string, approx = false): string {
  if (!iso || !ms(iso)) return "";
  const l = localIn(ms(iso), tz), d = `${DAYS[lang][l.dow]} ${shortDate(lang, l.date)}`;
  return approx ? d : `${d} · ${pad(l.hour)}:${pad(l.minute)}`;
}
/** Link naar de titel in Bingr (universele link); zonder TMDB-id zoekt bingr.online/titel/ op titel (+ jaar). */
export function recapUrl(t: RecapTitle): string {
  if (t.tmdbId) return titleUrl({ type: t.type, id: t.tmdbId, title: t.title, year: t.year ?? null });
  const p = new URLSearchParams({ type: t.type, q: t.title });
  if (t.year && t.year > 1800 && t.year < 3000) p.set("y", String(t.year));
  return `${SITE}/titel/?${p.toString().replace(/\+/g, "%20")}`;
}
const episodeLine = (lang: Lang, t: RecapTitle) =>
  t.season !== undefined && t.episode ? [RTEXT[lang].season(t.season, t.episode), t.episodeName ?? ""].filter(Boolean).join(" · ") : "";

// Covers: overal dezelfde staande TMDB-poster w342 met width="156" height="234" (zoals de nieuwsbrief), alt = titel.
const POSTER_W = 156, POSTER_H = 234;
function poster(t: RecapTitle) {
  const p = img(t.poster ?? null, "w342");
  return p
    ? `<img src="${esc(p)}" width="${POSTER_W}" height="${POSTER_H}" alt="${esc(t.title)}" style="display:block;width:100%;max-width:${POSTER_W}px;height:auto;aspect-ratio:2/3;object-fit:cover;border:0;outline:none;text-decoration:none;border-radius:6px;background:#1f1f1f">`
    : `<div role="img" aria-label="${esc(t.title)}" style="width:100%;max-width:${POSTER_W}px;height:${POSTER_H}px;border-radius:6px;background:#1f1f1f">&nbsp;</div>`;
}
const section = (s: string) =>
  `<tr><td style="padding:30px 0 12px"><div style="font-size:18px;line-height:24px;font-weight:800;color:#ffffff">${esc(s)}</div><div style="height:3px;width:36px;background:${RED};border-radius:2px;margin-top:6px;font-size:0;line-height:0">&nbsp;</div></td></tr>`;

/** Eén titel met poster links en tekst rechts (Eerste titel, Volgende aflevering, Laatste titel). */
function rowCard(lang: Lang, t: RecapTitle, lines: string[]) {
  const url = recapUrl(t);
  return `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
<td width="${POSTER_W}" valign="top" style="width:${POSTER_W}px;vertical-align:top"><a href="${esc(url)}" style="display:block;text-decoration:none">${poster(t)}</a></td>
<td width="18" style="width:18px;font-size:0;line-height:0">&nbsp;</td>
<td valign="top" style="vertical-align:top;padding:4px 0 0">
<div style="font-size:18px;line-height:24px;font-weight:800;color:#ffffff;word-break:break-word"><a href="${esc(url)}" style="color:#ffffff;text-decoration:none">${esc(shortTitle(t.title, 60))}</a></div>
${lines.filter(Boolean).map((l, i) => `<div style="margin:${i ? 4 : 8}px 0 0;font-size:14px;line-height:20px;color:${i ? "#b3b3b3" : RED};font-weight:${i ? 400 : 700}">${esc(l)}</div>`).join("\n")}
</td></tr></table></td></tr>`;
}
/** Top 3: posters naast elkaar (3 kolommen van 156 + 2 × 16 = 500 px), onder elke poster titel, aantal keer en kijktijd. */
function topGrid(lang: Lang, list: RecapTitle[], tv: boolean) {
  const cols = 3, colPct = "31.2%", gapPct = "3.2%";
  const cells = list.slice(0, cols).map((t, i) => {
    const url = recapUrl(t), rt = RTEXT[lang];
    const meta = [tv && t.episodes ? rt.eps(t.episodes) : rt.plays(t.plays), duration(lang, t.minutes)].join(" · ");
    return `<td width="${colPct}" valign="top" style="width:${colPct};vertical-align:top;padding:0 0 18px"><a href="${esc(url)}" style="display:block;text-decoration:none;color:#ffffff">${poster(t)}</a>
<div style="padding:8px 0 0;max-height:32px;overflow:hidden;font-size:12px;line-height:16px;font-weight:700;color:#ffffff;word-break:break-word"><a href="${esc(url)}" style="color:#ffffff;text-decoration:none"><span style="color:${RED};font-weight:900">${i + 1}</span>&nbsp; ${esc(shortTitle(t.title))}</a></div>
<div style="font-size:11px;line-height:16px;color:#8c8c8c">${esc(meta)}</div>
${tv && t.episodes ? `<div style="font-size:11px;line-height:16px;color:#8c8c8c">${esc(rt.plays(t.plays))}</div>` : ""}</td>`;
  });
  while (cells.length < cols) cells.push(`<td width="${colPct}" style="width:${colPct};font-size:0;line-height:0">&nbsp;</td>`);
  const gap = `<td width="${gapPct}" style="width:${gapPct};font-size:0;line-height:0">&nbsp;</td>`;
  return `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;table-layout:fixed"><tr>${cells.join(gap)}</tr></table></td></tr>`;
}
function tiles(lang: Lang, r: Recap) {
  const rt = RTEXT[lang], nf = (n: number) => n.toLocaleString(lang === "nl" ? "nl-NL" : "en-US");
  const tile = (v: string, label: string) =>
    `<td width="32%" valign="top" bgcolor="#1f1f1f" style="width:32%;background:#1f1f1f;border-radius:8px;padding:14px 8px;text-align:center;vertical-align:top"><div style="font-size:28px;line-height:34px;font-weight:900;color:#ffffff">${esc(v)}</div><div style="font-size:12px;line-height:16px;color:#b3b3b3">${esc(label)}</div></td>`;
  const gap = `<td width="2%" style="width:2%;font-size:0;line-height:0">&nbsp;</td>`;
  return `<tr><td style="padding:22px 0 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;table-layout:fixed"><tr>${
    [tile(nf(r.totals.episodes), rt.episodes), tile(nf(r.totals.movies), rt.movies), tile(hoursText(lang, r.totals.minutes), rt.hours)].join(gap)
  }</tr></table><div style="padding:8px 0 0;font-size:11px;line-height:16px;color:#737373">${esc(rt.hoursNote)}</div></td></tr>`;
}

export type RecapRenderOpts = { lang: Lang; recap: Recap; name?: string; unsubscribeUrl: string; year?: number; preview?: boolean; sample?: boolean };
/** Aanhef: voornaam, anders de weergavenaam, anders zonder naam. */
export const recapName = (first?: string | null, display?: string | null) => personName(first) || personName(display) || undefined;

export function recapSubject(lang: Lang, r: Recap, preview = false) {
  return (preview ? "[Voorbeeld] " : "") + RTEXT[lang].subject(monthName(lang, r.month));
}

/** De hele mail: {subject, html, text}. */
export function renderRecap(o: RecapRenderOpts): { subject: string; html: string; text: string } {
  const lang = o.lang, rt = RTEXT[lang], r = o.recap, m = monthName(lang, r.month), y = r.month.slice(0, 4);
  const parts: string[] = [tiles(lang, r)];
  if (r.first) parts.push(section(rt.first(m)), rowCard(lang, r.first, [episodeLine(lang, r.first), whenText(lang, r.first.at, r.tz, r.first.approx)]));
  if (r.series.length) parts.push(section(rt.series), topGrid(lang, r.series, true));
  if (r.movies.length) parts.push(section(rt.films), topGrid(lang, r.movies, false));
  if (r.last) parts.push(section(rt.last(m)), rowCard(lang, r.last, [episodeLine(lang, r.last), whenText(lang, r.last.at, r.tz, r.last.approx)]));
  if (r.upNext) parts.push(section(rt.upNext), rowCard(lang, r.upNext, [episodeLine(lang, r.upNext)]));
  if (r.channel) {
    parts.push(`<tr><td style="padding:24px 0 0;font-size:13px;line-height:19px;color:#b3b3b3">${esc(rt.channel)}: <b style="color:#ffffff">${esc(shortTitle(r.channel.title, 50))}</b> · ${esc(duration(lang, r.channel.minutes))}</td></tr>`);
  }
  const hero = r.hero && imgPath(r.hero.backdrop) ? r.hero : null;
  const heroHtml = hero
    ? `<a href="${esc(recapUrl(hero))}" style="display:block;text-decoration:none;margin:0 0 22px"><img src="${esc(img(hero.backdrop!, "w780")!)}" width="500" height="281" alt="${esc(hero.title)}" style="display:block;width:100%;max-width:500px;height:auto;aspect-ratio:16/9;object-fit:cover;border:0;border-radius:8px;background:#1f1f1f"></a>`
    : "";
  const sampleNote = o.sample ? `<p style="margin:0 0 14px;padding:8px 12px;background:#2a2a2a;border-radius:6px;font-size:12px;line-height:17px;color:#d6d6d6">${esc(rt.sample)}</p>` : "";
  const name = personName(o.name);
  const content = `${sampleNote}${heroHtml}<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(rt.eyebrow)}</div>
<h1 style="margin:8px 0 10px;font-size:26px;line-height:32px;font-weight:900;color:#ffffff">${esc(rt.title(m, y))}</h1>
${name ? greetingPara(esc(`${lang === "nl" ? "Hoi" : "Hi"} ${name},`)) : ""}<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(rt.intro(m))}</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${parts.join("\n")}</table>`;
  const [unsubQ, unsubA] = rt.unsub.split("? ");
  const reasonHtml = `${esc(rt.reason)}<br>${esc(unsubQ)}? <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(unsubA)}</a>`;
  const footer = footerHtml({ lang, reasonHtml, year: o.year }) + `<br><span style="color:#5c5c5c;font-size:11px;line-height:16px">${esc(TEXT[lang].tmdb)}</span>`;
  const subject = recapSubject(lang, r, o.preview);
  const html = layout({
    lang, docTitle: subject, preheader: rt.preheader(m, `${hoursText(lang, r.totals.minutes)} ${lang === "nl" ? "uur" : "hours"}`),
    label: "", contentHtml: content, footerHtml: footer,
  });
  return { subject, html, text: recapText(o) };
}

/** Platte-tekstversie. */
export function recapText(o: RecapRenderOpts): string {
  const lang = o.lang, rt = RTEXT[lang], r = o.recap, m = monthName(lang, r.month), out: string[] = [];
  const name = personName(o.name);
  if (o.sample) out.push(`[${rt.sample}]`, "");
  out.push(rt.title(m, r.month.slice(0, 4)), "");
  if (name) out.push(`${lang === "nl" ? "Hoi" : "Hi"} ${name},`, "");
  out.push(rt.intro(m), "", `${r.totals.episodes} ${rt.episodes} · ${r.totals.movies} ${rt.movies} · ${hoursText(lang, r.totals.minutes)} ${rt.hours} (${rt.hoursNote})`, "");
  const one = (t: RecapTitle, extra: string[]) => `${t.title}${extra.filter(Boolean).length ? ` (${extra.filter(Boolean).join(", ")})` : ""}: ${recapUrl(t)}`;
  if (r.first) out.push(`${rt.first(m)}: ${one(r.first, [episodeLine(lang, r.first), whenText(lang, r.first.at, r.tz, r.first.approx)])}`, "");
  const top = (list: RecapTitle[], tv: boolean) => list.map((t, i) => `${i + 1}. ${one(t, [tv && t.episodes ? rt.eps(t.episodes) : "", rt.plays(t.plays), duration(lang, t.minutes)])}`);
  if (r.series.length) out.push(rt.series, ...top(r.series, true), "");
  if (r.movies.length) out.push(rt.films, ...top(r.movies, false), "");
  if (r.last) out.push(`${rt.last(m)}: ${one(r.last, [episodeLine(lang, r.last), whenText(lang, r.last.at, r.tz, r.last.approx)])}`, "");
  if (r.upNext) out.push(`${rt.upNext}: ${one(r.upNext, [episodeLine(lang, r.upNext)])}`, "");
  if (r.channel) out.push(`${rt.channel}: ${r.channel.title} (${duration(lang, r.channel.minutes)})`, "");
  out.push(footerText({ lang, reason: rt.reason, year: o.year }), `${rt.unsub}: ${o.unsubscribeUrl}`, TEXT[lang].tmdb);
  return out.filter((x, n, a) => !(x === "" && a[n - 1] === "")).join("\n");
}

// ---------- voorbeeld (beheer) ----------
// Voorbeeldgegevens, niet van een echte gebruiker: bekende titels met hun TMDB-id (posters en namen haalt het voorbeeld bij
// TMDB op), vaste aantallen en tijden.
export function sampleRows(month: string): RecapRow[] {
  const d = (day: number, h: number, mi: number) => `${month}-${pad(day)}T${pad(h - 1)}:${pad(mi)}:00Z`;
  return [
    { kind: "episode", item_key: "s1", title: "Slow Horses", plays: 9, minutes: 412, episodes: 8, first_at: d(3, 20, 5), last_at: d(29, 22, 10), first_label: "Slow Horses · S4:E1", last_label: "Slow Horses · S4:E6", tmdb_id: 95480 },
    { kind: "episode", item_key: "s2", title: "The Bear", plays: 7, minutes: 236, episodes: 7, first_at: d(1, 19, 42), last_at: d(20, 21, 0), first_label: "The Bear · S3:E1", last_label: "The Bear · S3:E7", tmdb_id: 136315 },
    { kind: "episode", item_key: "s3", title: "Stranger Things", plays: 4, minutes: 205, episodes: 3, first_at: d(10, 20, 30), last_at: d(12, 23, 15), first_label: "Stranger Things · S1:E1", last_label: "Stranger Things · S1:E3", tmdb_id: 66732 },
    { kind: "movie", item_key: "m1", title: "Dune: Part Two", plays: 2, minutes: 171, episodes: 0, first_at: d(7, 20, 0), last_at: d(7, 22, 51), tmdb_id: 693134 },
    { kind: "movie", item_key: "m2", title: "Oppenheimer", plays: 1, minutes: 165, episodes: 0, first_at: d(14, 19, 30), last_at: d(14, 22, 15), tmdb_id: 872585 },
    { kind: "movie", item_key: "m3", title: "Inside Out 2", plays: 1, minutes: 96, episodes: 0, first_at: d(30, 19, 15), last_at: d(30, 20, 51), tmdb_id: 1022789 },
    { kind: "live", item_key: "c1", title: "NPO 1", plays: 12, minutes: 190, episodes: 0, first_at: d(2, 18, 0), last_at: d(28, 19, 0) },
  ];
}
