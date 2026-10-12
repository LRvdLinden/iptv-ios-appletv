// Bingr: tv-koppeling (QR-login) en account verwijderen.
// POST /functions/v1/device-auth met JSON {action, ...}; header `apikey` altijd, `Authorization: Bearer <access_token>` bij approve/delete_account.
//   start           {device}            -> {code, poll_secret, url, expires_in, interval}
//   poll            {code, poll_secret} -> {status: pending|approved|expired, token_hash?, email?}
//                   Bij approved: POST /auth/v1/verify {type:"magiclink", token_hash} geeft de tv een eigen sessie.
//   approve         {code}   (ingelogd)  -> {ok, device}
//   delete_account  {}       (ingelogd)  -> {ok}
//   register_device {device_id, name, platform} (ingelogd) -> {ok, device} | 403 {error:"device_limit", limit, devices}
//   heartbeat       {device_id} (ingelogd) -> {ok} | {revoked:true}  (werkt ook "laatst gebruikt" bij)
//   list_devices    {device_id?} (ingelogd) -> {limit, devices:[{device_id,name,platform,created_at,last_seen_at,current}]}
//   remove_device   {device_id} (ingelogd) -> {ok}  (trekt de sessie van dat apparaat in)
//   get_sources     {}       (ingelogd)  -> {sources:[…], mainSourceID, updatedAt}
//   put_sources     {sources, mainSourceID} (ingelogd) -> {ok, updatedAt}   (versleuteld opgeslagen)
//   get_state       {sections?:[naam…]} (ingelogd) -> {sections:{naam:{data, updatedAt}}}
//   put_state       {section, data}      (ingelogd) -> {ok, updatedAt}     (versleuteld; data = willekeurige JSON)
//   delete_state    {section}            (ingelogd) -> {ok}
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
const DEVICE_LIMIT = 10;
function sessionIdFrom(req: Request): string | null {
  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(part + "===".slice((part.length + 3) % 4)));
    return typeof claims.session_id === "string" ? claims.session_id : null;
  } catch { return null; }
}
async function listDevices(userId: string, current?: string) {
  const { data } = await admin.from("account_devices").select("device_id,name,platform,created_at,last_seen_at")
    .eq("user_id", userId).order("last_seen_at", { ascending: false });
  return (data ?? []).map((d) => ({ ...d, current: d.device_id === current }));
}
async function removeDevice(userId: string, deviceId: string) {
  const { data: row } = await admin.from("account_devices").select("session_id").eq("user_id", userId).eq("device_id", deviceId).maybeSingle();
  if (row?.session_id) await admin.rpc("revoke_session", { sid: row.session_id });
  await admin.from("account_devices").delete().eq("user_id", userId).eq("device_id", deviceId);
}
// AES-GCM met BINGR_SOURCES_KEY (32 bytes, base64); wordt eenmalig door de Backend-workflow aangemaakt.
async function sourcesKey(): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(Deno.env.get("BINGR_SOURCES_KEY") ?? ""), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("sources_key_missing");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
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
async function userFrom(req: Request) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  return error ? null : data.user;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  switch (body.action) {
    case "start": {
      await admin.from("device_codes").delete().lt("expires_at", new Date().toISOString());
      const device = String(body.device ?? "TV").slice(0, 60);
      for (let i = 0; i < 5; i++) {
        const code = randomCode(), poll_secret = randomSecret();
        const expires = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const { error } = await admin.from("device_codes").insert({ code, poll_secret, device, expires_at: expires });
        if (!error) return json({ code, poll_secret, url: `${SITE}/tv?code=${code}`, expires_in: 600, interval: 3 });
      }
      return json({ error: "try_again" }, 503);
    }
    case "poll": {
      const code = normalize(body.code);
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
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const code = normalize(body.code);
      const { data: row } = await admin.from("device_codes").select("code, device, expires_at, user_id").eq("code", code).maybeSingle();
      if (!row || new Date(row.expires_at) < new Date()) return json({ error: "invalid_code" }, 404);
      if (row.user_id && row.user_id !== user.id) return json({ error: "invalid_code" }, 404);
      await admin.from("device_codes").update({ user_id: user.id }).eq("code", code);
      return json({ ok: true, device: row.device });
    }
    case "delete_account": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      // profielfoto's opruimen, daarna de gebruiker (tabellen gaan mee via on delete cascade)
      const { data: files } = await admin.storage.from("avatars").list(user.id, { limit: 1000 });
      if (files?.length) await admin.storage.from("avatars").remove(files.map((f) => `${user.id}/${f.name}`));
      const { error } = await admin.auth.admin.deleteUser(user.id);
      return error ? json({ error: "delete_failed" }, 500) : json({ ok: true });
    }
    case "register_device": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const device_id = String(body.device_id ?? "").slice(0, 80);
      if (!device_id) return json({ error: "device_id_missing" }, 400);
      const name = String(body.name ?? "").slice(0, 80), platform = String(body.platform ?? "").slice(0, 40);
      const session_id = sessionIdFrom(req);
      const { data: existing } = await admin.from("account_devices").select("device_id,session_id").eq("user_id", user.id).eq("device_id", device_id).maybeSingle();
      if (!existing) {
        const { count } = await admin.from("account_devices").select("device_id", { count: "exact", head: true }).eq("user_id", user.id);
        if ((count ?? 0) >= DEVICE_LIMIT) return json({ error: "device_limit", limit: DEVICE_LIMIT, devices: await listDevices(user.id) }, 403);
        await admin.from("account_devices").insert({ user_id: user.id, device_id, name, platform, session_id });
      } else {
        // zelfde apparaat opnieuw ingelogd: oude sessie intrekken als die anders is
        if (existing.session_id && session_id && existing.session_id !== session_id) await admin.rpc("revoke_session", { sid: existing.session_id });
        await admin.from("account_devices").update({ name, platform, session_id, last_seen_at: new Date().toISOString() })
          .eq("user_id", user.id).eq("device_id", device_id);
      }
      return json({ ok: true, limit: DEVICE_LIMIT });
    }
    case "heartbeat": {
      const user = await userFrom(req);
      if (!user) return json({ revoked: true });
      const device_id = String(body.device_id ?? "");
      const { data: row } = await admin.from("account_devices").select("session_id").eq("user_id", user.id).eq("device_id", device_id).maybeSingle();
      if (!row) return json({ revoked: true });
      const sid = sessionIdFrom(req);
      const patch: Record<string, unknown> = { last_seen_at: new Date().toISOString() };
      if (sid && sid !== row.session_id) patch.session_id = sid;
      await admin.from("account_devices").update(patch).eq("user_id", user.id).eq("device_id", device_id);
      return json({ ok: true });
    }
    case "list_devices": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      return json({ limit: DEVICE_LIMIT, devices: await listDevices(user.id, body.device_id ? String(body.device_id) : undefined) });
    }
    case "remove_device": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      await removeDevice(user.id, String(body.device_id ?? ""));
      return json({ ok: true });
    }
    case "get_sources": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const { data: row } = await admin.from("account_sources").select("data,updated_at").eq("user_id", user.id).maybeSingle();
      if (!row) return json({ sources: [], mainSourceID: null, updatedAt: null });
      try {
        const o = await open_(row.data);
        return json({ sources: o.sources ?? [], mainSourceID: o.mainSourceID ?? null, updatedAt: row.updated_at });
      } catch { return json({ error: "decrypt_failed" }, 500); }
    }
    case "put_sources": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const sources = Array.isArray(body.sources) ? body.sources.slice(0, 50) : [];
      const payload = { sources, mainSourceID: body.mainSourceID ?? null };
      const size = JSON.stringify(payload).length;
      if (size > 512 * 1024) return json({ error: "too_large" }, 413);
      const updated_at = new Date().toISOString();
      await admin.from("account_sources").upsert({ user_id: user.id, data: await seal(payload), updated_at });
      return json({ ok: true, updatedAt: updated_at });
    }
    case "get_state": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      let q = admin.from("account_state").select("section,data,updated_at").eq("user_id", user.id);
      if (Array.isArray(body.sections) && body.sections.length) q = q.in("section", body.sections.map(String).slice(0, 100));
      const { data: rows } = await q;
      const out: Record<string, unknown> = {};
      for (const r of rows ?? []) {
        try { out[r.section] = { data: await open_(r.data), updatedAt: r.updated_at }; } catch { /* onleesbaar: overslaan */ }
      }
      return json({ sections: out });
    }
    case "put_state": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const section = String(body.section ?? "").slice(0, 80);
      if (!/^[a-zA-Z0-9._:-]+$/.test(section)) return json({ error: "bad_section" }, 400);
      if (JSON.stringify(body.data ?? null).length > 1024 * 1024) return json({ error: "too_large" }, 413);
      const { count } = await admin.from("account_state").select("section", { count: "exact", head: true }).eq("user_id", user.id);
      if ((count ?? 0) >= 200) {
        const { data: exists } = await admin.from("account_state").select("section").eq("user_id", user.id).eq("section", section).maybeSingle();
        if (!exists) return json({ error: "too_many_sections" }, 413);
      }
      const updated_at = new Date().toISOString();
      await admin.from("account_state").upsert({ user_id: user.id, section, data: await seal(body.data ?? null), updated_at });
      return json({ ok: true, updatedAt: updated_at });
    }
    case "delete_state": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
      await admin.from("account_state").delete().eq("user_id", user.id).eq("section", String(body.section ?? ""));
      return json({ ok: true });
    }
    case "config": {
      const user = await userFrom(req);
      if (!user) return json({ error: "not_signed_in" }, 401);
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
});
