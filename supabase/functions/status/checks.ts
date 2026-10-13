// Bingr-status: de controles zelf. Elke controle krijgt maximaal TIMEOUT_MS en geeft een CheckResult terug.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { type CheckResult, shortError } from "./logic.ts";

export const TIMEOUT_MS = 10_000;
export const SLOW_MS = 5_000; // trager dan dit = verminderde prestaties
export const TLS_WARN_DAYS = 14;
const UA = "BingrStatus/1.0 (+https://bingr.online/status)";

export interface Monitor {
  id: string;
  kind: string;
  target: string;
  keyword: string | null;
}

export interface Ctx {
  db: SupabaseClient;
  env: (k: string) => string;
  fetch?: typeof fetch;
  /** per run gedeeld: GitHub-releases maar één keer ophalen voor APK en .wgt */
  cache: Map<string, Promise<unknown>>;
}

const now = () => performance.now();
const since = (t: number) => Math.round(performance.now() - t);

/** Alles binnen TIMEOUT_MS; daarna een fout "timeout". */
export function withTimeout<T>(p: (signal: AbortSignal) => Promise<T>, ms = TIMEOUT_MS): Promise<T> {
  const ctl = new AbortController();
  let timer: number | undefined;
  return Promise.race([
    p(ctl.signal),
    new Promise<T>((_, rej) => { timer = setTimeout(() => { ctl.abort(); rej(new Error("timeout")); }, ms); }),
  ]).finally(() => clearTimeout(timer));
}

export async function runCheck(m: Monitor, ctx: Ctx): Promise<CheckResult> {
  try {
    switch (m.kind) {
      case "http": return await checkHttp(m.target, m.keyword, ctx);
      case "auth": return await checkAuth(ctx);
      case "db": return await checkDb(ctx);
      case "fn": return await checkFn(m.target, ctx);
      case "storage": return await checkStorage(m.target || "avatars", ctx);
      case "smtp": return await checkSmtp(ctx);
      case "tls": return await checkTls(m.target, ctx);
      case "gh_asset": return await checkGhAsset(m.target, ctx);
      case "gh_workflow": return await checkGhWorkflow(m.target, ctx);
      default: return { ok: true, skip: true, error: "no_check" }; // bv. devices: alleen informatie
    }
  } catch (e) {
    return { ok: false, error: shortError(e) };
  }
}

const slow = (ms: number) => ms > SLOW_MS;

// ---- website: http(s) + optioneel trefwoord ----
export async function checkHttp(url: string, keyword: string | null, ctx: Ctx): Promise<CheckResult> {
  const f = ctx.fetch ?? fetch;
  const t = now();
  return await withTimeout(async (signal) => {
    const res = await f(url, { signal, redirect: "follow", headers: { "User-Agent": UA, "Cache-Control": "no-cache" } });
    const ms = since(t);
    let body = "";
    if (keyword) body = (await res.text()).slice(0, 2_000_000);
    else await res.body?.cancel();
    if (!res.ok) return { ok: false, code: res.status, ms, error: `HTTP ${res.status}` };
    if (keyword && !body.includes(keyword)) return { ok: false, code: res.status, ms, error: `trefwoord "${keyword.slice(0, 40)}" ontbreekt` };
    return { ok: true, code: res.status, ms, degraded: slow(ms), detail: slow(ms) ? "traag" : null };
  });
}

// ---- server ----
async function checkAuth(ctx: Ctx): Promise<CheckResult> {
  const f = ctx.fetch ?? fetch;
  const base = ctx.env("SUPABASE_URL").replace(/\/+$/, "");
  const key = ctx.env("SUPABASE_ANON_KEY") || ctx.env("SUPABASE_SERVICE_ROLE_KEY");
  const t = now();
  return await withTimeout(async (signal) => {
    const res = await f(`${base}/auth/v1/health`, { signal, headers: { apikey: key } });
    const ms = since(t);
    await res.body?.cancel();
    return res.ok ? { ok: true, code: res.status, ms, degraded: slow(ms) } : { ok: false, code: res.status, ms, error: `HTTP ${res.status}` };
  });
}

async function checkDb(ctx: Ctx): Promise<CheckResult> {
  const t = now();
  return await withTimeout(async (signal) => {
    const { error } = await ctx.db.from("status_monitors").select("id").limit(1).abortSignal(signal);
    const ms = since(t);
    return error ? { ok: false, ms, error: shortError(error.message) } : { ok: true, ms, degraded: slow(ms) };
  });
}

