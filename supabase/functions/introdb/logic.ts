// Bingr introdb (build 179): pure logica (validatie, TheIntroDB-antwoord → tijden in seconden). Getest in introdb_test.ts.
// Contract: docs/ACCOUNT.md → "Build 179", punt 10. Bron: TheIntroDB (api.theintrodb.org/v4/media, openbaar, geen sleutel;
// alleen lezen, tijden in milliseconden in de arrays intro, recap en credits).
// Build 186: zonder tmdb ook { title, year?, imdb?, season, episode }; de server zoekt dan zelf het TMDB-id van de serie
// (TMDB /find op imdb, anders /search/tv met de opgeschoonde titel en het jaar, daarna zonder jaar).

export type Want = { tmdb: number; imdb: string | null; season: number; episode: number };
/** Build 186: serie zonder TMDB-id (titel uit de IPTV-bibliotheek). */
export type Lookup = { tmdb: null; title: string; year: number | null; imdb: string | null; season: number; episode: number };
export type Segment = { start: number; end?: number };
export type Result = { intro: Segment | null; recap: Segment | null; credits: Segment | null };

export const CACHE_DAYS = 30;
export const MISS_DAYS = 1;
export const PER_MINUTE = 120;
export const API = "https://api.theintrodb.org/v4/media";

function int(v: unknown, min: number, max: number): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,10}$/.test(v) ? Number(v) : NaN;
  return Number.isInteger(n) && n >= min && n <= max ? n : null;
}

/** Verzoek → wat er gevraagd wordt, of null (ongeldig). Met tmdb: Want; zonder tmdb maar met titel of imdb: Lookup. */
export function parseBody(b: unknown): Want | Lookup | null {
  if (!b || typeof b !== "object" || Array.isArray(b)) return null;
  const o = b as Record<string, unknown>;
  const tmdb = int(o.tmdb, 1, 9_999_999_999), season = int(o.season, 0, 500), episode = int(o.episode, 0, 10_000);
  if (season === null || episode === null) return null;
  const imdb = typeof o.imdb === "string" && /^tt\d{5,10}$/.test(o.imdb.trim()) ? o.imdb.trim() : null;
  if (tmdb) return { tmdb, imdb, season, episode };
  if (o.tmdb !== undefined && o.tmdb !== null && o.tmdb !== "") return null; // tmdb gegeven maar ongeldig
  const title = typeof o.title === "string" ? cleanTitle(o.title) : "";
  const y = int(o.year, 1900, 2100) ?? (typeof o.title === "string" ? titleYear(o.title) : null);
  if (!title && !imdb) return null;
  return { tmdb: null, title, year: y, imdb, season, episode };
}

const PIPES = /[¦│｜┃]/g;
const QUALITY = /^(4k|uhd|fhd|hd|sd|hevc|h\.?265|x26[45]|1080p|720p|2160p|hdr10?\+?|dv|multi|subs?|vost\w*)$/i;
const CODES = "nl|en|uk|us|gb|de|fr|es|it|vl|tr|ar|pl|pt|br|ru|se|dk|fi|gr|ro|nf|nfx|vod|multi|4k|uhd|fhd|hd|sd";
// "NL | ", "[NL] ", "(EN) ", "EN-", "NL SUBS | ": alleen taal-/landcodes en IPTV-woorden, met | of - erachter
// ("NCIS: Hawaii", "It: Welcome to Derry" en "BBC - Planet Earth" blijven heel)
const SUFFIX = new RegExp(`\\s*[|\\-]\\s*(?:${CODES})(?:[- ]?subs?)?\\s*$`, "i");
const PREFIX = new RegExp(`^(?:\\[[^\\]]{1,12}\\]|\\([^)]{1,12}\\)|(?:${CODES})(?:[- ]?subs?)?\\s*[|\\-])\\s*`, "i");

/** IPTV-titel → zoektitel: taal-/landcodes vooraan, afleveringsmarkering, kwaliteitswoorden en haakjes weg. */
export function cleanTitle(raw: string): string {
  let s = String(raw).replace(/[\u0000-\u001f\u007f]/g, " ").replace(PIPES, "|").slice(0, 300).trim();
  for (let i = 0; i < 3; i++) {
    const m = s.match(PREFIX);
    if (!m || m[0].length >= s.length) break;
    s = s.slice(m[0].length);
  }
  s = s.replace(/\s*[|\-]?\s*\bS\d{1,3}\s*E\d{1,4}\b.*$/i, "").replace(/\s*\b\d{1,2}x\d{1,3}\b.*$/i, "");
  s = s.replace(/\[[^\]]*\]|\([^)]*\)/g, " ").replace(/[_.]/g, " ");
  s = s.split(/\s+/).filter((w) => w && !QUALITY.test(w)).join(" ");
  s = s.replace(SUFFIX, "").replace(/\s+[|\-]\s*((18|19|20)\d{2})\s*$/, "").replace(/^[\s|:\-]+|[\s|:\-]+$/g, "");
  return s.slice(0, 200);
}

