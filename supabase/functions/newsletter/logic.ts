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
};
export type Edition = { featured: Item | null; fresh: Item[]; soon: Item[]; popular: Item[] };
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
  return { type: mt, id, title, year: date ? Number(date.slice(0, 4)) : null, date, overview: clean(r.overview, 260), poster, backdrop: imgPath(r.backdrop_path) };
}
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
    popular: ["/trending/all/week", { language }],
  } as const satisfies Record<string, readonly [string, Record<string, string>]>;
}

export const LIMITS = { fresh: 6, soon: 4, popular: 5 };

/**
 * Inhoud van één editie uit de TMDB-lijsten. `recentFeatured` = uitgelichte titels van de vorige 2 edities (ref "movie:1"),
 * `recentShown` = alle titels uit die edities: de uitgelichte titel komt nooit terug; in de rasters gaan titels die nog
 * niet getoond zijn voor.
 */
export function buildEdition(
  lists: { freshMovies: Item[]; freshTv: Item[]; soonMovies: Item[]; soonTv: Item[]; popular: Item[] },
  ms: number, recentFeatured: Set<string>, recentShown: Set<string> = new Set(),
): Edition {
  const today = dayOffset(ms, 0);
  const fresh = interleave(lists.freshMovies, lists.freshTv).filter((x) => !x.date || x.date <= today);
  const popular = lists.popular.filter((x) => !x.date || x.date <= today);
  // uitgelicht: een titel met achtergrond en omschrijving die de vorige 2 edities niet uitgelicht waren
  const pool = [...fresh, ...popular];
  const ok = (x: Item) => !!x.backdrop && !recentFeatured.has(ref(x));
  const featured = pool.find((x) => ok(x) && x.overview) ?? pool.find(ok) ?? null;
  const used = new Set<string>(featured ? [ref(featured)] : []);
  const pick = (list: Item[], n: number) => {
    const free = list.filter((x) => !used.has(ref(x)));
    const out = [...free.filter((x) => !recentShown.has(ref(x))), ...free.filter((x) => recentShown.has(ref(x)))].slice(0, n);
    out.forEach((x) => used.add(ref(x)));
    return out;
  };
  const freshOut = pick(fresh, LIMITS.fresh);
  const soonAll = interleave(lists.soonMovies, lists.soonTv).filter((x) => x.date && x.date > today);
  const soon = pick(soonAll.slice(0, 20), LIMITS.soon).sort((a, b) => (a.date ?? "").localeCompare(b.date ?? "") || a.title.localeCompare(b.title));
  // populair: de volgorde van TMDB houden (een top-lijst), alleen wat al in deze mail staat overslaan
  const pop = popular.filter((x) => !used.has(ref(x))).slice(0, LIMITS.popular);
  return { featured, fresh: freshOut, soon, popular: pop };
}

/** Alle refs in een editie (voor het ontdubbelen van de volgende). */
export function editionRefs(e: Partial<Edition> | null | undefined): { featured: string[]; shown: string[] } {
  if (!e) return { featured: [], shown: [] };
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
  const c = Number((e as { responseCode?: number })?.responseCode ?? 0);
  const code = String((e as { code?: string })?.code ?? "");
  return (c >= 400 && c < 500) || ["ETIMEDOUT", "ECONNECTION", "ESOCKET", "ECONNRESET", "EDNS"].includes(code);
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