async function checkFn(name: string, ctx: Ctx): Promise<CheckResult> {
  const f = ctx.fetch ?? fetch;
  const base = ctx.env("SUPABASE_URL").replace(/\/+$/, "");
  const t = now();
  return await withTimeout(async (signal) => {
    const res = await f(`${base}/functions/v1/${encodeURIComponent(name)}`, {
      method: "POST", signal, headers: { "Content-Type": "application/json" }, // functies draaien zonder JWT-controle
      body: JSON.stringify({ action: "ping" }),
    });
    const ms = since(t);
    let j: { ok?: boolean } = {};
    try { j = await res.json(); } catch { /* geen json */ }
    if (!res.ok || j.ok !== true) return { ok: false, code: res.status, ms, error: `HTTP ${res.status}${j.ok === true ? "" : " zonder ok"}` };
    return { ok: true, code: res.status, ms, degraded: slow(ms) };
  });
}

async function checkStorage(bucket: string, ctx: Ctx): Promise<CheckResult> {
  const t = now();
  return await withTimeout(async () => {
    const { data, error } = await ctx.db.storage.getBucket(bucket);
    const ms = since(t);
    if (error || !data) return { ok: false, ms, error: shortError(error?.message ?? "bucket ontbreekt") };
    return { ok: true, ms, degraded: slow(ms) };
  });
}

// ---- e-mail: verbinden met de SMTP-server en wachten op "220" (geen inloggen, geen mail) ----
async function checkSmtp(ctx: Ctx): Promise<CheckResult> {
  const host = ctx.env("BINGR_SMTP_HOST");
  if (!host) return { ok: true, skip: true, error: "niet ingesteld" };
  const port = Number(ctx.env("BINGR_SMTP_PORT") || 465);
  const t = now();
  let conn: Deno.Conn | null = null;
  try {
    return await withTimeout(async () => {
      conn = port === 465 ? await Deno.connectTls({ hostname: host, port }) : await Deno.connect({ hostname: host, port });
      const buf = new Uint8Array(512);
      const n = await conn.read(buf);
      const ms = since(t);
      const line = new TextDecoder().decode(buf.subarray(0, n ?? 0));
      try { await conn.write(new TextEncoder().encode("QUIT\r\n")); } catch { /* */ }
      if (!line.startsWith("220")) return { ok: false, ms, error: `onverwacht antwoord: ${line.slice(0, 40)}` };
      return { ok: true, ms, code: 220, degraded: slow(ms) };
    });
  } finally {
    try { (conn as Deno.Conn | null)?.close(); } catch { /* al dicht */ }
  }
}

