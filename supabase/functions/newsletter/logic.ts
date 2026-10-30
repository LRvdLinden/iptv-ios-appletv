// Bingr nieuwsbrief: pure logica (geen database, geen netwerk), zodat alles met `deno test` te controleren is.
// Contract: docs/NEWSLETTER.md. Planning: zondag 09:00 en woensdag 18:00 Europe/Amsterdam (ook bij zomer-/wintertijd).

export const SITE = "https://bingr.online";
export const TZ = "Europe/Amsterdam";
export type Lang = "nl" | "en";
export type Kind = "movie" | "tv";

// ---------- tijdrekening ----------

/** Vaste momenten (lokale tijd in Europe/Amsterdam): dag van de week (0 = zondag) en uur. */
export const SLOTS: { dow: number; hour: number; tag: "sun" | "wed" }[] = [
  { dow: 0, hour: 9, tag: "sun" },
  { dow: 3, hour: 18, tag: "wed" },
];
/** Gaat de cron op het uur zelf mis (storing, deploy), dan mag de editie nog zoveel uur later beginnen. */
export const GRACE_HOURS = 2;

const DOW: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
const fmt = new Intl.DateTimeFormat("en-US", {
  timeZone: TZ, weekday: "short", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
export type Local = { date: string; dow: number; hour: number; minute: number };
/** Lokale datum (yyyy-mm-dd), dag van de week, uur en minuut in Europe/Amsterdam. */
export function amsterdam(ms: number): Local {
  const p: Record<string, string> = {};
  for (const x of fmt.formatToParts(new Date(ms))) p[x.type] = x.value;
  return { date: `${p.year}-${p.month}-${p.day}`, dow: DOW[p.weekday] ?? 0, hour: Number(p.hour) % 24, minute: Number(p.minute) };
}

/** Sleutel van een editie: lokale datum + dag, bv. "2026-10-18-sun". */
export const editionKey = (date: string, tag: string) => `${date}-${tag}`;
export const validKey = (k: unknown): k is string => typeof k === "string" && /^\d{4}-\d{2}-\d{2}-(sun|wed)$/.test(k);

/** Welke editie moet nu (beginnen met) versturen? null buiten de momenten (incl. GRACE_HOURS speling). */
export function dueEdition(ms: number): { key: string; at: string } | null {
  for (let back = 0; back <= GRACE_HOURS; back++) {
    const t = Math.floor(ms / 3600_000) * 3600_000 - back * 3600_000;
    const l = amsterdam(t);
    if (l.minute !== 0) continue; // (alleen bij tijdzones met halve uren; Amsterdam niet)
    const s = SLOTS.find((x) => x.dow === l.dow && x.hour === l.hour);
    if (s) return { key: editionKey(l.date, s.tag), at: new Date(t).toISOString() };
  }
  return null;
}

/** Het volgende moment ná ms (strikt later): {key, at (ISO, UTC)}. */
export function nextEdition(ms: number): { key: string; at: string } {
  let t = Math.floor(ms / 3600_000) * 3600_000 + 3600_000;
  for (let i = 0; i < 24 * 8; i++, t += 3600_000) {
    const l = amsterdam(t);
    const s = SLOTS.find((x) => x.dow === l.dow && x.hour === l.hour && l.minute === 0);
    if (s) return { key: editionKey(l.date, s.tag), at: new Date(t).toISOString() };
  }
  throw new Error("geen volgend moment");
}

// ---------- taal ----------

/** Taal van de ontvanger uit user_metadata.lang: nl (of leeg/onbekend) -> nl, een andere taal -> en. */
export function langOf(v: unknown): Lang {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s || s.startsWith("nl")) return "nl";
  return "en";
}
export const TMDB_LANG: Record<Lang, string> = { nl: "nl-NL", en: "en-US" };
export const REGION = "NL";

// ---------- titels ----------

export type Item = {
  type: Kind;
  id: number;
  title: string;
  year: number | null;
  /** yyyy-mm-dd (release in NL of eerste uitzending) */
  date: string | null;
  overview: string;
  poster: string | null;
  backdrop: string | null;
  /** TMDB-genre-id's (max. 3, volgorde van TMDB); `genre` = naam van het eerste genre in de taal van de mail */
  genres?: number[];
  genre?: string;
  /** TMDB-score (vote_average, alleen met genoeg stemmen) en IMDb-score (via OMDb, als de sleutel er is) */
  score?: number | null;
  imdb?: number | null;
  /** Alleen in shownEdition (Top 10): doorlopend nummer 1-6 in de getoonde volgorde */
  rank?: number;
};
/** Top 10 van deze week, films en series apart (zoals de rijen "Top 10" in de apps). */
export type Top10 = { movies: Item[]; tv: Item[] };
/** Welke bronnen deze editie gebruikt (voor de bronvermelding onderaan). */
export type Credits = { trakt?: boolean; omdb?: boolean };
export type Edition = { featured: Item | null; fresh: Item[]; soon: Item[]; popular: Item[]; top10?: Top10; credits?: Credits };
/** Schakelaars per sectie (newsletter_settings.show_top10 / show_popular); standaard aan. */
export type Sections = { top10: boolean; popular: boolean };
export const ALL_SECTIONS: Sections = { top10: true, popular: true };
export type Content = Record<Lang, Edition>;

const IMG_PATH = /^\/[A-Za-z0-9_-]{1,80}\.(jpg|jpeg|png|webp)$/;
/** Alleen nette TMDB-afbeeldingspaden ("/abc123.jpg"); al het andere wordt null (nooit vreemde URL's in de mail). */
export const imgPath = (p: unknown) => (typeof p === "string" && IMG_PATH.test(p) ? p : null);
export const img = (p: string | null, size: "w185" | "w342" | "w780" | "w92") => (p ? `https://image.tmdb.org/t/p/${size}${p}` : null);

const clean = (s: unknown, max: number) => {
  const v = String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (Array.from(v).length <= max) return v;
  const cut = Array.from(v).slice(0, max).join("");
  const sp = cut.lastIndexOf(" ");
  return (sp > max * 0.6 ? cut.slice(0, sp) : cut).replace(/[\s,.;:–-]+$/, "") + "…";
};
const day = (s: unknown) => (typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null);

/** Eén resultaat van TMDB (discover/trending/upcoming) naar een Item; null bij volwassen titels, zonder titel of poster. */
export function toItem(r: Record<string, unknown>, kind?: Kind): Item | null {
  const mt = kind ?? (r.media_type === "tv" ? "tv" : r.media_type === "movie" ? "movie" : null);
  if (!mt || r.adult === true) return null;
  const id = Number(r.id);
  if (!Number.isInteger(id) || id <= 0) return null;
  const title = clean(mt === "tv" ? (r.name ?? r.title) : (r.title ?? r.name), 120);
  const poster = imgPath(r.poster_path);
  if (!title || !poster) return null;
  const date = day(mt === "tv" ? r.first_air_date : r.release_date);
  const it: Item = { type: mt, id, title, year: date ? Number(date.slice(0, 4)) : null, date, overview: clean(r.overview, 260), poster, backdrop: imgPath(r.backdrop_path) };
  // genre_ids (lijsten) of genres [{id, name}] (details)
  const g = Array.isArray(r.genre_ids) ? r.genre_ids : Array.isArray(r.genres) ? (r.genres as { id?: unknown }[]).map((x) => x?.id) : [];
  const genres = g.map(Number).filter((n) => Number.isInteger(n) && n > 0 && n < 1e6).slice(0, 3);
  if (genres.length) it.genres = genres;
  const sc = Number(r.vote_average), votes = Number(r.vote_count);
  if (Number.isFinite(sc) && sc > 0 && sc <= 10 && votes >= MIN_VOTES) it.score = Math.round(sc * 10) / 10;
  return it;
}
/** Minimaal aantal stemmen voordat de TMDB-score in de mail mag (anders zegt hij weinig). */
export const MIN_VOTES = 20;
export const ref = (i: { type: Kind; id: number }) => `${i.type}:${i.id}`;

/** Om en om films en series (populairste eerst, zoals Discover.swift), zonder dubbele. */
export function interleave(a: Item[], b: Item[]): Item[] {
  const out: Item[] = [], seen = new Set<string>();
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    for (const x of [a[i], b[i]]) if (x && !seen.has(ref(x))) { seen.add(ref(x)); out.push(x); }
  }
  return out;
}

