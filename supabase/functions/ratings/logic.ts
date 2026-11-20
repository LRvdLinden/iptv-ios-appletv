// Bingr ratings (build 179): pure logica (validatie, MDBList-antwoord → beoordelingen). Getest in ratings_test.ts.
// Contract: docs/ACCOUNT.md → "Build 179", punt 9.

export type Want = { kind: "movie" | "show"; tmdb: number; imdb: string | null } | { kind: "movie" | "show" | null; tmdb: null; imdb: string };
export type Rating = { source: Source; value: number; votes?: number };
export const SOURCES = ["imdb", "tmdb", "tomatoes", "tomatoesaudience", "metacritic", "letterboxd", "trakt"] as const;
export type Source = typeof SOURCES[number];

export const CACHE_DAYS = 7;
export const PER_MINUTE = 120;

const IMDB = /^tt\d{5,10}$/;

/** Verzoek → wat er gevraagd wordt, of null (ongeldig). */
export function parseBody(b: unknown): Want | null {
  if (!b || typeof b !== "object" || Array.isArray(b)) return null;
  const o = b as Record<string, unknown>;
  const t = o.type === "tv" ? "show" : o.type;
  const kind = t === "movie" || t === "show" ? t : null;
  const imdb = typeof o.imdb === "string" && IMDB.test(o.imdb.trim()) ? o.imdb.trim() : null;
  const n = typeof o.tmdb === "number" ? o.tmdb : typeof o.tmdb === "string" && /^\d{1,10}$/.test(o.tmdb) ? Number(o.tmdb) : NaN;
  const tmdb = Number.isInteger(n) && n > 0 && n < 1e10 ? n : null;
  if (tmdb && kind) return { kind, tmdb, imdb };
  if (imdb) return { kind, tmdb: null, imdb };
  return null;
}

/** Sleutel in ratings_cache: movie:<tmdb> / show:<tmdb> / imdb:<id>. */
export function cacheKey(w: Want): string {
  return w.tmdb ? `${w.kind}:${w.tmdb}` : `imdb:${w.imdb}`;
}

/** Adressen bij MDBList (de sleutel komt er pas bij het ophalen bij, nooit in een log). */
export function mdblistPaths(w: Want): string[] {
  if (w.tmdb) return [`/tmdb/${w.kind}/${w.tmdb}`];
  const kinds = w.kind ? [w.kind] : ["movie", "show"];
  return kinds.map((k) => `/imdb/${k}/${w.imdb}`);
}

/** Bron van MDBList → onze bron (null = niet tonen). */
export function mapSource(s: unknown): Source | null {
  switch (String(s ?? "").toLowerCase()) {
    case "imdb": return "imdb";
    case "tmdb": return "tmdb";
    case "tomatoes": return "tomatoes";
    case "popcorn": case "tomatoesaudience": case "audience": return "tomatoesaudience";
    case "metacritic": return "metacritic";
    case "letterboxd": return "letterboxd";
    case "trakt": return "trakt";
    default: return null;
  }
}

function num(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** MDBList-antwoord → beoordelingen in de schaal van het contract: imdb/tmdb 0–10, letterboxd 0–5, de rest 0–100. */
export function toRatings(j: unknown): Rating[] {
  const list = (j && typeof j === "object" && Array.isArray((j as { ratings?: unknown }).ratings))
    ? (j as { ratings: Record<string, unknown>[] }).ratings : [];
  const out: Rating[] = [];
  for (const r of list) {
    const source = mapSource(r?.source);
    if (!source || out.some((x) => x.source === source)) continue;
    let v = num(r.value);
    const score = num(r.score);
    if (v === null || v <= 0) {
      if (score === null || score <= 0) continue;
      // alleen een score (0–100): terugrekenen naar de schaal van de bron
      v = source === "imdb" || source === "tmdb" ? score / 10 : source === "letterboxd" ? score / 20 : score;
    }
    if (source === "tmdb" && v > 10) v = v / 10;        // MDBList geeft TMDB soms als 0–100
    if ((source === "imdb") && v > 10) continue;
    if (source === "letterboxd" && v > 5) v = v / 20;
    if (v > 100) continue;
    const item: Rating = { source, value: Math.round(v * 100) / 100 };
    const votes = num(r.votes);
    if (votes !== null && votes > 0) item.votes = Math.round(votes);
    out.push(item);
  }
  out.sort((a, b) => SOURCES.indexOf(a.source) - SOURCES.indexOf(b.source));
  return out;
}

/** Is een cacherij nog bruikbaar? */
export function fresh(fetchedAt: string | null | undefined, now: number, days = CACHE_DAYS): boolean {
  const t = fetchedAt ? Date.parse(fetchedAt) : NaN;
  return Number.isFinite(t) && now - t >= -3600_000 && now - t < days * 86400_000;
}
