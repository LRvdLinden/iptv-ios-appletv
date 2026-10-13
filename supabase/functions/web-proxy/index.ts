// Bingr: proxy voor de webspeler (build 62). IPTV-servers sturen zelden CORS-headers en draaien vaak op http; een
// https-pagina (bingr.online) mag niets van http laden (mixed content). De proxy haalt het op aan de serverkant.
//
// POST /functions/v1/web-proxy, headers `apikey` en `Authorization: Bearer <access_token>`:
//   {url, range?}       body van `url` (http of https), gestreamd; range bv. "bytes=0-1048575"
//   {action:"token"}    → {token, expires_at}: kort geldig (6 uur) token voor de GET-vorm
//   {action:"ping"}     → {ok:true}: statuscontrole, zonder inloggen
// GET /functions/v1/web-proxy?u=<base64url van de URL>&t=<token>[&s=<handtekening>]
//   voor <video>, hls.js en Safari's eigen HLS-speler (die geen headers kunnen meesturen). De Range-header van de
//   browser gaat mee, begrensd tot 8 MB per aanvraag; negeert de server Range, dan maakt de proxy zelf de 206.
//   HLS-afspeellijsten worden herschreven: elke URI wordt een GET-URL van de proxy (met `s`).
// Alleen hosts uit de eigen servers van het account (get_sources: m3uURL, epgURL, serverURL) mogen, plus subdomeinen
// van hetzelfde domein; of een URL die de proxy zelf in een afspeellijst zette (`s` = HMAC over gebruiker + URL).
// Doorverwijzingen (max. 5, http of https) volgt de proxy zelf, ook naar andere hosts, maar nooit naar interne
// adressen; het eindadres staat in `X-Final-URL`.
// Antwoord: de body van de server, gestreamd, met dezelfde status (200/206/4xx/5xx) en content-type, content-length,
// content-range, accept-ranges. Fouten van de proxy zelf zijn JSON {error}:
//   400 bad_json/bad_url/bad_range · 401 not_signed_in/bad_token · 403 host_not_allowed · 405 method_not_allowed
//   413 too_large (> 200 MB) · 416 (bereik voorbij het einde) · 429 rate_limited · 502 upstream_failed/range_not_supported
//   · 503 unavailable · 504 timeout
import { createClient } from "jsr:@supabase/supabase-js@2";
import { b64url, isHlsPlaylist, rewritePlaylist, unb64url } from "./hls.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const SELF_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "") + "/functions/v1/web-proxy";

const MAX_BYTES = 200 * 1024 * 1024;
const MAX_PLAYLIST = 4 * 1024 * 1024;
const TIMEOUT_MS = 120 * 1000;
const RATE_PER_MIN = 600; // per account; ruim genoeg voor HLS (segmenten + afspeellijsten) op een paar schermen
const MAX_REDIRECTS = 5;
const TOKEN_TTL_S = 6 * 3600;
// GET met een open bereik (bytes=N-) voor een bestand: in stukken van 8 MB, zodat één aanvraag binnen de tijdslimiet
// blijft; de browser vraagt zelf het volgende stuk (206 met Content-Range).
const GET_CHUNK = 8 * 1024 * 1024;
// negeert de server Range, dan slaat de proxy zelf hooguit zoveel over om bij het gevraagde stuk te komen
const MAX_SKIP = 512 * 1024 * 1024;

