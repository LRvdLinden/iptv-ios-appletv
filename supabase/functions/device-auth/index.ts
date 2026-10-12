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