/** yyyy-mm-dd, n dagen na `ms` (UTC). */
export const dayOffset = (ms: number, n: number) => new Date(ms + n * 86400_000).toISOString().slice(0, 10);

/** TMDB-verzoeken per editie (zelfde regels als "Nieuw op Bingr" / "Binnenkort op Bingr" in Discover.swift). */
export function tmdbQueries(lang: Lang, ms: number) {
  const language = TMDB_LANG[lang], today = dayOffset(ms, 0);
  const base = { language, include_adult: "false", sort_by: "popularity.desc", page: "1" };
  return {
    freshMovies: ["/discover/movie", { ...base, region: REGION, watch_region: REGION, with_watch_monetization_types: "flatrate", "release_date.gte": dayOffset(ms, -90), "release_date.lte": today }],
    freshTv: ["/discover/tv", { ...base, watch_region: REGION, with_watch_monetization_types: "flatrate", "first_air_date.gte": dayOffset(ms, -120), "first_air_date.lte": today }],
    soonMovies: ["/movie/upcoming", { language, region: REGION, page: "1" }],
    soonTv: ["/discover/tv", { ...base, "first_air_date.gte": dayOffset(ms, 1), "first_air_date.lte": dayOffset(ms, 60) }],
    // Top 10 deze week: TMDB trending (zelfde bron als de rijen "Top 10" in de apps, RichSources.swift), per soort
    trendMovies: ["/trending/movie/week", { language }],
    trendTv: ["/trending/tv/week", { language }],
    // Populair: TMDB popular (geen IMDb: daar is geen openbare API en scrapen mag niet)
    popularMovies: ["/movie/popular", { language, region: REGION, page: "1" }],
    popularTv: ["/tv/popular", { language, page: "1" }],
  } as const satisfies Record<string, readonly [string, Record<string, string>]>;
}

