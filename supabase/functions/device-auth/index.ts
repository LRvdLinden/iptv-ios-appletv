// Bingr: tv-koppeling (QR-login) en account verwijderen.
// POST /functions/v1/device-auth met JSON {action, ...}; header `apikey` altijd, `Authorization: Bearer <access_token>` bij approve/delete_account.
//   start           {device}            -> {code, poll_secret, url, expires_in, interval}
//                   build 95: max. 10 per IP per 10 minuten -> 429 {error:"rate_limited"}
//   poll            {code, poll_secret} -> {status: pending|approved|expired, token_hash?, email?}
//                   Account dat de code goedkeurde is geblokkeerd -> 403 {status:"banned", error:"user_banned", banned:true}
//   Alle acties met inloggen: geblokkeerd account -> 401 {error:"user_banned", banned:true, reason:"banned"} (docs/ACCOUNT.md)
//                   Bij approved: POST /auth/v1/verify {type:"magiclink", token_hash} geeft de tv een eigen sessie.
//   code_info       {code}   (ingelogd)  -> {ok, device, kind, label, created_at, age_s, expires_in}
//                   soort apparaat bij een code (naamveld op /koppelen); created_at/age_s (seconden sinds aanmaken, door de server
//                   berekend) en expires_in voor de bevestigingsstap ("zojuist", "3 minuten geleden"). device = wat het apparaat zelf opgaf.
//                   Ongeldige/verlopen code (of al door een ander account goedgekeurd) -> 404 {error:"invalid_code"}
//                   build 95: code_info en approve samen max. 30 per account en 60 per IP per minuut -> 429 {error:"rate_limited"}
//                   en max. 20 FOUTE codes per account en per IP per uur (daarna 429 tot het uur om is; raden van codes)
//   approve         {code, name?} (ingelogd) -> {ok, device, name}
//                   name (optioneel, max. 40 tekens): eigen naam voor het apparaat ("Apple TV - Woonkamer"). Wordt bewaard bij
//                   de code; zodra de tv inlogt en zich aanmeldt (register_device van dezelfde soort, binnen 15 minuten) wordt het
//                   de naam in account_devices met custom_name = true, zodat de standaardnaam van de app hem niet overschrijft.
//                   Te lang -> 400 {error:"name_too_long"}.
//   delete_account  {password} (ingelogd) -> {ok}
//                   H1: huidig wachtwoord verplicht (server controleert het met signInWithPassword op het e-mailadres van het
//                   account). Geen of fout wachtwoord -> 403 {error:"wrong_password"}; max. 5 per account en 20 per IP per
//                   10 minuten -> 429 {error:"rate_limited"}; auth-server onbereikbaar -> 503 {error:"unavailable"}.
//   register_device {device_id, name, platform, app_version?, os_version?} (ingelogd) -> {ok, limit} | 403 {error:"device_limit", limit, plan, devices}
//                   limit = apparatenlimiet van het abonnement (gratis 8, lifetime 15, of eigen limiet uit het beheer)
//   heartbeat       {device_id, app_version?, os_version?, platform?} (ingelogd) -> {ok, entitlements} | {revoked:true}  (werkt ook "laatst gebruikt" bij)
//                   Ongeldig/verlopen token -> 401 {error:"not_signed_in"} (app ververst en probeert opnieuw); auth-server onbereikbaar -> 503.
//   list_devices    {device_id?} (ingelogd) -> {limit, devices:[{device_id,name,platform,created_at,last_seen_at,current}]}
//   rename_device   {device_id, name} (ingelogd) -> {ok}   (eigen naam; register_device overschrijft die niet meer)
//   remove_device   {device_id} (ingelogd) -> {ok}  (trekt de sessie van dat apparaat in)
//   get_sources     {}       (ingelogd)  -> {sources:[…], mainSourceID, updatedAt}
//   put_sources     {sources, mainSourceID} (ingelogd) -> {ok, updatedAt}   (versleuteld opgeslagen)
//                   Build 60: de server voegt samen per bron-id (nieuwste updatedAt wint, ook tombstones); een bron die
//                   alleen op de server staat blijft staan. Verwijderen gaat dus altijd via een tombstone.
//   get_state       {sections?:[naam…]} (ingelogd) -> {sections:{naam:{data, updatedAt}}}
//   put_state       {section, data}      (ingelogd) -> {ok, updatedAt}     (versleuteld; data = willekeurige JSON)
//   delete_state    {section}            (ingelogd) -> {ok}
//   stream_start    {device_id, profile_id, profile_name, title, kind, content_id, series_id?, series_title?, tz?} (ingelogd)
//                   -> {ok, limit} | 403 {error:"stream_limit", limit, plan, streams:[…]}   (limit: gratis 1, lifetime 3, of eigen limiet;
//                   build 68: series_id/series_title/tz voor statistieken)
//   stream_ping     {device_id, title?, kind?, content_id?, series_id?, series_title?} (ingelogd, elke 30 s) -> {ok} | {stopped:true}
//   stream_stop     {device_id} (ingelogd) -> {ok}
//                   start/ping/stop schrijven de kijktijd bij in account_watch_stats (max. 3 min per keer).
//   list_streams    {} (ingelogd) -> {limit, streams:[{device_id, device_name, platform, profile_id, profile_name, title, kind, started_at, signed_in_at}]}
//   watch_log       {days?:7} (ingelogd) -> {entries:[{device_name, platform, profile_id, profile_name, title, kind, started_at, ended_at, minutes}]}
//   watch_stats     {period?:"week"|"month"|"year", offset?:0, profile_id?, tz?} (ingelogd) -> statistieken (build 68, zie docs/ACCOUNT.md)
//   delete_watch_stats {profile_id?} (ingelogd) -> {ok}   (zonder profile_id: alle profielen)
//   announcements   {lang?} (ingelogd) -> {items:[]}  (build 62; sinds build 117 altijd leeg: berichten alleen als pushmelding)
//   ping            {}                  -> {ok:true}  (statuscontrole, zonder inloggen)
//   config          {platform?, device_id?} (ingelogd) -> {traktClientID?, traktClientSecret?, openSubtitlesAPIKey, omdbAPIKey, tmdbAPIKey, entitlements}
//                   security L5: Trakt-sleutels alleen voor Lifetime (functie trakt); max. 60 per uur per account (429 rate_limited).
//                   App-sleutels staan alleen als function-secrets op de server (BINGR_*), nooit in de openbare repo.
//   entitlements    {platform?, device_id?} (ingelogd) -> {plan:"free"|"lifetime", limits:{streams, devices, servers|null},
//                   features:{stats, now_watching, trakt, multi_server, themes}, upgrade:{url, link, price, price_en}}
//                   Abonnementen (Gratis / Lifetime, docs/ACCOUNT.md): limieten en functies uit account_plans (geen rij = gratis),
//                   upgrade.link per platform uit app_settings.upgrade_link (platform uit de aanvraag, anders van het apparaat).
//                   heartbeat geeft hetzelfde object als `entitlements`. Gratis: list_streams, watch_log -> 403
//                   {error:"feature_locked", feature:"now_watching", plan:"free"}; watch_stats -> 403 {…, feature:"stats"}.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { buildStats, DEFAULT_TZ, periodRange, todayIn, validTz } from "./stats.ts";
import { cleanDeviceName, deviceKind, deviceTypeLabel } from "./naming.ts";
import { type PasswordCheck, passwordCheckResult } from "./password.ts";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { clientIp } from "../_shared/ip.ts";
import {
  entitlements, featureLocked, limitsFor, normalizePlan, normalizePlatform, normalizeUpgradeLink, platformFromDevice,
  type PlanRow, type UpgradeLink,
} from "../_shared/plans.ts";

