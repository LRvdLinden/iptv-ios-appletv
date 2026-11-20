// Bingr introdb (build 179): pure logica (validatie, TheIntroDB-antwoord → tijden in seconden). Getest in introdb_test.ts.
// Contract: docs/ACCOUNT.md → "Build 179", punt 10. Bron: TheIntroDB (api.theintrodb.org/v4/media, openbaar, geen sleutel;
// alleen lezen, tijden in milliseconden in de arrays intro, recap en credits).

export type Want = { tmdb: number; imdb: string | null; season: number; episode: number };
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

/** Verzoek → wat er gevraagd wordt, of null (ongeldig). */
export function parseBody(b: unknown): Want | null {
  if (!b || typeof b !== "object" || Array.isArray(b)) return null;
  const o = b as Record<string, unknown>;
  const tmdb = int(o.tmdb, 1, 9_999_999_999), season = int(o.season, 0, 500), episode = int(o.episode, 0, 10_000);
  if (!tmdb || season === null || episode === null) return null;
  const imdb = typeof o.imdb === "string" && /^tt\d{5,10}$/.test(o.imdb.trim()) ? o.imdb.trim() : null;
  return { tmdb, imdb, season, episode };
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