/** Kandidaten per sectie in de editie (meer dan getoond, zodat er na het ontdubbelen en met een sectie uit genoeg overblijven). */
export const LIMITS = { fresh: 12, soon: 12, popular: 12, top10: 10 };
/** Getoond in de mail: per sectie (en per rij van de Top 10) max. 6 titels, 3 naast elkaar in 2 rijen. */
export const SHOW = { perSection: 6, cols: 3 };

export type Lists = {
  freshMovies: Item[]; freshTv: Item[]; soonMovies: Item[]; soonTv: Item[];
  popularMovies: Item[]; popularTv: Item[]; trendMovies: Item[]; trendTv: Item[];
  /** Trakt trending (al aangevuld met TMDB-gegevens): vult de Top 10 aan als TMDB te weinig geeft */
  traktMovies?: Item[]; traktTv?: Item[];
};

/**
 * Top 10 van één soort, zoals TrendingStore in de apps: eerst TMDB trending, dan Trakt trending, en als terugval de
 * populaire titels (in de apps is dat de eigen top uit de bibliotheek; die bestaat aan de serverkant niet). Geen
 * dubbele, niets uit de toekomst. De volgorde van de bron blijft (het is een ranglijst).
 */
export function top10Of(today: string, ...sources: (Item[] | undefined)[]): Item[] {
  const out: Item[] = [], seen = new Set<string>();
  for (const src of sources) {
    for (const x of src ?? []) {
      if (out.length >= LIMITS.top10) return out;
      if (seen.has(ref(x)) || (x.date && x.date > today)) continue;
      seen.add(ref(x));
      out.push(x);
    }
  }
  return out;
}

/**
 * Inhoud van één editie uit de TMDB-lijsten. `recentFeatured` = uitgelichte titels van de vorige 2 edities (ref "movie:1"),
 * `recentShown` = alle titels uit die edities: de uitgelichte titel komt nooit terug; in de rasters gaan titels die nog
 * niet getoond zijn voor.
 */