const SITE = Deno.env.get("BINGR_SITE") ?? "https://bingr.online";
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // zonder 0/O, 1/I
function randomCode(n = 6) {
  const b = crypto.getRandomValues(new Uint8Array(n));
  return Array.from(b, (x) => ALPHABET[x % ALPHABET.length]).join("");
}
function randomSecret() {
  return Array.from(crypto.getRandomValues(new Uint8Array(24)), (x) => x.toString(16).padStart(2, "0")).join("");
}
const normalize = (c: unknown) => String(c ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const STREAM_TTL_MS = 90 * 1000; // een stream zonder ping na 90 s telt niet meer mee
function sessionIdFrom(req: Request): string | null {
  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(part + "===".slice((part.length + 3) % 4)));
    return typeof claims.session_id === "string" ? claims.session_id : null;
  } catch { return null; }
}
// Abonnement van een account (account_plans; geen rij = gratis). strict: bij een databasefout een fout gooien
// (entitlements -> 500; heartbeat/config laten de entitlements dan weg, de apps houden de laatst bekende). Anders
// security L3: fail closed naar de Gratis-limieten (een uitgelokte databasefout geeft nooit Lifetime). Er wordt nergens
// iets gewist op grond van deze limieten: alleen nieuwe apparaten/streams/servers boven de grens worden geweigerd.
async function planRow(userId: string, strict = false): Promise<PlanRow> {
  const { data, error } = await admin.from("account_plans").select("plan,max_streams,max_devices").eq("user_id", userId).maybeSingle();
  if (error) {
    console.error("account_plans", error.message);
    if (strict) throw new Error(error.message);
    return { plan: "free" };
  }
  return data ?? null;
}
// Upgrade-link per platform (app_settings.upgrade_link), 60 s in het geheugen; bij een fout de standaard.
let linkCache: { at: number; value: UpgradeLink } | null = null;
async function upgradeLinks(): Promise<UpgradeLink> {
  if (linkCache && Date.now() - linkCache.at < 60_000) return linkCache.value;
  const { data, error } = await admin.from("app_settings").select("value").eq("key", "upgrade_link").maybeSingle();
  if (error) console.error("app_settings", error.message);
  const value = normalizeUpgradeLink(data?.value);
  if (!error) linkCache = { at: Date.now(), value };
  return value;
}
// Platform van de aanvraag (body.platform), anders van het geregistreerde apparaat (body.device_id of het opgegeven platform).
async function callerPlatform(userId: string, body: Record<string, unknown>, devicePlatform?: string | null) {
  const p = normalizePlatform(body.platform);
  if (p) return p;
  if (devicePlatform !== undefined) return platformFromDevice(devicePlatform);
  if (!body.device_id) return null;
  const { data } = await admin.from("account_devices").select("platform").eq("user_id", userId)
    .eq("device_id", String(body.device_id).slice(0, 80)).maybeSingle();
  return platformFromDevice(data?.platform);
}
async function entitlementsFor(userId: string, body: Record<string, unknown>, devicePlatform?: string | null, strict = false) {
  // security L3: altijd strict, zodat een databasefout nooit "Gratis" als entitlements naar de apps stuurt (strict blijft
  // als parameter voor de aanroepers; zonder strict vangen die de fout af en laten ze de entitlements weg)
  void strict;
  const [row, links, platform] = await Promise.all([planRow(userId, true), upgradeLinks(), callerPlatform(userId, body, devicePlatform)]);
  return entitlements(row, links, platform);
}
async function listDevices(userId: string, current?: string) {
  const { data } = await admin.from("account_devices").select("device_id,name,platform,created_at,last_seen_at,signed_in_at")
    .eq("user_id", userId).order("last_seen_at", { ascending: false });
  return (data ?? []).map((d) => ({ ...d, current: d.device_id === current }));
}
// Eigen naam uit /koppelen toepassen: de oudste klaargezette naam (< 15 min) van dezelfde soort, alleen als dit apparaat ná het
// goedkeuren is ingelogd (signed_in_at), zodat een ander apparaat van dezelfde soort dat toevallig opstart hem niet krijgt.
// De naam krijgt custom_name = true: de standaardnaam van de app overschrijft hem daarna niet meer. Een fout stopt het
// aanmelden nooit.
async function pendingName(userId: string, deviceId: string, platform: string) {
  try {
    const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
    const { data: p } = await admin.from("device_pending_names").select("id,name,created_at").eq("user_id", userId)
      .eq("kind", deviceKind(platform)).gte("created_at", since).order("created_at", { ascending: true }).limit(1).maybeSingle();
    if (!p) return;
    const { data: d } = await admin.from("account_devices").select("signed_in_at,created_at").eq("user_id", userId).eq("device_id", deviceId).maybeSingle();
    const signedIn = Date.parse(d?.signed_in_at ?? d?.created_at ?? "");
    if (!d || !(signedIn >= Date.parse(p.created_at) - 5000)) return;
    const { data: claimed } = await admin.from("device_pending_names").delete().eq("id", p.id).select("id");
    if (!claimed?.length) return; // al door een gelijktijdige aanmelding gebruikt
    await admin.from("account_devices").update({ name: p.name, custom_name: true }).eq("user_id", userId).eq("device_id", deviceId);
  } catch (e) { console.error("pending_name", e instanceof Error ? e.message : e); }
}
async function removeDevice(userId: string, deviceId: string) {
  const { data: row } = await admin.from("account_devices").select("session_id").eq("user_id", userId).eq("device_id", deviceId).maybeSingle();
  if (row?.session_id) await admin.rpc("revoke_session", { sid: row.session_id });
  await admin.from("account_devices").delete().eq("user_id", userId).eq("device_id", deviceId);
  await admin.from("account_streams").delete().eq("user_id", userId).eq("device_id", deviceId);
}
// AES-GCM met BINGR_SOURCES_KEY (32 bytes, base64); wordt eenmalig door de Backend-workflow aangemaakt.
// Elke seal() krijgt een eigen willekeurige nonce van 12 bytes (veilig tot ~2^32 versleutelingen per sleutel).
let keyPromise: Promise<CryptoKey> | null = null;
function sourcesKey(): Promise<CryptoKey> {
  if (!keyPromise) {
    keyPromise = (async () => {
      const raw = Uint8Array.from(atob(Deno.env.get("BINGR_SOURCES_KEY") ?? ""), (c) => c.charCodeAt(0));
      if (raw.length !== 32) throw new Error("sources_key_missing");
      return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
    })();
    keyPromise.catch(() => { keyPromise = null; });
  }
  return keyPromise;
}
async function seal(obj: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await sourcesKey(), new TextEncoder().encode(JSON.stringify(obj))));
  const out = new Uint8Array(iv.length + ct.length); out.set(iv); out.set(ct, iv.length);
  let s = ""; for (let i = 0; i < out.length; i += 8192) s += String.fromCharCode(...out.subarray(i, i + 8192));
  return btoa(s);
}
async function open_(data: string): Promise<any> {
  const all = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12) }, await sourcesKey(), all.subarray(12));
  return JSON.parse(new TextDecoder().decode(pt));
}
const s80 = (v: unknown) => (v == null ? null : String(v).slice(0, 80));
const s200 = (v: unknown) => (v == null ? null : String(v).slice(0, 200));
// Build 62: appversie ("1.0.0 (62)") en systeemversie, max. 40 tekens; leeg/ontbrekend = niet meegestuurd.
const s40 = (v: unknown) => { const t = v == null ? "" : String(v).trim().slice(0, 40); return t || null; };
async function closeLog(userId: string, deviceId: string) {
  const { data: cur } = await admin.from("account_streams").select("log_id").eq("user_id", userId).eq("device_id", deviceId).maybeSingle();
  if (cur?.log_id) await admin.from("account_watch_log").update({ ended_at: new Date().toISOString() }).eq("id", cur.log_id);
}
// Build 68: kijktijd van de lopende stream op dit apparaat bijschrijven (statistieken); een fout stopt het afspelen nooit.
async function account(userId: string, deviceId: string) {
  const { error } = await admin.rpc("bingr_stream_account", { p_user: userId, p_device: deviceId, p_ttl_seconds: Math.round(STREAM_TTL_MS / 1000) });
  if (error) console.error("stream_account", error.message);
}
async function activeStreams(userId: string) {
  const fresh = new Date(Date.now() - STREAM_TTL_MS).toISOString();
  const { data: rows } = await admin.from("account_streams").select("device_id,profile_id,profile_name,title,kind,started_at,last_ping")
    .eq("user_id", userId).gte("last_ping", fresh).order("started_at", { ascending: true });
  const { data: devs } = await admin.from("account_devices").select("device_id,name,platform,signed_in_at,created_at").eq("user_id", userId);
  const map = new Map((devs ?? []).map((d) => [d.device_id, d]));
  return (rows ?? []).map((r) => {
    const d = map.get(r.device_id);
    return { ...r, device_name: d?.name ?? null, platform: d?.platform ?? null, signed_in_at: d?.signed_in_at ?? d?.created_at ?? null };
  });
}
// Ingelogde gebruiker, of een kant-en-klaar foutantwoord: 401 bij een ongeldig/verlopen token (de apps verversen dan
// en proberen het opnieuw), 503 als de auth-server tijdelijk niet antwoordt (nooit uitloggen door een storing).
type Authed = { id: string; email?: string };
async function authed(req: Request): Promise<Authed | Response> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return json({ error: "not_signed_in" }, 401);
  const { data, error } = await admin.auth.getUser(token);
  // geblokkeerd account (ban uit het beheer): 401 {error:"user_banned", banned:true} -> de apps tonen de melding
  // (Android/Samsung TV vernieuwen eerst bij 401; dat geeft door de ban ook user_banned). Zie docs/ACCOUNT.md.
  if (!error && data?.user) return bannedUntilActive((data.user as { banned_until?: string }).banned_until) ? json(BANNED_BODY, 401) : data.user;
  if (isBanError(error)) return json(BANNED_BODY, 401);
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? json({ error: "not_signed_in" }, 401) : json({ error: "unavailable" }, 503);
}
// build 95: limiet via bingr_rate_hit (schema.sql; p_window = venster in seconden). Een databasefout houdt niets tegen
// (zoals elders: een storing mag inloggen of koppelen niet blokkeren), maar komt wel in de logs.
async function rateLimited(key: string, max: number, windowS = 60): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: key, p_max: max, p_window: windowS });
  if (error) { console.error("rate_hit", key.split(":")[0], error.message); return false; }
  return data === false;
}
// build 95: tv-koppeling raden/afschermen: code_info en approve per account en per IP
const CODE_PER_MIN_USER = 30, CODE_PER_MIN_IP = 60;
async function codeLimited(req: Request, userId: string) {
  return await rateLimited(`da-code:ip:${clientIp(req)}`, CODE_PER_MIN_IP) || await rateLimited(`da-code:u:${userId}`, CODE_PER_MIN_USER)
    || await badCodeBlocked(req, userId);
}
// Koppelcodes raden: alleen FOUTE codes (invalid_code) tellen, max. 20 per IP en 20 per account per uur; daarna 429 tot
// het uur om is. Een gewone gebruiker typt hooguit een paar keer een code verkeerd (de website vraagt pas bij 6 tekens).
const BAD_CODE_PER_HOUR = 20;
async function ratePeek(key: string, max: number, windowS: number): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_peek", { p_key: key, p_max: max, p_window: windowS });
  if (error) { console.error("rate_peek", key.split(":")[0], error.message); return true; }
  return data !== false;
}
async function badCodeBlocked(req: Request, userId: string) {
  return !(await ratePeek(`da-bad:ip:${clientIp(req)}`, BAD_CODE_PER_HOUR, 3600)) || !(await ratePeek(`da-bad:u:${userId}`, BAD_CODE_PER_HOUR, 3600));
}
async function invalidCode(req: Request, userId: string) {
  await rateLimited(`da-bad:ip:${clientIp(req)}`, BAD_CODE_PER_HOUR, 3600);
  await rateLimited(`da-bad:u:${userId}`, BAD_CODE_PER_HOUR, 3600);
  return json({ error: "invalid_code" }, 404);
}
// H1: delete_account met wachtwoord, per account 5 en per IP 20 pogingen per 10 minuten (wachtwoord raden)
const DELETE_PER_10MIN_USER = 5, DELETE_PER_10MIN_IP = 20;
// Wachtwoord controleren met een losse anon-client (eigen geheugen, niets bewaard): signInWithPassword op het e-mailadres
// van de ingelogde gebruiker. Lukt het, dan wordt die nieuwe sessie meteen weer ingetrokken (alleen die, scope local).
// Het wachtwoord komt nooit in een log.
async function passwordOk(email: string, password: string, req: Request): Promise<PasswordCheck> {
  const key = Deno.env.get("SUPABASE_ANON_KEY") || req.headers.get("apikey") || "";
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, key, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    const { data, error } = await anon.auth.signInWithPassword({ email, password });
    if (data?.session && !error) {
      await anon.auth.signOut({ scope: "local" }).catch(() => {});
      return "ok";
    }
    return passwordCheckResult(error as { status?: number; code?: string } | null);
  } catch (e) {
    console.error("delete_account wachtwoordcontrole", e instanceof Error ? e.message : e);
    return "unavailable";
  }
}
const isoMs = (v: unknown) => { const t = Date.parse(String(v ?? "")); return Number.isFinite(t) ? t : 0; };
const TOMBSTONE_MS = 90 * 864e5;
// Bronnen samenvoegen per id (hoofdletterongevoelig): nieuwste updatedAt (of deletedAt) wint, bij gelijk de nieuwe lijst.
// Een bron die alleen op de server staat blijft staan, zodat een apparaat met een oude lijst niets kan wissen.
function mergeSources(stored: unknown[], incoming: unknown[]) {
  const key = (o: any) => String(o?.id ?? "").toLowerCase();
  const stamp = (o: any) => isoMs(o?.updatedAt) || isoMs(o?.deletedAt);
  const out = new Map<string, any>();
  const loose: unknown[] = [];
  for (const o of stored) { const k = key(o); if (k) out.set(k, o); }
  for (const o of incoming) {
    const k = key(o);
    if (!k) { loose.push(o); continue; }
    const cur = out.get(k);
    if (!cur || stamp(o) >= stamp(cur)) out.set(k, o);
  }
  const cut = Date.now() - TOMBSTONE_MS;
  return [...out.values(), ...loose].filter((o: any) => !(o?.deleted === true && (isoMs(o.deletedAt) || isoMs(o.updatedAt)) < cut));
}

