// Bingr title-meta (build 132): openbare metadata van één film of serie voor de deelpreview van bingr.online/titel/
// (Open Graph / Twitter-tags, server-side gerenderd door titel/index.php in bingr-website). Geen sleutel nodig.
//   GET ?type=movie|tv&id=<tmdb-id>[&q=<titel>&y=<jaar>]   -> metadata van die titel (id onbekend en q gegeven: zoeken)
//   GET ?type=movie|tv&q=<titel>[&y=<jaar>]                -> eerste zoekresultaat
//   200 {ok, type, id, year, title:{nl,en}, overview:{nl,en}, poster, backdrop, image:{url,width,height}, url}
//   400 bad_request · 404 not_found · 405 method · 429 rate_limited · 502 upstream · 503 not_configured
// TMDB-sleutel: function-secret BINGR_TMDB_API_KEY (zelfde als de nieuwsbrief); nooit in een antwoord of log.
// Geen logging van IP-adressen; de limiet (60 per minuut) houdt alleen een gehashte sleutel met een zout per instantie bij.
import { cacheKey, Limiter, type Meta, parseQuery, searchQuery, tmdbAuth, toMeta, type Want } from "./logic.ts";
import { clientIp } from "../_shared/ip.ts";

const API = "https://api.themoviedb.org/3";
const KEY = Deno.env.get("BINGR_TMDB_API_KEY") ?? "";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Max-Age": "86400",
};
const limiter = new Limiter(60, 60_000);
const SALT = crypto.getRandomValues(new Uint8Array(16));
const cache = new Map<string, { at: number; status: number; body: string }>();
const TTL_OK = 6 * 3600_000, TTL_MISS = 3600_000, MAX_CACHE = 1000;

function json(status: number, body: unknown, cacheCtl: string): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": cacheCtl, "X-Robots-Tag": "noindex" },
  });
}
const CC_OK = "public, max-age=3600, s-maxage=86400";
const CC_MISS = "public, max-age=600, s-maxage=3600";

async function ipKey(req: Request): Promise<string> {
  const ip = clientIp(req); // security L7: _shared/ip.ts
  const d = await crypto.subtle.digest("SHA-256", new Uint8Array([...SALT, ...new TextEncoder().encode(ip)]));
  return btoa(String.fromCharCode(...new Uint8Array(d).slice(0, 12)));
}

class NotFound extends Error {}
async function tmdb(path: string, q: Record<string, string>): Promise<Record<string, unknown>> {
  const a = tmdbAuth(KEY);
  const u = new URL(API + path);
  for (const [k, v] of Object.entries(q)) u.searchParams.set(k, v);
  if (a.param) u.searchParams.set("api_key", a.param);
  const r = await fetch(u, { headers: { Accept: "application/json", ...(a.header ? { Authorization: a.header } : {}) }, signal: AbortSignal.timeout(6000) });
  if (r.status === 404) { await r.body?.cancel(); throw new NotFound(); }
  if (!r.ok) { await r.body?.cancel(); throw new Error(`tmdb_${r.status}`); }
  return await r.json();
}

async function details(w: Want, id: number): Promise<Meta | null> {
  const path = `/${w.kind}/${id}`;
  const [nl, en] = await Promise.all([tmdb(path, { language: "nl-NL" }), tmdb(path, { language: "en-US" }).catch(() => null)]);
  return toMeta(w.kind, nl, en);
}
async function search(w: Want): Promise<number | null> {
  const [p, q] = searchQuery(w, "nl-NL");
  let j = await tmdb(p, q);
  let res = Array.isArray(j.results) ? j.results as Record<string, unknown>[] : [];
  if (!res.length && w.y) { // jaar wijkt soms een jaar af: nog één keer zonder jaar
    j = await tmdb(...searchQuery({ ...w, y: null }, "nl-NL"));
    res = Array.isArray(j.results) ? j.results as Record<string, unknown>[] : [];
  }
  const id = Number(res[0]?.id);
  return Number.isInteger(id) && id > 0 ? id : null;
}

async function lookup(w: Want): Promise<Meta | null> {
  if (w.id) {
    try { return await details(w, w.id); } catch (e) {
      if (!(e instanceof NotFound) || !w.q) throw e;
    }
  }
  const id = await search(w);
  return id ? await details(w, id).catch((e) => { if (e instanceof NotFound) return null; throw e; }) : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "GET" && req.method !== "HEAD") return json(405, { error: "method" }, "no-store");
  const want = parseQuery(new URL(req.url).searchParams);
  if (!want) return json(400, { error: "bad_request" }, CC_MISS);
  const ck = cacheKey(want), now = Date.now();
  const hit = cache.get(ck);
  if (hit && now - hit.at < (hit.status === 200 ? TTL_OK : TTL_MISS)) return json(hit.status, hit.body, hit.status === 200 ? CC_OK : CC_MISS);
  if (!limiter.allow(await ipKey(req), now)) return json(429, { error: "rate_limited" }, "no-store");
  if (!tmdbAuth(KEY).header && !tmdbAuth(KEY).param) return json(503, { error: "not_configured" }, "no-store");
  try {
    const m = await lookup(want);
    const status = m ? 200 : 404;
    const body = JSON.stringify(m ?? { error: "not_found" });
    if (cache.size >= MAX_CACHE) cache.clear();
    cache.set(ck, { at: now, status, body });
    return json(status, body, m ? CC_OK : CC_MISS);
  } catch (e) {
    if (e instanceof NotFound) {
      cache.set(ck, { at: now, status: 404, body: '{"error":"not_found"}' });
      return json(404, { error: "not_found" }, CC_MISS);
    }
    return json(502, { error: "upstream" }, "no-store"); // geen details in het antwoord of het log
  }
});