// ---- TLS-certificaat: dagen tot verlopen ----
// Deno geeft het certificaat van de server niet terug; daarom een eigen TLS 1.2-ClientHello. In TLS 1.2 stuurt de
// server zijn certificaat onversleuteld mee, daaruit lezen we notAfter. Daarna wordt de verbinding verbroken.
export function clientHello(host: string): Uint8Array {
  const u16 = (n: number) => [(n >> 8) & 255, n & 255];
  const u24 = (n: number) => [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  const name = [...new TextEncoder().encode(host)];
  const suites = [0xc02f, 0xc030, 0xc02b, 0xc02c, 0xcca8, 0xcca9, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035].flatMap(u16);
  const ext = (type: number, data: number[]) => [...u16(type), ...u16(data.length), ...data];
  const sni = ext(0x0000, [...u16(name.length + 3), 0, ...u16(name.length), ...name]);
  const groups = ext(0x000a, [...u16(6), 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18]);
  const points = ext(0x000b, [1, 0]);
  const sigs = [0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601, 0x0201].flatMap(u16);
  const sigalg = ext(0x000d, [...u16(sigs.length), ...sigs]);
  const exts = [...sni, ...groups, ...points, ...sigalg];
  const random = [...crypto.getRandomValues(new Uint8Array(32))];
  const body = [0x03, 0x03, ...random, 0, ...u16(suites.length), ...suites, 1, 0, ...u16(exts.length), ...exts];
  const hs = [0x01, ...u24(body.length), ...body];
  return new Uint8Array([0x16, 0x03, 0x01, ...u16(hs.length), ...hs]);
}

/** Leest TLS-records tot het Certificate-bericht; geeft het eerste (server)certificaat als DER. */
export async function readServerCert(read: (b: Uint8Array) => Promise<number | null>): Promise<Uint8Array> {
  let raw = new Uint8Array(0);
  let hs = new Uint8Array(0);
  const append = (a: Uint8Array, b: Uint8Array) => { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; };
  const buf = new Uint8Array(16384);
  for (let guard = 0; guard < 400; guard++) {
    // hele records uit raw halen
    while (raw.length >= 5) {
      const type = raw[0], len = (raw[3] << 8) | raw[4];
      if (raw.length < 5 + len) break;
      const frag = raw.subarray(5, 5 + len);
      raw = raw.slice(5 + len);
      if (type === 21) throw new Error(`tls alert ${frag[1] ?? "?"} (alleen TLS 1.3?)`);
      if (type !== 22) continue;
      hs = append(hs, frag);
      // handshake-berichten doorlopen
      let off = 0;
      while (hs.length - off >= 4) {
        const mt = hs[off], ml = (hs[off + 1] << 16) | (hs[off + 2] << 8) | hs[off + 3];
        if (hs.length - off - 4 < ml) break;
        if (mt === 11) {
          const b = hs.subarray(off + 4, off + 4 + ml);
          const l1 = (b[3] << 16) | (b[4] << 8) | b[5];
          return b.slice(6, 6 + l1);
        }
        if (mt === 14) throw new Error("geen certificaat ontvangen");
        off += 4 + ml;
      }
      hs = hs.slice(off);
    }
    const n = await read(buf);
    if (n === null || n === 0) throw new Error("verbinding gesloten");
    raw = append(raw, buf.subarray(0, n));
    if (raw.length > 512 * 1024) throw new Error("te veel data");
  }
  throw new Error("geen certificaat gevonden");
}

/** notAfter uit een X.509-certificaat (DER). */
export function certNotAfter(der: Uint8Array): Date {
  let p = 0;
  const tlv = () => {
    const tag = der[p++];
    let len = der[p++];
    if (len & 0x80) { const k = len & 0x7f; len = 0; for (let i = 0; i < k; i++) len = (len << 8) | der[p++]; }
    const start = p;
    return { tag, start, len, end: start + len };
  };
  const cert = tlv(); if (cert.tag !== 0x30) throw new Error("geen certificaat");
  const tbs = tlv(); if (tbs.tag !== 0x30) throw new Error("geen tbsCertificate");
  let e = tlv();
  if (e.tag === 0xa0) { p = e.end; e = tlv(); } // versie
  p = e.end; // serienummer
  p = tlv().end; // handtekeningalgoritme
  p = tlv().end; // uitgever
  const validity = tlv(); if (validity.tag !== 0x30) throw new Error("geen geldigheid");
  p = tlv().end; // notBefore
  const na = tlv();
  const s = new TextDecoder().decode(der.subarray(na.start, na.end));
  let y: number, rest: string;
  if (na.tag === 0x17) { const yy = +s.slice(0, 2); y = yy < 50 ? 2000 + yy : 1900 + yy; rest = s.slice(2); }
  else if (na.tag === 0x18) { y = +s.slice(0, 4); rest = s.slice(4); }
  else throw new Error("onbekend tijdformaat");
  const d = new Date(Date.UTC(y, +rest.slice(0, 2) - 1, +rest.slice(2, 4), +rest.slice(4, 6), +rest.slice(6, 8), +(rest.slice(8, 10) || 0)));
  if (isNaN(d.getTime())) throw new Error("ongeldige datum");
  return d;
}

export function tlsResult(notAfter: Date, ms: number, nowMs = Date.now()): CheckResult {
  const days = Math.floor((notAfter.getTime() - nowMs) / 864e5);
  const detail = `${days} dagen geldig (tot ${notAfter.toISOString().slice(0, 10)})`;
  if (days < 0) return { ok: false, ms, error: `certificaat verlopen op ${notAfter.toISOString().slice(0, 10)}`, detail };
  return { ok: true, ms, degraded: days < TLS_WARN_DAYS, detail, code: days };
}

export async function checkTls(target: string, _ctx: Ctx, port = 443): Promise<CheckResult> {
  const host = target.replace(/^https?:\/\//, "").replace(/[/:].*$/, "");
  const t = now();
  let conn: Deno.Conn | null = null;
  try {
    return await withTimeout(async () => {
      conn = await Deno.connect({ hostname: host, port });
      await conn.write(clientHello(host));
      const c = conn;
      let der: Uint8Array;
      try { der = await readServerCert((b) => c.read(b)); } catch (e) {
        // server wil geen TLS 1.2 (alleen 1.3): dan kunnen we de datum niet lezen; niet als storing tellen
        if (/tls alert/.test(String((e as Error).message))) return { ok: true, skip: true, ms: since(t), error: "alleen TLS 1.3: vervaldatum onbekend" };
        throw e;
      }
      return tlsResult(certNotAfter(der), since(t));
    });
  } finally {
    try { (conn as Deno.Conn | null)?.close(); } catch { /* */ }
  }
}

// ---- GitHub: downloads en de Apple-build. Eerst de API; bij de limiet (60/uur zonder token) de gewone webpagina ----
function ghHeaders(ctx: Ctx): Record<string, string> {
  const h: Record<string, string> = { "User-Agent": UA, Accept: "application/vnd.github+json" };
  const tok = ctx.env("BINGR_GITHUB_TOKEN");
  if (tok) h.Authorization = `Bearer ${tok}`;
  return h;
}
const limited = (res: Response) => res.status === 429 || (res.status === 403 && res.headers.get("x-ratelimit-remaining") === "0");

async function latestAssets(repo: string, ctx: Ctx, signal: AbortSignal): Promise<{ tag: string; urls: string[] }> {
  const key = `rel:${repo}`;
  if (!ctx.cache.has(key)) {
    ctx.cache.set(key, (async () => {
      const f = ctx.fetch ?? fetch;
      const res = await f(`https://api.github.com/repos/${repo}/releases/latest`, { signal, headers: ghHeaders(ctx) });
      if (res.ok) {
        const j = await res.json();
        return { tag: String(j.tag_name ?? ""), urls: (j.assets ?? []).map((a: { browser_download_url: string }) => a.browser_download_url) };
      }
      await res.body?.cancel();
      if (!limited(res)) throw new Error(`GitHub API HTTP ${res.status}`);
      // terugval zonder API: /releases/latest verwijst naar de tag, expanded_assets toont de bestanden
      const r1 = await f(`https://github.com/${repo}/releases/latest`, { signal, redirect: "manual", headers: { "User-Agent": UA } });
      await r1.body?.cancel();
      const loc = r1.headers.get("location") ?? "";
      const tag = decodeURIComponent(loc.split("/releases/tag/")[1] ?? "");
      if (!tag) throw new Error("geen release gevonden");
      const r2 = await f(`https://github.com/${repo}/releases/expanded_assets/${encodeURIComponent(tag)}`, { signal, headers: { "User-Agent": UA } });
      const html = await r2.text();
      const urls = [...html.matchAll(/href="(\/[^"]+\/releases\/download\/[^"]+)"/g)].map((m) => `https://github.com${m[1]}`);
      return { tag, urls };
    })());
  }
  return await (ctx.cache.get(key) as Promise<{ tag: string; urls: string[] }>);
}

export async function checkGhAsset(target: string, ctx: Ctx): Promise<CheckResult> {
  const [repo, ext] = target.split("|");
  const f = ctx.fetch ?? fetch;
  const t = now();
  return await withTimeout(async (signal) => {
    const rel = await latestAssets(repo, ctx, signal);
    const url = rel.urls.find((u) => u.toLowerCase().endsWith((ext || "").toLowerCase()));
    if (!url) return { ok: false, ms: since(t), error: `geen ${ext}-bestand in release ${rel.tag}` };
    const res = await f(url, { signal, headers: { "User-Agent": UA, Range: "bytes=0-0" }, redirect: "follow" });
    await res.body?.cancel();
    const ms = since(t);
    const name = decodeURIComponent(url.split("/").pop() ?? "");
    if (res.status !== 200 && res.status !== 206) return { ok: false, code: res.status, ms, error: `download HTTP ${res.status}`, detail: name };
    return { ok: true, code: res.status, ms, detail: name };
  });
}

export async function checkGhWorkflow(target: string, ctx: Ctx): Promise<CheckResult> {
  const [repo, file, branch = "main"] = target.split("|");
  const f = ctx.fetch ?? fetch;
  const t = now();
  return await withTimeout(async (signal) => {
    const res = await f(`https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(file)}/runs?branch=${encodeURIComponent(branch)}&status=completed&per_page=1`,
      { signal, headers: ghHeaders(ctx) });
    if (res.ok) {
      const j = await res.json();
      const run = j.workflow_runs?.[0];
      const ms = since(t);
      if (!run) return { ok: true, skip: true, error: "nog geen build" };
      const detail = `run ${run.run_number} (${String(run.head_sha ?? "").slice(0, 7)})`;
      return run.conclusion === "success" ? { ok: true, ms, detail } : { ok: false, ms, error: `laatste build: ${run.conclusion}`, detail };
    }
    await res.body?.cancel();
    if (!limited(res)) return { ok: false, code: res.status, ms: since(t), error: `GitHub API HTTP ${res.status}` };
    // terugval: de statusbadge (geen API-limiet)
    const b = await f(`https://github.com/${repo}/actions/workflows/${encodeURIComponent(file)}/badge.svg?branch=${encodeURIComponent(branch)}`,
      { signal, headers: { "User-Agent": UA } });
    const svg = await b.text();
    const ms = since(t);
    if (/>\s*passing\s*</i.test(svg)) return { ok: true, ms, detail: "badge: passing" };
    if (/>\s*failing\s*</i.test(svg)) return { ok: false, ms, error: "laatste build: failure", detail: "badge: failing" };
    return { ok: true, skip: true, ms, error: "GitHub-limiet bereikt" };
  });
}