const MAX_BODY = 2 * 1024 * 1024;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "too_large" }, 413);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return json({ error: "too_large" }, 413);
    body = JSON.parse(text);
  } catch { return json({ error: "bad_json" }, 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "bad_json" }, 400);
  try {
    return await handle(req, body);
  } catch (e) {
    // nooit interne details naar buiten; wel in de functielogs
    console.error("device-auth", String(body.action ?? ""), e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});

async function handle(req: Request, body: Record<string, unknown>): Promise<Response> {
  switch (body.action) {
    case "ping": // statuspagina: werkt de functie (zonder inloggen, zonder database)
      return json({ ok: true });
    case "start": {
      // build 95: zonder inloggen, dus per IP begrensd (10 per 10 minuten): niemand kan de 10.000 open codes vullen
      if (await rateLimited(`da-start:${clientIp(req)}`, 10, 600)) return json({ error: "rate_limited" }, 429);
      // verlopen codes eerst weg, zodat alleen echt open codes meetellen voor de grens hieronder
      await admin.from("device_codes").delete().lt("expires_at", new Date().toISOString());
      // af en toe voor alle accounts opruimen (oude streams, geschiedenis > 8 dagen)
      if (Math.random() < 0.1) await admin.rpc("bingr_cleanup");
      const { count: open } = await admin.from("device_codes").select("code", { count: "exact", head: true });
      if ((open ?? 0) >= 10000) return json({ error: "try_again" }, 503);
      const device = String(body.device ?? "TV").slice(0, 60);
      for (let i = 0; i < 5; i++) {
        const code = randomCode(), poll_secret = randomSecret();
        const expires = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const { error } = await admin.from("device_codes").insert({ code, poll_secret, device, expires_at: expires });
        if (!error) return json({ code, poll_secret, url: `${SITE}/koppelen?code=${code}`, expires_in: 600, interval: 3 });
      }
      return json({ error: "try_again" }, 503);
    }
    case "poll": {
      const code = normalize(body.code).slice(0, 12);
      const { data: row } = await admin.from("device_codes").select("*").eq("code", code).maybeSingle();
      if (!row || !same(row.poll_secret, String(body.poll_secret ?? ""))) return json({ status: "expired" });
      if (new Date(row.expires_at) < new Date()) {
        await admin.from("device_codes").delete().eq("code", code);
        return json({ status: "expired" });
      }
      if (!row.user_id) return json({ status: "pending" });
      const { data: u } = await admin.auth.admin.getUserById(row.user_id);
      const email = u?.user?.email;
      if (!email) return json({ status: "expired" });
      // account intussen geblokkeerd: geen sessie voor de tv, wel een duidelijke status (apps tonen de melding)
      if (bannedUntilActive((u.user as { banned_until?: string }).banned_until)) {
        await admin.from("device_codes").delete().eq("code", code);
        return json({ status: "banned", ...BANNED_BODY }, 403);
      }
      const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
      await admin.from("device_codes").delete().eq("code", code);
      // eigen naam uit /koppelen: klaarzetten voor de register_device van dit apparaat (zie pendingName)
      if (!error && row.name) {
        await admin.from("device_pending_names").delete().lt("created_at", new Date(Date.now() - 3600e3).toISOString());
        const { error: pe } = await admin.from("device_pending_names").insert({ user_id: row.user_id, kind: deviceKind(row.device), name: row.name });
        if (pe) console.error("pending_name", pe.message);
      }
      if (error || !link?.properties?.hashed_token) return json({ error: "link_failed" }, 500);
      return json({ status: "approved", token_hash: link.properties.hashed_token, email });
    }
    case "code_info": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      if (await codeLimited(req, user.id)) return json({ error: "rate_limited" }, 429);
      const code = normalize(body.code).slice(0, 12);
      const { data: row } = await admin.from("device_codes").select("device, created_at, expires_at, user_id").eq("code", code).maybeSingle();
      if (!row || new Date(row.expires_at) < new Date() || (row.user_id && row.user_id !== user.id)) return await invalidCode(req, user.id);
      // H1: aanmaaktijdstip voor de bevestigingsstap op /koppelen ("zojuist", "3 minuten geleden"). age_s rekent de server
      // zelf uit, zodat een verkeerd ingestelde klok bij de gebruiker de leeftijd niet verandert. Niets van de aanvrager (IP e.d.).
      const age_s = Math.max(0, Math.round((Date.now() - Date.parse(row.created_at)) / 1000));
      return json({
        ok: true, device: row.device ?? "TV", kind: deviceKind(row.device), label: deviceTypeLabel(row.device),
        created_at: row.created_at, age_s, expires_in: Math.max(0, Math.round((Date.parse(row.expires_at) - Date.now()) / 1000)),
      });
    }
    case "approve": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      if (await codeLimited(req, user.id)) return json({ error: "rate_limited" }, 429);
      const code = normalize(body.code).slice(0, 12);
      const { data: row } = await admin.from("device_codes").select("code, device, expires_at, user_id").eq("code", code).maybeSingle();
      if (!row || new Date(row.expires_at) < new Date()) return await invalidCode(req, user.id);
      if (row.user_id && row.user_id !== user.id) return await invalidCode(req, user.id);
      const n = cleanDeviceName(body.name, deviceTypeLabel(row.device));
      if ("error" in n) return json({ error: n.error }, 400);
      // alleen een nog niet goedgekeurde code (of je eigen) claimen, ook als twee accounts tegelijk goedkeuren
      const { data: claimed } = await admin.from("device_codes").update({ user_id: user.id, name: n.name }).eq("code", code)
        .or(`user_id.is.null,user_id.eq.${user.id}`).select("code");
      if (!claimed?.length) return json({ error: "invalid_code" }, 404);
      return json({ ok: true, device: row.device, name: n.name });
    }
    case "delete_account": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      // H1: alleen met het huidige wachtwoord, zodat een overgenomen sessie (bv. een tv die via een doorgestuurde
      // koppelcode is gekoppeld) het account niet kan verwijderen. Geen of fout wachtwoord -> 403 {error:"wrong_password"}.
      const password = typeof body.password === "string" ? body.password : "";
      if (!password || password.length > 200 || !user.email) return json({ error: "wrong_password" }, 403);
      if (await rateLimited(`da-del:u:${user.id}`, DELETE_PER_10MIN_USER, 600) || await rateLimited(`da-del:ip:${clientIp(req)}`, DELETE_PER_10MIN_IP, 600)) {
        return json({ error: "rate_limited" }, 429);
      }
      const check = await passwordOk(user.email, password, req);
      if (check === "rate_limited") return json({ error: "rate_limited" }, 429);
      if (check === "unavailable") return json({ error: "unavailable" }, 503);
      if (check !== "ok") return json({ error: "wrong_password" }, 403);
      // profielfoto's opruimen, daarna de gebruiker (tabellen gaan mee via on delete cascade)
      for (let i = 0; i < 20; i++) {
        const { data: files, error: le } = await admin.storage.from("avatars").list(user.id, { limit: 1000 });
        if (le || !files?.length) break;
        const { error: re } = await admin.storage.from("avatars").remove(files.map((f) => `${user.id}/${f.name}`));
        if (re) break;
      }
      // sessies van gekoppelde apparaten intrekken; alle tabellen (profielen, servers, gegevens, apparaten, streams,
      // geschiedenis, tv-codes) gaan mee via on delete cascade. Aankopen en terugbetalingen blijven (fiscale bewaarplicht,
      // 7 jaar) zonder koppeling aan het account: user_id null via on delete set null (docs/ACCOUNT.md, "Bewaarplicht").
      const { error } = await admin.auth.admin.deleteUser(user.id);
      if (error) { console.error("delete_account", error.message); return json({ error: "delete_failed" }, 500); }
      return json({ ok: true });
    }
    case "register_device": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      if (!device_id) return json({ error: "device_id_missing" }, 400);
      const name = String(body.name ?? "").slice(0, 80), platform = String(body.platform ?? "").slice(0, 40);
      const sid = sessionIdFrom(req);
      const session_id = sid && /^[0-9a-f-]{36}$/i.test(sid) ? sid : null;
      // apparatenlimiet van het abonnement (gratis 8, lifetime 15, of eigen limiet uit het beheer)
      const row = await planRow(user.id), limit = limitsFor(row).devices;
      // tellen + toevoegen atomair in de database (slot per account), zodat gelijktijdige logins de limiet niet passeren
      const { data: r, error } = await admin.rpc("bingr_register_device", {
        p_user: user.id, p_device: device_id, p_name: name, p_platform: platform, p_session: session_id, p_limit: limit,
        p_app_version: s40(body.app_version), p_os_version: s40(body.os_version),
      });
      if (error) throw new Error(error.message);
      if (r?.error === "device_limit") {
        return json({ error: "device_limit", limit, plan: normalizePlan(row?.plan), devices: await listDevices(user.id) }, 403);
      }
      await pendingName(user.id, device_id, platform);
      return json({ ok: true, limit });
    }
    case "heartbeat": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      const { data: row } = await admin.from("account_devices").select("session_id,platform").eq("user_id", user.id).eq("device_id", device_id).maybeSingle();
      if (!row) return json({ revoked: true });
      const sid = sessionIdFrom(req);
      const patch: Record<string, unknown> = { last_seen_at: new Date().toISOString() };
      if (sid && /^[0-9a-f-]{36}$/i.test(sid) && sid !== row.session_id) patch.session_id = sid;
      const av = s40(body.app_version), ov = s40(body.os_version);
      if (av) patch.app_version = av;
      if (ov) patch.os_version = ov;
      await admin.from("account_devices").update(patch).eq("user_id", user.id).eq("device_id", device_id);
      // actief vandaag (statistieken); één rij per account per dag
      await admin.from("account_logins").upsert({ user_id: user.id, day: new Date().toISOString().slice(0, 10) },
        { onConflict: "user_id,day", ignoreDuplicates: true });
      // abonnement mee (limieten, functies, upgrade-link): de apps passen het zonder extra aanvraag toe
      let ent: unknown = undefined;
      try { ent = await entitlementsFor(user.id, body, row.platform ?? null); } catch (e) { console.error("heartbeat entitlements", e instanceof Error ? e.message : e); }
      return json({ ok: true, entitlements: ent });
    }
    case "list_devices": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const limit = limitsFor(await planRow(user.id)).devices;
      return json({ limit, devices: await listDevices(user.id, body.device_id ? String(body.device_id).slice(0, 80) : undefined) });
    }
    case "rename_device": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const name = String(body.name ?? "").trim().slice(0, 60);
      if (!name) return json({ error: "name_missing" }, 400);
      const { error } = await admin.from("account_devices").update({ name, custom_name: true })
        .eq("user_id", user.id).eq("device_id", String(body.device_id ?? "").slice(0, 80));
      return error ? json({ error: "rename_failed" }, 500) : json({ ok: true });
    }
    case "remove_device": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      await removeDevice(user.id, String(body.device_id ?? "").slice(0, 80));
      return json({ ok: true });
    }
    case "get_sources": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const { data: row } = await admin.from("account_sources").select("data,updated_at").eq("user_id", user.id).maybeSingle();
      if (!row) return json({ sources: [], mainSourceID: null, updatedAt: null });
      try {
        const o = await open_(row.data);
        return json({ sources: o.sources ?? [], mainSourceID: o.mainSourceID ?? null, updatedAt: row.updated_at });
      } catch (e) { console.error("get_sources", e instanceof Error ? e.message : e); return json({ error: "decrypt_failed" }, 500); }
    }
    case "put_sources": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      if (!Array.isArray(body.sources)) return json({ error: "bad_sources" }, 400);
      const incoming = body.sources.filter((o) => o && typeof o === "object" && !Array.isArray(o)).slice(0, 100);
      const main = body.mainSourceID == null ? null : String(body.mainSourceID).slice(0, 80);
      const { data: row } = await admin.from("account_sources").select("data").eq("user_id", user.id).maybeSingle();
      let stored: unknown[] = [];
      if (row) {
        try { const o = await open_(row.data); stored = Array.isArray(o?.sources) ? o.sources : []; }
        catch (e) { console.error("put_sources", e instanceof Error ? e.message : e); return json({ error: "decrypt_failed" }, 500); }
      }
      const merged = mergeSources(stored, incoming);
      // security L4: serverlimiet van het abonnement (Gratis 1) ook op de server. Alleen groeien boven de grens wordt
      // geweigerd; wie (van vóór de limiet) al meer servers had, houdt die en kan ze bijwerken of verwijderen.
      const live = (l: unknown[]) => l.filter((o: any) => o && o.deleted !== true).length;
      const maxServers = limitsFor(await planRow(user.id)).servers;
      if (maxServers != null && live(merged) > Math.max(maxServers, live(stored))) {
        return json({ error: "server_limit", limit: maxServers, feature: "multi_server", plan: "free" }, 403);
      }
      const payload = { sources: merged, mainSourceID: main };
      if (JSON.stringify(payload).length > 512 * 1024) return json({ error: "too_large" }, 413);
      const updated_at = new Date().toISOString();
      const { error } = await admin.from("account_sources").upsert({ user_id: user.id, data: await seal(payload), updated_at });
      if (error) throw new Error(error.message);
      return json({ ok: true, updatedAt: updated_at });
    }
    case "get_state": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      let q = admin.from("account_state").select("section,data,updated_at").eq("user_id", user.id);
      if (Array.isArray(body.sections) && body.sections.length) q = q.in("section", body.sections.slice(0, 100).map((x) => String(x).slice(0, 80)));
      const { data: rows } = await q;
      const out: Record<string, unknown> = {};
      for (const r of rows ?? []) {
        try { out[r.section] = { data: await open_(r.data), updatedAt: r.updated_at }; } catch { /* onleesbaar: overslaan */ }
      }
      return json({ sections: out });
    }
    case "put_state": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const section = String(body.section ?? "");
      if (section.length > 80 || !/^[a-zA-Z0-9._:-]+$/.test(section)) return json({ error: "bad_section" }, 400);
      if (JSON.stringify(body.data ?? null).length > 1024 * 1024) return json({ error: "too_large" }, 413);
      const { count } = await admin.from("account_state").select("section", { count: "exact", head: true }).eq("user_id", user.id);
      if ((count ?? 0) >= 200) {
        const { data: exists } = await admin.from("account_state").select("section").eq("user_id", user.id).eq("section", section).maybeSingle();
        if (!exists) return json({ error: "too_many_sections" }, 413);
      }
      const updated_at = new Date().toISOString();
      const { error } = await admin.from("account_state").upsert({ user_id: user.id, section, data: await seal(body.data ?? null), updated_at });
      if (error) throw new Error(error.message);
      return json({ ok: true, updatedAt: updated_at });
    }
    case "delete_state": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      await admin.from("account_state").delete().eq("user_id", user.id).eq("section", String(body.section ?? "").slice(0, 80));
      return json({ ok: true });
    }
    case "stream_start": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      if (!device_id) return json({ error: "device_id_missing" }, 400);
      // streamlimiet van het abonnement (gratis 1, lifetime 3, of eigen limiet uit het beheer); Bingr-telling,
      // los van de limiet van de IPTV-provider (die controleren de apps zelf bij het afspelen)
      const row = await planRow(user.id), limit = limitsFor(row).streams;
      // verlopen streams weg, tellen, geschiedenis en stream in één transactie met een slot per account,
      // zodat gelijktijdige starts nooit boven de limiet uitkomen
      const { data: r, error } = await admin.rpc("bingr_stream_start", {
        p_user: user.id, p_device: device_id, p_profile_id: s80(body.profile_id), p_profile_name: s80(body.profile_name),
        p_title: s200(body.title), p_kind: s80(body.kind), p_content_id: s200(body.content_id),
        p_limit: limit, p_ttl_seconds: Math.round(STREAM_TTL_MS / 1000),
        p_series_id: s200(body.series_id || null), p_series_title: s200(body.series_title || null), p_tz: validTz(body.tz),
      });
      if (error) throw new Error(error.message);
      if (r?.error === "stream_limit") {
        return json({ error: "stream_limit", limit, plan: normalizePlan(row?.plan), streams: await activeStreams(user.id) }, 403);
      }
      // af en toe voor alle accounts opruimen (geschiedenis > 8 dagen, oude streams, verlopen tv-codes)
      if (Math.random() < 0.05) await admin.rpc("bingr_cleanup");
      return json({ ok: true, limit });
    }
    case "stream_ping": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      const { data: cur } = await admin.from("account_streams").select("log_id,last_ping").eq("user_id", user.id).eq("device_id", device_id).maybeSingle();
      // geen stream, of te lang geen ping (telde al niet meer mee): opnieuw stream_start, zodat de limiet weer geldt
      if (!cur || Date.now() - isoMs(cur.last_ping) > STREAM_TTL_MS) return json({ stopped: true });
      const now = new Date().toISOString();
      const patch: Record<string, unknown> = { last_ping: now };
      if (body.title) patch.title = s200(body.title);
      if (body.kind) patch.kind = s80(body.kind);
      if (body.content_id) patch.content_id = s200(body.content_id);
      if (body.series_id) patch.series_id = s200(body.series_id);
      if (body.series_title) patch.series_title = s200(body.series_title);
      // eerst de kijktijd tot nu bijschrijven (op de titel die tot nu liep), dan pas de wijzigingen
      await account(user.id, device_id);
      await admin.from("account_streams").update(patch).eq("user_id", user.id).eq("device_id", device_id);
      if (cur.log_id) await admin.from("account_watch_log").update({ ended_at: now }).eq("id", cur.log_id);
      return json({ ok: true });
    }
    case "stream_stop": {
      const user = await authed(req);
      if (user instanceof Response) return user.status === 401 ? json({ ok: true }) : user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      await closeLog(user.id, device_id);
      await account(user.id, device_id);
      await admin.from("account_streams").delete().eq("user_id", user.id).eq("device_id", device_id);
      return json({ ok: true });
    }
    case "list_streams": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      // "Wie kijkt er nu": alleen Lifetime
      const row = await planRow(user.id);
      if (normalizePlan(row?.plan) !== "lifetime") return json(featureLocked("now_watching", "free"), 403);
      return json({ limit: limitsFor(row).streams, streams: await activeStreams(user.id) });
    }
    case "watch_log": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      // kijkgeschiedenis (7 dagen) hoort bij "Nu aan het kijken": alleen Lifetime
      if (normalizePlan((await planRow(user.id))?.plan) !== "lifetime") return json(featureLocked("now_watching", "free"), 403);
      const days = Math.min(Math.max(Number(body.days ?? 7) || 7, 1), 7);
      const since = new Date(Date.now() - days * 864e5).toISOString();
      const { data } = await admin.from("account_watch_log")
        .select("device_name,platform,profile_id,profile_name,title,kind,content_id,started_at,ended_at")
        .eq("user_id", user.id).gte("started_at", since).order("started_at", { ascending: false }).limit(1000);
      const entries = (data ?? []).map((e) => ({
        ...e, minutes: Math.max(0, Math.round((Date.parse(e.ended_at) - Date.parse(e.started_at)) / 60000)),
      })).filter((e) => e.minutes >= 1 || Date.now() - Date.parse(e.started_at) < 5 * 60000);
      return json({ entries });
    }
    case "watch_stats": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      // statistieken: alleen Lifetime (de kijktijd wordt voor iedereen bijgehouden, dus na upgraden staat alles er al)
      if (normalizePlan((await planRow(user.id))?.plan) !== "lifetime") return json(featureLocked("stats", "free"), 403);
      const tz = validTz(body.tz) ?? DEFAULT_TZ;
      const range = periodRange(body.period, body.offset, todayIn(tz));
      const profileId = body.profile_id == null || body.profile_id === "" ? null : String(body.profile_id).slice(0, 80);
      const { data: raw, error } = await admin.rpc("bingr_watch_stats", {
        p_user: user.id, p_profile: profileId, p_from: range.from, p_to: range.to, p_by_month: range.byMonth,
      });
      if (error) throw new Error(error.message);
      // profielnamen zoals ze nu heten (de statistieken bewaren de naam van toen)
      const names = new Map<string, string>();
      if (profileId == null) {
        const { data: acc } = await admin.from("account_data").select("profiles").eq("user_id", user.id).maybeSingle();
        for (const p of Array.isArray(acc?.profiles) ? acc.profiles : []) {
          if (p && typeof p === "object" && p.id && !p.deleted && p.name) names.set(String(p.id), String(p.name));
        }
      }
      return json(buildStats(raw ?? {}, range, { profileId, tz, profileNames: names }));
    }
    case "delete_watch_stats": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      let q = admin.from("account_watch_stats").delete().eq("user_id", user.id);
      if (body.profile_id != null && body.profile_id !== "") q = q.eq("profile_id", String(body.profile_id).slice(0, 80));
      const { error } = await q;
      if (error) throw new Error(error.message);
      return json({ ok: true });
    }
    case "announcements": {
      // Build 117: berichten uit het beheer komen alleen nog als pushmelding (docs/PUSH.md). Oude app-builds (vóór de
      // pushmeldingen) vragen dit nog op en tonen dan een banner; ze krijgen een lege lijst, zodat ze niets meer in de app
      // tonen en ook niet vastlopen op een onbekende actie. Inloggen blijft nodig (zelfde antwoord als voorheen bij 401).
      const user = await authed(req);
      if (user instanceof Response) return user;
      return json({ items: [] });
    }
    case "config": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const env = (k: string) => Deno.env.get(k) ?? "";
      // security L5: app-sleutels niet onbeperkt uitdelen: max. 60 keer per uur per account (de apps vragen ze bij het
      // opstarten en na inloggen), en de Trakt-sleutels alleen aan wie Trakt mag gebruiken (Lifetime). Ontbreekt een veld,
      // dan houden de apps hun opgeslagen waarde (zie AccountService); bij een databasefout dus geen Trakt-velden.
      const { data: okRate, error: rateErr } = await admin.rpc("bingr_rate_hit", { p_key: `config:${user.id}`, p_max: 60, p_window: 3600 });
      if (rateErr) console.error("config rate", rateErr.message);
      else if (okRate !== true) return json({ error: "rate_limited" }, 429);
      let ent: Awaited<ReturnType<typeof entitlementsFor>> | undefined = undefined;
      try { ent = await entitlementsFor(user.id, body); } catch (e) { console.error("config entitlements", e instanceof Error ? e.message : e); }
      const trakt = ent?.features?.trakt === true;
      return json({
        ...(trakt ? { traktClientID: env("BINGR_TRAKT_CLIENT_ID"), traktClientSecret: env("BINGR_TRAKT_CLIENT_SECRET") } : {}),
        openSubtitlesAPIKey: env("BINGR_OPENSUBTITLES_API_KEY"),
        omdbAPIKey: env("BINGR_OMDB_API_KEY"),
        tmdbAPIKey: env("BINGR_TMDB_API_KEY"),
        entitlements: ent,
      });
    }
    case "entitlements": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      return json(await entitlementsFor(user.id, body, undefined, true));
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}
