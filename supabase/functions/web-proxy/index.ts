// Bingr: proxy voor de webspeler (build 62). IPTV-servers sturen zelden CORS-headers, dus de browser kan
// API-JSON, M3U, XMLTV en HLS-afspeellijsten/-segmenten niet zelf ophalen.
//
// POST /functions/v1/web-proxy, headers `apikey` en `Authorization: Bearer <access_token>`, body {url, range?}
//   url    https-URL (alleen https; de webspeler ondersteunt alleen https-bronnen)
//   range  optioneel, bv. "bytes=0-1048575"
// Alleen hosts uit de eigen servers van het account (get_sources: m3uURL, epgURL, serverURL) mogen, plus subdomeinen
// van hetzelfde domein. Doorverwijzingen (max. 5, ook https) volgt de proxy zelf; het eindadres staat in `X-Final-URL`.
// Antwoord: de body van de server, gestreamd, met dezelfde status (200/206/4xx/5xx) en content-type, content-length,
// content-range, accept-ranges. Fouten van de proxy zelf zijn JSON {error}:
//   400 bad_json/bad_url/https_only/bad_range · 401 not_signed_in · 403 host_not_allowed · 405 method_not_allowed
//   413 too_large (> 200 MB) · 429 rate_limited · 502 upstream_failed · 503 unavailable · 504 timeout
import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const MAX_BYTES = 200 * 1024 * 1024;
const TIMEOUT_MS = 120 * 1000;
const RATE_PER_MIN = 600; // per account; ruim genoeg voor HLS (segmenten + afspeellijsten) op een paar schermen
const MAX_REDIRECTS = 5;

function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const ok = /^https:\/\/(www\.)?bingr\.online$/.test(origin) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  return {
    ...(ok ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Expose-Headers": "content-type, content-length, content-range, accept-ranges, x-final-url",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}
const jsonFor = (req: Request) => (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsFor(req), "Content-Type": "application/json", "Cache-Control": "no-store" } });

// ---- inloggen (kort in het geheugen, zodat niet elk HLS-segment de auth-server raakt) ----
const authCache = new Map<string, { id: string; until: number }>();
async function sha256hex(s: string) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}
function jwtExp(token: string): number {
  try {
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const c = JSON.parse(atob(part + "===".slice((part.length + 3) % 4)));
    return typeof c.exp === "number" ? c.exp * 1000 : 0;
  } catch { return 0; }
}
async function userFor(req: Request): Promise<string | number> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return 401;
  const exp = jwtExp(token);
  if (exp && exp < Date.now()) return 401;
  const key = await sha256hex(token);
  const hit = authCache.get(key);
  if (hit && hit.until > Date.now()) return hit.id;
  const { data, error } = await admin.auth.getUser(token);
  if (!error && data?.user) {
    if (authCache.size > 5000) authCache.clear();
    authCache.set(key, { id: data.user.id, until: Math.min(Date.now() + 5 * 60_000, exp || Infinity) });
    return data.user.id;
  }
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? 401 : 503;
}