export function buildEdition(
  lists: Lists, ms: number, recentFeatured: Set<string>, recentShown: Set<string> = new Set(),
): Edition {
  const today = dayOffset(ms, 0);
  const fresh = interleave(lists.freshMovies, lists.freshTv).filter((x) => !x.date || x.date <= today);
  const popular = interleave(lists.popularMovies, lists.popularTv).filter((x) => !x.date || x.date <= today);
  const top10: Top10 = {
    movies: top10Of(today, lists.trendMovies, lists.traktMovies, lists.popularMovies),
    tv: top10Of(today, lists.trendTv, lists.traktTv, lists.popularTv),
  };
  const traktRefs = new Set([...(lists.traktMovies ?? []), ...(lists.traktTv ?? [])].map(ref));
  const trendRefs = new Set([...lists.trendMovies, ...lists.trendTv].map(ref));
  const trakt = [...top10.movies, ...top10.tv].some((x) => traktRefs.has(ref(x)) && !trendRefs.has(ref(x)));
  // uitgelicht: een titel met achtergrond en omschrijving die de vorige 2 edities niet uitgelicht waren
  const pool = [...fresh, ...popular];
  const ok = (x: Item) => !!x.backdrop && !recentFeatured.has(ref(x));
  const featured = pool.find((x) => ok(x) && x.overview) ?? pool.find(ok) ?? null;
  const used = new Set<string>(featured ? [ref(featured)] : []);
  // titels uit de Top 10 tellen niet mee voor het aantal kandidaten: in de mail vallen ze weg (shownEdition), maar staat de
  // Top 10 uit, dan blijven ze op hun plek
  const inTop = new Set([...top10.movies, ...top10.tv].map(ref));
  const upTo = (list: Item[], n: number) => {
    const out: Item[] = [];
    let own = 0;
    for (const x of list) {
      if (own >= n) break;
      out.push(x);
      if (!inTop.has(ref(x))) own++;
    }
    return out;
  };
  const pick = (list: Item[], n: number) => {
    const free = list.filter((x) => !used.has(ref(x)));
    const out = upTo([...free.filter((x) => !recentShown.has(ref(x))), ...free.filter((x) => recentShown.has(ref(x)))], n);
    out.forEach((x) => used.add(ref(x)));
    return out;
  };
  const freshOut = pick(fresh, LIMITS.fresh);
  const soonAll = interleave(lists.soonMovies, lists.soonTv).filter((x) => x.date && x.date > today);
  const soon = pick(soonAll.slice(0, 20), LIMITS.soon).sort((a, b) => (a.date ?? "").localeCompare(b.date ?? "") || a.title.localeCompare(b.title));
  // populair: de volgorde van TMDB houden; dubbele met de Top 10 vallen weg in shownEdition (de Top 10 kan uit staan)
  const pop = upTo(popular.filter((x) => !used.has(ref(x))), LIMITS.popular);
  return { featured, fresh: freshOut, soon, popular: pop, top10, credits: trakt ? { trakt: true } : {} };
}

/**
 * Wat de mail echt toont (HTML, platte tekst, voorbeeld in het beheer en testmail gebruiken allemaal dit): in de volgorde
 * van de mail (Uitgelicht, Top 10 films, Top 10 series, Nieuw, Binnenkort, Populair) per sectie max. SHOW.perSection
 * titels, en een titel die al eerder in de mail staat valt weg (geen titel twee keer). De Top 10 krijgt een doorlopend
 * nummer 1-6 in de getoonde volgorde (ook als er een titel wegvalt omdat hij al uitgelicht is). Werkt ook op oudere opgeslagen edities.
 */
export function shownEdition(e: Edition): Edition {
  const used = new Set<string>(e.featured ? [ref(e.featured)] : []);
  const take = (list: Item[] | undefined, ranked = false) => {
    const out: Item[] = [];
    (list ?? []).forEach((x) => {
      if (out.length >= SHOW.perSection || used.has(ref(x))) return;
      used.add(ref(x));
      out.push(ranked ? { ...x, rank: out.length + 1 } : x);
    });
    return out;
  };
  const movies = take(e.top10?.movies, true), tv = take(e.top10?.tv, true);
  const fresh = take(e.fresh), soon = take(e.soon), popular = take(e.popular);
  return { ...e, fresh, soon, popular, ...(e.top10 ? { top10: { movies, tv } } : {}) };
}

/** Secties die in het beheer uit staan weghalen (Top 10 en/of Populair). */
export function applySections(e: Edition, s: Sections): Edition {
  return { ...e, popular: s.popular ? e.popular : [], top10: s.top10 ? e.top10 : { movies: [], tv: [] } };
}
/** Schakelaars uit een rij van newsletter_settings (ontbrekende kolom = aan). */
export const sectionsOf = (row: Record<string, unknown> | null | undefined): Sections =>
  ({ top10: row?.show_top10 !== false, popular: row?.show_popular !== false });