function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const ok = /^https:\/\/(www\.)?bingr\.online$/.test(origin) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  return {
    ...(ok ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, range",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
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

// ---- sleutels: afgeleid van BINGR_SOURCES_KEY (staat alleen op de server) ----
function rawSourcesKey(): Uint8Array {
  const raw = Uint8Array.from(atob(Deno.env.get("BINGR_SOURCES_KEY") ?? ""), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("sources_key_missing");
  return raw;
}
let keyPromise: Promise<CryptoKey> | null = null;
function sourcesKey(): Promise<CryptoKey> {
  if (!keyPromise) {
    keyPromise = (async () => crypto.subtle.importKey("raw", rawSourcesKey(), "AES-GCM", false, ["decrypt"]))();
    keyPromise.catch(() => { keyPromise = null; });
  }
  return keyPromise;
}
// aparte HMAC-sleutel voor tokens en handtekeningen: HMAC(BINGR_SOURCES_KEY, label), nooit de AES-sleutel zelf
let macPromise: Promise<CryptoKey> | null = null;
function macKey(): Promise<CryptoKey> {
  if (!macPromise) {
    macPromise = (async () => {
      const base = await crypto.subtle.importKey("raw", rawSourcesKey(), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
      const sub = new Uint8Array(await crypto.subtle.sign("HMAC", base, new TextEncoder().encode("bingr-web-proxy-mac-v1")));
      return crypto.subtle.importKey("raw", sub, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    })();
    macPromise.catch(() => { macPromise = null; });
  }
  return macPromise;
}
async function mac(msg: string, len = 32): Promise<string> {
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await macKey(), new TextEncoder().encode(msg)));
  return b64url(sig.subarray(0, len));
}
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
/** token = <user-id>.<verloopt (unix s)>.<HMAC> */
async function makeToken(userId: string) {
  const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_S;
  return { token: `${userId}.${exp}.${await mac(`t:${userId}.${exp}`)}`, expires_at: new Date(exp * 1000).toISOString() };
}
async function tokenUser(t: string): Promise<string | null> {
  const m = /^([0-9a-f-]{36})\.(\d{9,11})\.([A-Za-z0-9_-]{43})$/i.exec(t);
  if (!m) return null;
  if (Number(m[2]) * 1000 < Date.now()) return null;
  return safeEqual(await mac(`t:${m[1]}.${m[2]}`), m[3]) ? m[1].toLowerCase() : null;
}
/** Handtekening van een URL die de proxy zelf in een afspeellijst zette (mag dan ook naar een andere host, bv. een CDN). */
const urlSig = (userId: string, url: string) => mac(`u:${userId}:${url}`, 16);

// ---- toegestane hosts: uit de eigen (versleutelde) servers van het account ----
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
function privateIPv4(ip: string) {
  const m = ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || (a === 198 && (b === 18 || b === 19)) || a >= 224;
}
function privateIPv6(ip: string) {
  const v = ip.toLowerCase();
  if (v === "::" || v === "::1") return true;
  if (/^f[cd]/.test(v) || /^fe[89ab]/.test(v)) return true; // ULA en link-local
  const mapped = v.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  return mapped ? privateIPv4(mapped[1]) : false;
}
function privateHost(host: string) {
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return true;
  if (host.startsWith("[") || host.includes(":")) return true; // IPv6-literals niet nodig voor IPTV-servers
  if (/^\d+$/.test(host) || /^0x/i.test(host)) return true; // 2130706433, 0x7f000001
  return privateIPv4(host);
}
// na DNS: wijst de naam naar een intern adres? (als de runtime geen DNS-opvraging kent, telt alleen de naamcontrole)
const dnsCache = new Map<string, { bad: boolean; until: number }>();
async function resolvesPrivate(host: string): Promise<boolean> {
  if (/^[\d.]+$/.test(host)) return privateIPv4(host);
  const hit = dnsCache.get(host);
  if (hit && hit.until > Date.now()) return hit.bad;
  let bad = false;
  try {
    const look = (t: "A" | "AAAA") => Promise.race([
      Deno.resolveDns(host, t).catch(() => [] as string[]),
      new Promise<string[]>((r) => setTimeout(() => r([]), 2500)),
    ]);
    const [a, aaaa] = await Promise.all([look("A"), look("AAAA")]);
    bad = a.some(privateIPv4) || aaaa.some(privateIPv6);
  } catch { /* geen DNS in deze runtime */ }
  if (dnsCache.size > 5000) dnsCache.clear();
  dnsCache.set(host, { bad, until: Date.now() + 5 * 60_000 });
  return bad;
}

async function proxy(req: Request, opts: { target: URL; range: string | null; user: string; trusted: boolean; get: boolean; token?: string }) {
  const json = jsonFor(req);
  const { target, user, get } = opts;
  let range = opts.range;
  const { data: ok, error: re } = await admin.rpc("bingr_rate_hit", { p_key: `proxy:${user}`, p_max: RATE_PER_MIN });
  if (!re && ok === false) return json({ error: "rate_limited" }, 429);

  let host = target.hostname.toLowerCase();
  if (privateHost(host)) return json({ error: "host_not_allowed" }, 403);
  if (!opts.trusted && !hostAllowed(host, await allowedHosts(user))) return json({ error: "host_not_allowed" }, 403);
  if (await resolvesPrivate(host)) return json({ error: "host_not_allowed" }, 403);

  // GET-bereik voor iets dat geen afspeellijst is: begrenzen tot GET_CHUNK. Open (bytes=N-, Chrome/Firefox) én gesloten
  // bereiken die groter zijn (Safari vraagt bytes=0-<eind>): anders loopt een film van > 200 MB op too_large (413)
  const looksPlaylist = /\.m3u8?$/i.test(target.pathname);
  let rangeFrom: number | null = null;
  if (get && range && !looksPlaylist) {
    const m = /^bytes=(\d+)-(\d*)$/.exec(range);
    if (m) {
      const from = Number(m[1]);
      const to = m[2] === "" ? Infinity : Number(m[2]);
      if (to >= from) {
        rangeFrom = from;
        if (to - from + 1 > GET_CHUNK) range = `bytes=${from}-${from + GET_CHUNK - 1}`;
      }
    }
  }

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
      // doorverwijzingen (bv. naar een load balancer of CDN): http of https, elke publieke host, nooit intern
      if (next.protocol !== "https:" && next.protocol !== "http:") { clearTimeout(timer); return json({ error: "bad_url" }, 400); }
      if (next.username || next.password) { clearTimeout(timer); return json({ error: "bad_url" }, 400); }
      if (privateHost(host) || await resolvesPrivate(host)) { clearTimeout(timer); return json({ error: "host_not_allowed" }, 403); }
      url = next;
      res = null;
    }
  } catch {
    clearTimeout(timer);
    return ctl.signal.aborted ? json({ error: "timeout" }, 504) : json({ error: "upstream_failed" }, 502);
  }
  if (!res) { clearTimeout(timer); return json({ error: "upstream_failed" }, 502); }

  const len = Number(res.headers.get("content-length") ?? "");
  const ctype = res.headers.get("content-type") ?? "";
  const out = new Headers({ ...corsFor(req), "Cache-Control": "no-store", "X-Final-URL": url.toString() });

  // de server negeert Range (200 met het hele bestand, komt voor bij Xtream-servers voor /movie/ en /series/):
  // zelf een 206 maken voor het gevraagde stuk (tot GET_CHUNK; vanaf een verschuiving die we kunnen overslaan),
  // zodat <video> het bestand toch in stukken kan afspelen en doorspoelen
  const plainMedia = !/mpegurl/i.test(ctype) && !/\.m3u8$/i.test(url.pathname) && !looksPlaylist;
  if (get && rangeFrom != null && res.status === 200 && res.body && plainMedia && len > 0 && Number.isFinite(len)) {
    if (rangeFrom >= len) {
      clearTimeout(timer); await res.body.cancel();
      out.set("content-range", `bytes */${len}`);
      return new Response(null, { status: 416, headers: out });
    }
    if (rangeFrom > MAX_SKIP) { clearTimeout(timer); await res.body.cancel(); return json({ error: "range_not_supported" }, 502); }
    const want = Math.min(GET_CHUNK, len - rangeFrom);
    const from = rangeFrom;
    let skip = from, sent = 0;
    const slice = new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, c) {
        let part = chunk;
        if (skip > 0) {
          if (part.byteLength <= skip) { skip -= part.byteLength; return; }
          part = part.subarray(skip); skip = 0;
        }
        if (sent + part.byteLength > want) part = part.subarray(0, want - sent);
        if (part.byteLength) { c.enqueue(part); sent += part.byteLength; }
        if (sent >= want) { clearTimeout(timer); c.terminate(); }
      },
      flush() { clearTimeout(timer); },
    });
    if (ctype) out.set("content-type", ctype);
    out.set("content-length", String(want));
    out.set("content-range", `bytes ${from}-${from + want - 1}/${len}`);
    out.set("accept-ranges", "bytes");
    return new Response(res.body.pipeThrough(slice), { status: 206, headers: out });
  }

  if (len > MAX_BYTES) { clearTimeout(timer); await res.body?.cancel(); return json({ error: "too_large" }, 413); }
  if (get && res.status === 200 && /^image\//i.test(ctype)) out.set("Cache-Control", "private, max-age=86400");

  // GET-vorm + HLS-afspeellijst: herschrijven, zodat de browser alles via de proxy ophaalt
  const maybePlaylist = /mpegurl/i.test(ctype) || /\.m3u8$/i.test(url.pathname) || looksPlaylist;
  if (get && res.ok && res.status !== 206 && maybePlaylist && !(len > MAX_PLAYLIST) && res.body) {
    let text: string;
    try {
      const reader = res.body.getReader();
      const parts: Uint8Array[] = [];
      let n = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        n += value.byteLength;
        if (n > MAX_PLAYLIST) { await reader.cancel(); clearTimeout(timer); return json({ error: "too_large" }, 413); }
        parts.push(value);
      }
      const all = new Uint8Array(n);
      let o = 0;
      for (const p of parts) { all.set(p, o); o += p.byteLength; }
      text = new TextDecoder().decode(all);
    } catch {
      clearTimeout(timer);
      return ctl.signal.aborted ? json({ error: "timeout" }, 504) : json({ error: "upstream_failed" }, 502);
    }
    clearTimeout(timer);
    if (isHlsPlaylist(text)) {
      const sigs = new Map<string, string>();
      const urls: string[] = [];
      rewritePlaylist(text, url.toString(), (abs) => { urls.push(abs); return abs; });
      await Promise.all(urls.map(async (u) => { if (!sigs.has(u)) sigs.set(u, await urlSig(user, u)); }));
      const t = encodeURIComponent(opts.token ?? "");
      text = rewritePlaylist(text, url.toString(), (abs) => `${SELF_URL}?u=${b64url(abs)}&t=${t}&s=${sigs.get(abs)}`);
      out.set("content-type", "application/vnd.apple.mpegurl");
    } else if (ctype) out.set("content-type", ctype);
    return new Response(text, { status: res.status, headers: out });
  }

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
}

