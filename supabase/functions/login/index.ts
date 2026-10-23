// Bingr build 141: inloggen met e-mail en wachtwoord via deze functie (verify_jwt uit), met blokkade per account.
// POST /functions/v1/login, headers apikey + Content-Type: application/json, body {email, password, device_id?, platform?}.
// Contract en afweging: docs/ACCOUNT.md "Inloggen via de functie login (build 141)"; logica in logic.ts.
// 1. bingr_login_begin (schema.sql): limiet per IP (30 per 10 min) en per e-mailadres (10 per 15 min), alleen als gezouten
//    hash; blokkade per account (auth_password_failures); zet een login-ticket voor de Custom Access Token hook.
// 2. GoTrue controleert het wachtwoord zelf: /auth/v1/token?grant_type=password vanaf de server, met een secret key en
//    Sb-Forwarded-For = IP van de bezoeker, zodat de IP-limiet van Auth per bezoeker telt en niet per functie-IP.
// 3. bingr_login_finish: gelukt = teller weg; fout wachtwoord = tellen (5 in 15 min = 15 min dicht, oplopend 30/60).
// Nooit in een log: wachtwoord, e-mailadres, IP, tokens of antwoorden van GoTrue (alleen statuscodes en soorten).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { clientIp } from "../_shared/ip.ts";
import { type Begin, type Finish, handleLogin, publishableKey, secretKey, type TokenReply, unavailable } from "./logic.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SECRET = secretKey(Deno.env.get("SUPABASE_SECRET_KEYS"));
const PUBLISHABLE = publishableKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), Deno.env.get("SUPABASE_ANON_KEY"));
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || SECRET || "", {
  auth: { autoRefreshToken: false, persistSession: false },
});
if (!SECRET) console.warn("login: geen secret key (SUPABASE_SECRET_KEYS); /token zonder Sb-Forwarded-For");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Access-Control-Expose-Headers": "Retry-After",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const headers: Record<string, string> = { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" };
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error_code: "method_not_allowed", msg: "Use POST." }), { status: 405, headers });
  }
  const ip = clientIp(req);
  let body: unknown = null;
  try { body = await req.json(); } catch { body = null; }

  const reply = await handleLogin(body, {
    async begin(email) {
      const { data, error } = await admin.rpc("bingr_login_begin", { p_email: email, p_ip: ip });
      if (error) { console.error("login: bingr_login_begin", error.code ?? ""); return null; }
      return data as Begin;
    },
    async finish(userId, result) {
      const { data, error } = await admin.rpc("bingr_login_finish", { p_user: userId, p_result: result });
      if (error) { console.error("login: bingr_login_finish", error.code ?? ""); return null; }
      return data as Finish;
    },
    async token(email, password): Promise<TokenReply> {
      const key = SECRET || PUBLISHABLE;
      if (!key) return null;
      const h: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
      if (SECRET && ip && ip !== "?") h["Sb-Forwarded-For"] = ip;
      try {
        const r = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
          method: "POST", headers: h, body: JSON.stringify({ email, password }), signal: AbortSignal.timeout(15000),
        });
        return { status: r.status, text: await r.text() };
      } catch {
        return null;
      }
    },
    log: (m) => console.warn(m),
  }).catch(() => unavailable());

  if (reply.retryAfter) headers["Retry-After"] = String(reply.retryAfter);
  return new Response(reply.body, { status: reply.status, headers });
});