/** Genre-namen (TMDB /genre/…/list) per soort: id -> naam. */
export type GenreMap = { movie: Map<number, string>; tv: Map<number, string> };
export function genreMap(movie: unknown, tv: unknown): GenreMap {
  const m = (j: unknown) => {
    const out = new Map<number, string>();
    const g = (j as { genres?: unknown })?.genres;
    for (const x of Array.isArray(g) ? g : []) {
      const id = Number((x as { id?: unknown })?.id), name = clean((x as { name?: unknown })?.name, 40);
      if (Number.isInteger(id) && id > 0 && name) out.set(id, name);
    }
    return out;
  };
  return { movie: m(movie), tv: m(tv) };
}
/** Eerste genre in de taal van de mail; "Action & Adventure" -> "Action & Adventure" (zoals TMDB het noemt). */
export function withGenre(i: Item, g: GenreMap): Item {
  const name = (i.genres ?? []).map((id) => g[i.type].get(id)).find(Boolean);
  return name ? { ...i, genre: name } : i;
}
export function mapEdition(e: Edition, f: (i: Item) => Item): Edition {
  return {
    ...e, featured: e.featured ? f(e.featured) : null, fresh: e.fresh.map(f), soon: e.soon.map(f), popular: e.popular.map(f),
    ...(e.top10 ? { top10: { movies: e.top10.movies.map(f), tv: e.top10.tv.map(f) } } : {}),
  };
}

/** IMDb-id ("tt1234567") of null. */
export const imdbId = (v: unknown): string | null => (typeof v === "string" && /^tt\d{5,10}$/.test(v) ? v : null);
/** IMDb-score uit een OMDb-antwoord ("7.8", "N/A") -> 7.8 of null. */
export function omdbRating(j: unknown): number | null {
  const o = j as { Response?: unknown; imdbRating?: unknown } | null;
  if (!o || o.Response === "False") return null;
  const n = Number(String(o.imdbRating ?? "").replace(",", "."));
  return Number.isFinite(n) && n > 0 && n <= 10 ? Math.round(n * 10) / 10 : null;
}

/** Alle refs in een editie (voor het ontdubbelen van de volgende). */
export function editionRefs(e: Partial<Edition> | null | undefined): { featured: string[]; shown: string[] } {
  if (!e) return { featured: [], shown: [] };
  e = shownEdition({ featured: null, fresh: [], soon: [], popular: [], ...e } as Edition);
  // de Top 10 telt niet mee: een ranglijst mag terugkomen, en hij mag het raster "Nieuw" niet verdringen
  const all = [e.featured, ...(e.fresh ?? []), ...(e.soon ?? []), ...(e.popular ?? [])].filter(Boolean) as Item[];
  return { featured: e.featured ? [ref(e.featured)] : [], shown: all.map(ref) };
}

// ---------- links ----------

/** Universele link naar een titel: opent de app (Apple universal links / Android app links), anders bingr.online/titel/. */
export function titleUrl(i: { type: Kind; id: number; title: string; year?: number | null }): string {
  const p = new URLSearchParams({ type: i.type, id: String(i.id), q: i.title });
  if (i.year && i.year > 1800 && i.year < 3000) p.set("y", String(i.year));
  return `${SITE}/titel/?${p.toString().replace(/\+/g, "%20")}`;
}

// ---------- afmelden ----------