/** Jaartal uit een IPTV-titel ("Show (2008)", "Show - 2008"), anders null. */
export function titleYear(raw: string): number | null {
  const m = String(raw).match(/\(((?:18|19|20)\d{2})\)|[|\-]\s*((?:18|19|20)\d{2})\s*$/);
  const y = m ? Number(m[1] ?? m[2]) : NaN;
  return Number.isInteger(y) ? y : null;
}

/** Cachesleutel voor het gevonden TMDB-id van een serie. */
export function showKey(l: Lookup): string {
  const t = l.title.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
  return `introdb-show:${t || l.imdb || ""}:${l.year ?? ""}`;
}

/** TMDB-sleutel: v4-leestoken (JWT) als Bearer, anders v3-sleutel als parameter (zoals in title-meta/logic.ts). */
export function tmdbAuth(key: string): { header?: string; param?: string } {
  const k = key.trim();
  if (!k) return {};
  return k.split(".").length === 3 && k.length > 60 ? { header: `Bearer ${k}` } : { param: k };
}

/** Zoekstappen bij TMDB, in volgorde: /find op imdb, /search/tv met jaar, /search/tv zonder jaar. */
export function showQueries(l: Lookup): [string, Record<string, string>][] {
  const out: [string, Record<string, string>][] = [];
  if (l.imdb) out.push([`/find/${l.imdb}`, { external_source: "imdb_id" }]);
  if (l.title) {
    const q = { query: l.title, include_adult: "false", page: "1" };
    if (l.year) out.push(["/search/tv", { ...q, first_air_date_year: String(l.year) }]);
    out.push(["/search/tv", q]);
  }
  return out;
}

/** TMDB-antwoord (find of search) → id van de eerste serie, of null. */
export function showId(j: unknown): number | null {
  if (!j || typeof j !== "object") return null;
  const o = j as Record<string, unknown>;
  const list = Array.isArray(o.tv_results) ? o.tv_results : Array.isArray(o.results) ? o.results : [];
  const id = Number((list[0] as Record<string, unknown> | undefined)?.id);
  return Number.isInteger(id) && id > 0 ? id : null;
}

export function cacheKey(w: Want): string {
  return `introdb:${w.tmdb}:${w.season}:${w.episode}`;
}

/** Adres bij TheIntroDB. */
export function url(w: Want): string {
  const u = new URL(API);
  u.searchParams.set("tmdb_id", String(w.tmdb));
  if (w.imdb) u.searchParams.set("imdb_id", w.imdb);
  u.searchParams.set("season", String(w.season));
  u.searchParams.set("episode", String(w.episode));
  return u.toString();
}

function ms(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;
}

/** Eerste bruikbare segment (start null = begin van de aflevering, end null = tot het einde) → seconden. */
function segment(list: unknown, needEnd: boolean): Segment | null {
  if (!Array.isArray(list)) return null;
  for (const s of list) {
    if (!s || typeof s !== "object") continue;
    const r = s as Record<string, unknown>;
    const start = r.start_ms === null ? 0 : ms(r.start_ms);
    const end = r.end_ms === null ? null : ms(r.end_ms);
    if (start === null) continue;
    if (needEnd) {
      if (end === null || end <= start) continue;
      return { start: Math.round(start / 100) / 10, end: Math.round(end / 100) / 10 };
    }
    return { start: Math.round(start / 100) / 10 };
  }
  return null;
}

/** TheIntroDB-antwoord → { intro, recap, credits }; null als er niets bruikbaars in staat. */
export function toResult(j: unknown): Result | null {
  if (!j || typeof j !== "object") return null;
  const o = j as Record<string, unknown>;
  const r: Result = { intro: segment(o.intro, true), recap: segment(o.recap, true), credits: segment(o.credits, false) };
  return r.intro || r.recap || r.credits ? r : null;
}

/** Cacherij bruikbaar? Gevonden 30 dagen, niet gevonden 1 dag. */
export function fresh(fetchedAt: string | null | undefined, found: boolean, now: number): boolean {
  const t = fetchedAt ? Date.parse(fetchedAt) : NaN;
  const days = found ? CACHE_DAYS : MISS_DAYS;
  return Number.isFinite(t) && now - t >= -3600_000 && now - t < days * 86400_000;
}
