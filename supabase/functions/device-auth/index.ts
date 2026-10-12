// Bingr: tv-koppeling (QR-login) en account verwijderen.
// POST /functions/v1/device-auth met JSON {action, ...}; header `apikey` altijd, `Authorization: Bearer <access_token>` bij approve/delete_account.
//   start           {device}            -> {code, poll_secret, url, expires_in, interval}
//   poll            {code, poll_secret} -> {status: pending|approved|expired, token_hash?, email?}
//                   Bij approved: POST /auth/v1/verify {type:"magiclink", token_hash} geeft de tv een eigen sessie.
//   approve         {code}   (ingelogd)  -> {ok, device}
//   delete_account  {}       (ingelogd)  -> {ok}
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
    default:
      return json({ error: "unknown_action" }, 400);
  }
});