// ---- toegestane hosts: uit de eigen (versleutelde) servers van het account ----
let keyPromise: Promise<CryptoKey> | null = null;
function sourcesKey(): Promise<CryptoKey> {
  if (!keyPromise) {
    keyPromise = (async () => {
      const raw = Uint8Array.from(atob(Deno.env.get("BINGR_SOURCES_KEY") ?? ""), (c) => c.charCodeAt(0));
      if (raw.length !== 32) throw new Error("sources_key_missing");
      return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
    })();
    keyPromise.catch(() => { keyPromise = null; });
  }
  return keyPromise;
}
async function open_(data: string): Promise<any> {
  const all = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12) }, await sourcesKey(), all.subarray(12));
  return JSON.parse(new TextDecoder().decode(pt));
}
// "tv.example.co.uk" -> "example.co.uk", "a.b.example.com" -> "example.com" (eenvoudige benadering, genoeg voor IPTV-hosts)
function baseDomain(host: string): string {
  if (/^[\d.]+$/.test(host) || host.includes(":")) return host;
  const p = host.split(".");
  if (p.length <= 2) return host;
  const sld = p[p.length - 2];
  const two = p[p.length - 1].length === 2 && /^(co|com|net|org|gov|ac|edu|ne|or)$/.test(sld);
  return p.slice(two ? -3 : -2).join(".");
}
const hostCache = new Map<string, { hosts: Set<string>; until: number }>();
async function allowedHosts(userId: string): Promise<Set<string>> {
  const hit = hostCache.get(userId);
  if (hit && hit.until > Date.now()) return hit.hosts;
  const hosts = new Set<string>();
  const { data: row, error } = await admin.from("account_sources").select("data").eq("user_id", userId).maybeSingle();
  if (error) throw new Error(error.message);
  if (row?.data) {
    const o = await open_(row.data);
    for (const s of Array.isArray(o?.sources) ? o.sources : []) {
      if (!s || s.deleted === true) continue;
      for (const f of ["m3uURL", "epgURL", "serverURL"]) {
        try {
          const v = String(s[f] ?? "").trim();
          if (!v) continue;
          const h = new URL(/^[a-z]+:\/\//i.test(v) ? v : `https://${v}`).hostname.toLowerCase();
          if (h) { hosts.add(h); hosts.add("*." + baseDomain(h)); }
        } catch { /* geen geldige URL */ }
      }
    }
  }
  if (hostCache.size > 5000) hostCache.clear();
  hostCache.set(userId, { hosts, until: Date.now() + 60_000 });
  return hosts;
}
function hostAllowed(host: string, hosts: Set<string>) {
  return hosts.has(host) || hosts.has("*." + baseDomain(host));
}
// nooit naar interne adressen, ook niet via een doorverwijzing
function privateHost(host: string) {
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return true;
  if (host.startsWith("[") || host.includes(":")) return true; // IPv6-literals niet nodig voor IPTV-servers
  const m = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

Deno.serve(async (req) => {
  const json = jsonFor(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsFor(req) });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > 8192) return json({ error: "bad_json" }, 400);
    body = JSON.parse(text);
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
  } catch { return json({ error: "bad_json" }, 400); }

  let target: URL;
  try { target = new URL(String(body.url ?? "")); } catch { return json({ error: "bad_url" }, 400); }
  if (target.protocol !== "https:") return json({ error: "https_only" }, 400);
  if (target.username || target.password) return json({ error: "bad_url" }, 400);
  const range = body.range == null || body.range === "" ? null : String(body.range);
  if (range && !/^bytes=\d*-\d*(,\s*\d*-\d*)*$/.test(range)) return json({ error: "bad_range" }, 400);

  const user = await userFor(req);
  if (user === 401) return json({ error: "not_signed_in" }, 401);
  if (typeof user !== "string") return json({ error: "unavailable" }, 503);

  try {
    const { data: ok, error: re } = await admin.rpc("bingr_rate_hit", { p_key: `proxy:${user}`, p_max: RATE_PER_MIN });
    if (!re && ok === false) return json({ error: "rate_limited" }, 429);

    const hosts = await allowedHosts(user);
    let host = target.hostname.toLowerCase();
    if (privateHost(host) || !hostAllowed(host, hosts)) return json({ error: "host_not_allowed" }, 403);

    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    let res: Response | null = null;
    let url = target;
    try {
      for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
        const headers: Record<string, string> = { "User-Agent": "Mozilla/5.0 (compatible; Bingr/1.0; +https://bingr.online)", "Accept": "*/*", "Accept-Encoding": "identity" };
        if (range) headers["Range"] = range;
        res = await fetch(url, { method: "GET", headers, redirect: "manual", signal: ctl.signal });
        if (res.status < 300 || res.status >= 400 || !res.headers.get("location")) break;
        await res.body?.cancel();
        const next = new URL(res.headers.get("location")!, url);
        host = next.hostname.toLowerCase();
        // een doorverwijzing van een toegestane server (bv. naar een load balancer) mag, maar alleen https en niet intern
        if (next.protocol !== "https:") { clearTimeout(timer); return json({ error: "https_only" }, 400); }
        if (privateHost(host)) { clearTimeout(timer); return json({ error: "host_not_allowed" }, 403); }
        url = next;
        res = null;
      }
    } catch (e) {
      clearTimeout(timer);
      return ctl.signal.aborted ? json({ error: "timeout" }, 504) : json({ error: "upstream_failed" }, 502);
    }
    if (!res) { clearTimeout(timer); return json({ error: "upstream_failed" }, 502); }

    const len = Number(res.headers.get("content-length") ?? "");
    if (len > MAX_BYTES) { clearTimeout(timer); await res.body?.cancel(); return json({ error: "too_large" }, 413); }

    const out = new Headers({ ...corsFor(req), "Cache-Control": "no-store", "X-Final-URL": url.toString() });
    // komt er toch gecomprimeerd iets binnen, dan pakt fetch het uit en klopt de lengte niet meer: dan zonder lengte
    const encoded = /^(gzip|br|deflate|zstd)/i.test(res.headers.get("content-encoding") ?? "");
    for (const h of ["content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag"]) {
      const v = res.headers.get(h);
      if (v && !(encoded && h === "content-length")) out.set(h, v);
    }
    if (!res.body) { clearTimeout(timer); return new Response(null, { status: res.status, headers: out }); }

    // doorstromen zonder te bufferen; boven 200 MB of na 120 s afbreken
    let seen = 0;
    const cap = new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, c) {
        seen += chunk.byteLength;
        if (seen > MAX_BYTES) { ctl.abort(); c.error(new Error("too_large")); return; }
        c.enqueue(chunk);
      },
      flush() { clearTimeout(timer); },
    });
    return new Response(res.body.pipeThrough(cap), { status: res.status, headers: out });
  } catch (e) {
    console.error("web-proxy", e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});
