// Bingr title-meta: pure logica (validatie, TMDB-antwoord → metadata). Getest in title_meta_test.ts.
export type Kind = "movie" | "tv";
export type Want =
  | { kind: Kind; id: number; q: string; y: number | null }
  | { kind: Kind; id: null; q: string; y: number | null };

export const IMG = "https://image.tmdb.org/t/p/";

function clean(s: string | null, max: number): string {
  return String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

/** Query → wat er gevraagd wordt, of null (ongeldig). type ∈ movie|tv, id numeriek (1–10 cijfers), anders q (+ y). */
export function parseQuery(p: URLSearchParams): Want | null {
  const t = p.get("type");
  if (t !== "movie" && t !== "tv") return null;
  const rawId = p.get("id") ?? "";
  if (rawId && !/^[1-9]\d{0,9}$/.test(rawId)) return null;
  const q = clean(p.get("q"), 200);
  const ys = p.get("y") ?? "";
  const y = /^(18|19|20|21)\d{2}$/.test(ys) ? Number(ys) : null;
  if (rawId) return { kind: t, id: Number(rawId), q, y };
  if (!q) return null;
  return { kind: t, id: null, q, y };
}

/** Cachesleutel (in het geheugen van de functie). */
export function cacheKey(w: Want): string {
  return w.id ? `${w.kind}:${w.id}` : `s:${w.kind}:${w.q.toLowerCase()}:${w.y ?? ""}`;
}

/** TMDB-sleutel: v4-leestoken (JWT) als Bearer, anders v3-sleutel als parameter (zoals in newsletter/logic.ts). */
export function tmdbAuth(key: string): { header?: string; param?: string } {
  const k = key.trim();
  if (!k) return {};
  return k.split(".").length === 3 && k.length > 60 ? { header: `Bearer ${k}` } : { param: k };
}

/** Zoekpad en -parameters voor q (+ y). */
export function searchQuery(w: Want, lang: string): [string, Record<string, string>] {
  const q: Record<string, string> = { query: w.q, language: lang, include_adult: "false", page: "1" };
  if (w.y) q[w.kind === "tv" ? "first_air_date_year" : "primary_release_year"] = String(w.y);
  return [`/search/${w.kind}`, q];
}

function imgPath(v: unknown): string | null {
  return typeof v === "string" && /^\/[A-Za-z0-9_-]{1,80}\.(jpg|jpeg|png|webp)$/.test(v) ? v : null;
}
function str(v: unknown, max: number): string {
  return typeof v === "string" ? clean(v, max) : "";
}

export type Meta = {
  ok: true;
  type: Kind;
  id: number;
  year: number | null;
  title: { nl: string; en: string };
  overview: { nl: string; en: string };
  poster: string | null;
  backdrop: string | null;
  image: { url: string; width: number; height: number } | null;
  url: string;
};

/** Canonieke universele link (zelfde als in de nieuwsbrief en de deelknoppen). */
export function canonicalUrl(kind: Kind, id: number, title: string, year: number | null): string {
  const p = new URLSearchParams({ type: kind, id: String(id) });
  if (title) p.set("q", title);
  if (year) p.set("y", String(year));
  return `https://bingr.online/titel/?${p.toString().replace(/\+/g, "%20")}`;
}

/** Details in nl-NL en en-US → metadata. Omschrijving en titel: nl, terugval en (en omgekeerd). */
export function toMeta(kind: Kind, nl: Record<string, unknown> | null, en: Record<string, unknown> | null): Meta | null {
  const a = nl ?? en, b = en ?? nl;
  if (!a || !b) return null;
  const id = Number(a.id ?? b.id);
  if (!Number.isInteger(id) || id <= 0) return null;
  const tKey = kind === "tv" ? "name" : "title";
  const oKey = kind === "tv" ? "original_name" : "original_title";
  const tNl = str(a[tKey], 200) || str(b[tKey], 200) || str(a[oKey], 200);
  const tEn = str(b[tKey], 200) || tNl;
  const oNl = str(a.overview, 2000) || str(b.overview, 2000);
  const oEn = str(b.overview, 2000) || oNl;
  const date = str(a[kind === "tv" ? "first_air_date" : "release_date"], 10) || str(b[kind === "tv" ? "first_air_date" : "release_date"], 10);
  const year = /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null;
  const pp = imgPath(a.poster_path) ?? imgPath(b.poster_path);
  const bp = imgPath(a.backdrop_path) ?? imgPath(b.backdrop_path);
  const poster = pp ? `${IMG}w780${pp}` : null;
  const backdrop = bp ? `${IMG}w1280${bp}` : null;
  const image = backdrop ? { url: backdrop, width: 1280, height: 720 } : poster ? { url: poster, width: 780, height: 1170 } : null;
  if (!tNl) return null;
  return {
    ok: true, type: kind, id, year, title: { nl: tNl, en: tEn }, overview: { nl: oNl, en: oEn }, poster, backdrop, image,
    url: canonicalUrl(kind, id, tEn || tNl, year),
  };
}

/** Eenvoudige limiet per sleutel (gehashte IP) in het geheugen: max `n` per `windowMs`. */
export class Limiter {
  private m = new Map<string, { n: number; reset: number }>();
  constructor(private n: number, private windowMs: number, private maxKeys = 5000) {}
  allow(key: string, now = Date.now()): boolean {
    const e = this.m.get(key);
    if (!e || e.reset <= now) {
      if (this.m.size >= this.maxKeys) this.m.clear();
      this.m.set(key, { n: 1, reset: now + this.windowMs });
      return true;
    }
    e.n++;
    return e.n <= this.n;
  }
}