const enc = new TextEncoder();
export function b64u(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function unb64u(s: string): Uint8Array {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  if (!/^[A-Za-z0-9+/]*$/.test(t)) throw new Error("bad_base64");
  return Uint8Array.from(atob(t + "===".slice((t.length + 3) % 4)), (c) => c.charCodeAt(0));
}
async function hmac(material: string, data: string) {
  const key = await crypto.subtle.importKey("raw", await crypto.subtle.digest("SHA-256", enc.encode(material)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(data)));
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Sleutelmateriaal: eigen voorvoegsel, zodat een afmeldtoken van de nieuwsbrief nooit als dat van de berichten (admin) geldt. */
export const unsubMaterial = (secret: string) => `bingr-news-unsub-v1|${secret}`;
/** Afmeldtoken per account: "<uuid>.<18 bytes HMAC, base64url>" (zelfde vorm als de berichten, ander bericht en sleutel). */
export async function unsubToken(userId: string, secret: string): Promise<string> {
  if (!UUID.test(userId)) throw new Error("bad_user");
  const id = userId.toLowerCase();
  return `${id}.${b64u((await hmac(unsubMaterial(secret), `news-unsub:${id}`)).subarray(0, 18))}`;
}
/** Token controleren -> account-id (kleine letters) of null. */
export async function unsubUser(t: unknown, secret: string): Promise<string | null> {
  if (typeof t !== "string" || t.length > 120 || !secret) return null;
  const [id, sig, extra] = t.split(".");
  if (extra !== undefined || !UUID.test(id ?? "") || !sig) return null;
  let given: Uint8Array;
  try { given = unb64u(sig); } catch { return null; }
  const want = (await hmac(unsubMaterial(secret), `news-unsub:${id.toLowerCase()}`)).subarray(0, 18);
  if (given.length !== want.length) return null;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= given[i] ^ want[i];
  return d === 0 ? id.toLowerCase() : null;
}
export const unsubPageUrl = (token: string) => `${SITE}/unsubscribe/?k=news&t=${encodeURIComponent(token)}`;
export const oneClickUrl = (fnUrl: string, token: string) => `${fnUrl}?unsubscribe=${encodeURIComponent(token)}`;

// ---------- overig ----------

/** Eenvoudige controle van een e-mailadres (voor het voorbeeld). */
export function validEmail(v: unknown): v is string {
  return typeof v === "string" && v.length <= 254 && /^[^\s@<>()",;:\\[\]]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/.test(v);
}
/** v3-API-sleutel (32 hex) of v4-leestoken (JWT): de juiste manier van meesturen. */
export function tmdbAuth(key: string): { header?: string; param?: string } {
  const k = key.trim();
  if (!k) return {};
  return k.split(".").length === 3 && k.length > 60 ? { header: `Bearer ${k}` } : { param: k };
}
/** Tijdelijke SMTP-fout (later opnieuw proberen, batch stoppen)? */
export function smtpTemporary(e: unknown): boolean {
  // Tijdelijk = later opnieuw (de batch stopt). Alleen een weigering van deze ontvanger (5xx bij RCPT TO / EENVELOPE, bv. 550
  // "user unknown") is blijvend. Fouten van de verbinding, het inloggen (EAUTH, ook 535) of een limiet van de provider
  // (ook als 5xx, bv. "550 rate limit exceeded" / "554 quota") gelden niet voor de ontvanger: vroeger werden die als
  // blijvend geteld en kreeg de rest van de batch nooit een mail.
  const x = e as { responseCode?: number; code?: string; command?: string; response?: string };
  const c = Number(x?.responseCode ?? 0);
  const code = String(x?.code ?? "");
  if (c >= 400 && c < 500) return true;
  if (["ETIMEDOUT", "ECONNECTION", "ESOCKET", "ECONNRESET", "EDNS", "EAUTH", "ETLS", "ECONNREFUSED", "EPROTOCOL", "EMAXLIMIT"].includes(code)) return true;
  if (c >= 500 && /rate|limit|quota|too many|exceeded|try again|throttl/i.test(String(x?.response ?? ""))) return true;
  return false;
}
/** Korte foutcode voor logs/tellers (nooit adressen of serverteksten). */
export function smtpCode(e: unknown): string {
  const c = Number((e as { responseCode?: number })?.responseCode ?? 0);
  if (c) return `smtp_${c}`;
  const code = String((e as { code?: string })?.code ?? "");
  return /^[A-Z]{2,20}$/.test(code) ? code.toLowerCase() : "error";
}

/** Geheim vergelijken in constante tijd; leeg of korter dan 16 tekens telt nooit. */
export function sameSecret(given: string | null | undefined, want: string | null | undefined): boolean {
  const a = enc.encode(String(given ?? "")), b = enc.encode(String(want ?? ""));
  if (b.length < 16) return false;
  let d = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) d |= (a[i] ?? 0) ^ b[i];
  return d === 0;
}