function parseTarget(raw: string): URL | null {
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  if (u.username || u.password) return null;
  return u;
}

Deno.serve(async (req) => {
  const json = jsonFor(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsFor(req) });
  try {
    if (req.method === "GET") {
      const q = new URL(req.url).searchParams;
      let raw = "";
      try { raw = unb64url(q.get("u") ?? ""); } catch { return json({ error: "bad_url" }, 400); }
      const target = parseTarget(raw);
      if (!target) return json({ error: "bad_url" }, 400);
      const t = q.get("t") ?? "";
      const user = await tokenUser(t);
      if (!user) return json({ error: "bad_token" }, 401);
      const range = req.headers.get("Range");
      if (range && !/^bytes=\d*-\d*(,\s*\d*-\d*)*$/.test(range)) return json({ error: "bad_range" }, 400);
      const s = q.get("s") ?? "";
      const trusted = !!s && safeEqual(await urlSig(user, target.toString()), s);
      return await proxy(req, { target, range, user, trusted, get: true, token: t });
    }
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    let body: Record<string, unknown>;
    try {
      const text = await req.text();
      if (text.length > 8192) return json({ error: "bad_json" }, 400);
      body = JSON.parse(text);
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    } catch { return json({ error: "bad_json" }, 400); }

    if (body.action === "ping") return json({ ok: true }); // statuspagina: werkt de proxy (zonder inloggen)

    if (body.action === "token") {
      const user = await userFor(req);
      if (user === 401) return json({ error: "not_signed_in" }, 401);
      if (typeof user !== "string") return json({ error: "unavailable" }, 503);
      return json(await makeToken(user));
    }

    const target = parseTarget(String(body.url ?? ""));
    if (!target) return json({ error: "bad_url" }, 400);
    const range = body.range == null || body.range === "" ? null : String(body.range);
    if (range && !/^bytes=\d*-\d*(,\s*\d*-\d*)*$/.test(range)) return json({ error: "bad_range" }, 400);

    const user = await userFor(req);
    if (user === 401) return json({ error: "not_signed_in" }, 401);
    if (typeof user !== "string") return json({ error: "unavailable" }, 503);
    return await proxy(req, { target, range, user, trusted: false, get: false });
  } catch (e) {
    console.error("web-proxy", e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});
