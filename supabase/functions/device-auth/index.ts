// Bingr: tv-koppeling (QR-login) en account verwijderen.
// POST /functions/v1/device-auth met JSON {action, ...}; header `apikey` altijd, `Authorization: Bearer <access_token>` bij approve/delete_account.
//   start           {device}            -> {code, poll_secret, url, expires_in, interval}
//   poll            {code, poll_secret} -> {status: pending|approved|expired, token_hash?, email?}
//                   Bij approved: POST /auth/v1/verify {type:"magiclink", token_hash} geeft de tv een eigen sessie.
//   approve         {code}   (ingelogd)  -> {ok, device}
//   delete_account  {}       (ingelogd)  -> {ok}
//   register_device {device_id, name, platform, app_version?, os_version?} (ingelogd) -> {ok, device} | 403 {error:"device_limit", limit, devices}
//   heartbeat       {device_id, app_version?, os_version?} (ingelogd) -> {ok} | {revoked:true}  (werkt ook "laatst gebruikt" bij)
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
//   stream_start    {device_id, profile_id, profile_name, title, kind, content_id} (ingelogd)
//                   -> {ok} | 403 {error:"stream_limit", limit:6, streams:[…]}
//   stream_ping     {device_id, title?, kind?, content_id?} (ingelogd, elke 30 s tijdens afspelen) -> {ok} | {stopped:true}
//   stream_stop     {device_id} (ingelogd) -> {ok}
//   list_streams    {} (ingelogd) -> {limit, streams:[{device_id, device_name, platform, profile_id, profile_name, title, kind, started_at, signed_in_at}]}
//   watch_log       {days?:7} (ingelogd) -> {entries:[{device_name, platform, profile_id, profile_name, title, kind, started_at, ended_at, minutes}]}
//   announcements   {lang?:"nl"|"en"} (ingelogd) -> {items:[{id, title, body, created_at}]}  (build 62; max. 5, nieuwste eerst)
//   config          {}       (ingelogd)  -> {traktClientID, traktClientSecret, openSubtitlesAPIKey, omdbAPIKey, tmdbAPIKey}
//                   App-sleutels staan alleen als function-secrets op de server (BINGR_*), nooit in de openbare repo.
import { createClient } from "jsr:@supabase/supabase-js@2";

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
const DEVICE_LIMIT = 15;
const STREAM_LIMIT = 6;
const STREAM_TTL_MS = 90 * 1000; // een stream zonder ping na 90 s telt niet meer mee
function sessionIdFrom(req: Request): string | null {
  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(part + "===".slice((part.length + 3) % 4)));
    return typeof claims.session_id === "string" ? claims.session_id : null;
  } catch { return null; }
}
async function listDevices(userId: string, current?: string) {
  const { data } = await admin.from("account_devices").select("device_id,name,platform,created_at,last_seen_at,signed_in_at")
    .eq("user_id", userId).order("last_seen_at", { ascending: false });
  return (data ?? []).map((d) => ({ ...d, current: d.device_id === current }));
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
  if (!error && data?.user) return data.user;
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? json({ error: "not_signed_in" }, 401) : json({ error: "unavailable" }, 503);
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
    case "start": {
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
      const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
      await admin.from("device_codes").delete().eq("code", code);
      if (error || !link?.properties?.hashed_token) return json({ error: "link_failed" }, 500);
      return json({ status: "approved", token_hash: link.properties.hashed_token, email });
    }
    case "approve": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const code = normalize(body.code).slice(0, 12);
      const { data: row } = await admin.from("device_codes").select("code, device, expires_at, user_id").eq("code", code).maybeSingle();
      if (!row || new Date(row.expires_at) < new Date()) return json({ error: "invalid_code" }, 404);
      if (row.user_id && row.user_id !== user.id) return json({ error: "invalid_code" }, 404);
      // alleen een nog niet goedgekeurde code (of je eigen) claimen, ook als twee accounts tegelijk goedkeuren
      const { data: claimed } = await admin.from("device_codes").update({ user_id: user.id }).eq("code", code)
        .or(`user_id.is.null,user_id.eq.${user.id}`).select("code");
      if (!claimed?.length) return json({ error: "invalid_code" }, 404);
      return json({ ok: true, device: row.device });
    }
    case "delete_account": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      // profielfoto's opruimen, daarna de gebruiker (tabellen gaan mee via on delete cascade)
      for (let i = 0; i < 20; i++) {
        const { data: files, error: le } = await admin.storage.from("avatars").list(user.id, { limit: 1000 });
        if (le || !files?.length) break;
        const { error: re } = await admin.storage.from("avatars").remove(files.map((f) => `${user.id}/${f.name}`));
        if (re) break;
      }
      // sessies van gekoppelde apparaten intrekken; alle tabellen (profielen, servers, gegevens, apparaten, streams,
      // geschiedenis, tv-codes) gaan mee via on delete cascade
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
      // tellen + toevoegen atomair in de database (slot per account), zodat gelijktijdige logins de limiet niet passeren
      const { data: r, error } = await admin.rpc("bingr_register_device", {
        p_user: user.id, p_device: device_id, p_name: name, p_platform: platform, p_session: session_id, p_limit: DEVICE_LIMIT,
        p_app_version: s40(body.app_version), p_os_version: s40(body.os_version),
      });
      if (error) throw new Error(error.message);
      if (r?.error === "device_limit") return json({ error: "device_limit", limit: DEVICE_LIMIT, devices: await listDevices(user.id) }, 403);
      return json({ ok: true, limit: DEVICE_LIMIT });
    }
    case "heartbeat": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      const { data: row } = await admin.from("account_devices").select("session_id").eq("user_id", user.id).eq("device_id", device_id).maybeSingle();
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
      return json({ ok: true });
    }
    case "list_devices": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      return json({ limit: DEVICE_LIMIT, devices: await listDevices(user.id, body.device_id ? String(body.device_id).slice(0, 80) : undefined) });
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
      const payload = { sources: mergeSources(stored, incoming), mainSourceID: main };
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
      // verlopen streams weg, tellen, geschiedenis en stream in één transactie met een slot per account,
      // zodat gelijktijdige starts nooit boven de limiet uitkomen
      const { data: r, error } = await admin.rpc("bingr_stream_start", {
        p_user: user.id, p_device: device_id, p_profile_id: s80(body.profile_id), p_profile_name: s80(body.profile_name),
        p_title: s200(body.title), p_kind: s80(body.kind), p_content_id: s200(body.content_id),
        p_limit: STREAM_LIMIT, p_ttl_seconds: Math.round(STREAM_TTL_MS / 1000),
      });
      if (error) throw new Error(error.message);
      if (r?.error === "stream_limit") return json({ error: "stream_limit", limit: STREAM_LIMIT, streams: await activeStreams(user.id) }, 403);
      // af en toe voor alle accounts opruimen (geschiedenis > 8 dagen, oude streams, verlopen tv-codes)
      if (Math.random() < 0.05) await admin.rpc("bingr_cleanup");
      return json({ ok: true, limit: STREAM_LIMIT });
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
      await admin.from("account_streams").update(patch).eq("user_id", user.id).eq("device_id", device_id);
      if (cur.log_id) await admin.from("account_watch_log").update({ ended_at: now }).eq("id", cur.log_id);
      return json({ ok: true });
    }
    case "stream_stop": {
      const user = await authed(req);
      if (user instanceof Response) return user.status === 401 ? json({ ok: true }) : user;
      const device_id = String(body.device_id ?? "").slice(0, 80);
      await closeLog(user.id, device_id);
      await admin.from("account_streams").delete().eq("user_id", user.id).eq("device_id", device_id);
      return json({ ok: true });
    }
    case "list_streams": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      return json({ limit: STREAM_LIMIT, streams: await activeStreams(user.id) });
    }
    case "watch_log": {
      const user = await authed(req);
      if (user instanceof Response) return user;
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
    case "announcements": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const en = String(body.lang ?? "").toLowerCase().startsWith("en");
      const now = new Date().toISOString();
      const { data } = await admin.from("announcements").select("id,title_nl,body_nl,title_en,body_en,created_at")
        .gte("created_at", new Date(Date.now() - 30 * 864e5).toISOString())
        .or(`expires_at.is.null,expires_at.gt."${now}"`)
        .order("created_at", { ascending: false }).limit(5);
      const items = (data ?? []).map((a) => {
        const useEn = en && String(a.title_en ?? "").trim() !== "" && String(a.body_en ?? "").trim() !== "";
        return { id: a.id, title: useEn ? a.title_en : a.title_nl, body: useEn ? a.body_en : a.body_nl, created_at: a.created_at };
      });
      return json({ items });
    }
    case "config": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const env = (k: string) => Deno.env.get(k) ?? "";
      return json({
        traktClientID: env("BINGR_TRAKT_CLIENT_ID"),
        traktClientSecret: env("BINGR_TRAKT_CLIENT_SECRET"),
        openSubtitlesAPIKey: env("BINGR_OPENSUBTITLES_API_KEY"),
        omdbAPIKey: env("BINGR_OMDB_API_KEY"),
        tmdbAPIKey: env("BINGR_TMDB_API_KEY"),
      });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}
