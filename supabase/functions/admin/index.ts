// Bingr: beheer (bingr.online/admindashboard). Los van device-auth; nooit in de changelog.
// POST /functions/v1/admin met JSON {action, token?, ...}; header `apikey`.
// Inloggegevens alleen als function-secrets BINGR_ADMIN_USER / BINGR_ADMIN_PASSWORD (uit de GitHub-secrets).
//   login               {user, password}  -> {token, expires_at}   (5 fouten per IP = 15 min geblokkeerd: 429 {error:"locked", retry_after})
//   stats               {token}           -> {total_users, …, days:[…], platforms:[…], versions:[…], smtp}
//   users               {token, q?, page?, page_size?} -> {total, page, page_size, items:[…]} (e-mail gemaskeerd)
//   user_detail         {token, id}       -> {…, devices:[…]}
//   send_reset          {token, user_id}  -> {ok}    (standaard reset-mail van Supabase; beheer ziet of zet nooit wachtwoorden)
//   announce            {token, title_nl, body_nl, title_en?, body_en?, expires_at?, email} -> {ok, id, email_total}
//   announce_send       {token, id}       -> {email_total, email_sent, email_failed, done}  (volgende batch; herhalen tot done)
//   announcements_list  {token}           -> {items:[…]}
//   announcement_delete {token, id}       -> {ok}
//   unsubscribe         {t}               -> {ok}    (openbaar; t = ondertekend token uit de e-mail)
import { createClient } from "jsr:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@7.0.13";

const SITE = Deno.env.get("BINGR_SITE") ?? "https://bingr.online";
const env = (k: string) => Deno.env.get(k) ?? "";
const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { autoRefreshToken: false, persistSession: false },
});
const TOKEN_TTL_MS = 12 * 3600 * 1000;
const BATCH = 25;

function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const ok = /^https:\/\/(www\.)?bingr\.online$/.test(origin) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  return {
    ...(ok ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

// ---- crypto ----
const enc = new TextEncoder();
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
async function sha256(s: string) { return new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
function sameBytes(a: Uint8Array, b: Uint8Array) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}
async function hmacKey(material: string) {
  return crypto.subtle.importKey("raw", await sha256(material), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}
async function hmac(material: string, data: string) {
  return new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(material), enc.encode(data)));
}
// sleutel voor beheer-tokens: wijzigt het wachtwoord, dan vervallen alle tokens
const adminMaterial = () => `bingr-admin-v1|${env("BINGR_ADMIN_PASSWORD")}|${env("SUPABASE_SERVICE_ROLE_KEY")}`;
// sleutel voor afmeldlinks: blijft geldig (BINGR_SOURCES_KEY wordt nooit vervangen)
const unsubMaterial = () => `bingr-unsub-v1|${env("BINGR_SOURCES_KEY") || env("SUPABASE_SERVICE_ROLE_KEY")}`;

async function makeToken() {
  const exp = Date.now() + TOKEN_TTL_MS;
  const payload = b64u(enc.encode(JSON.stringify({ u: env("BINGR_ADMIN_USER"), exp })));
  return { token: `${payload}.${b64u(await hmac(adminMaterial(), payload))}`, expires_at: new Date(exp).toISOString() };
}
async function validToken(token: unknown) {
  if (!env("BINGR_ADMIN_PASSWORD") || typeof token !== "string" || token.length > 500) return false;
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return false;
  try {
    if (!sameBytes(unb64u(sig), await hmac(adminMaterial(), payload))) return false;
    const p = JSON.parse(new TextDecoder().decode(unb64u(payload)));
    return p.u === env("BINGR_ADMIN_USER") && typeof p.exp === "number" && p.exp > Date.now();
  } catch { return false; }
}
async function unsubToken(userId: string) {
  return `${userId}.${b64u((await hmac(unsubMaterial(), `unsub:${userId}`)).subarray(0, 18))}`;
}
async function unsubUser(t: unknown): Promise<string | null> {
  if (typeof t !== "string" || t.length > 120) return null;
  const [id, sig] = t.split(".");
  if (!/^[0-9a-f-]{36}$/i.test(id ?? "") || !sig) return null;
  try {
    return sameBytes(unb64u(sig), (await hmac(unsubMaterial(), `unsub:${id}`)).subarray(0, 18)) ? id.toLowerCase() : null;
  } catch { return null; }
}

// ---- hulpjes ----
const isUuid = (v: unknown) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function maskEmail(e: unknown) {
  const s = String(e ?? "");
  const at = s.lastIndexOf("@");
  if (at < 1) return s ? "***" : "";
  const local = s.slice(0, at), domain = s.slice(at + 1);
  const ml = local.length <= 2 ? local[0] + "***" : `${local[0]}***${local[local.length - 1]}`;
  const dot = domain.lastIndexOf(".");
  const md = dot > 0 ? `${domain[0]}***${domain.slice(dot)}` : "***";
  return `${ml}@${md}`;
}
function clientIp(req: Request) {
  const f = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  return (f || req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "?").slice(0, 64);
}
async function audit(action: string, ip: string, target?: string | null, detail?: unknown) {
  await admin.from("admin_audit").insert({ action, ip, target_user: target ?? null, detail: detail ?? null });
}
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const linkify = (s: string) => s.replace(/https:\/\/[^\s<]+[^\s<.,;:!?)]/g, (u) => `<a href="${u}" style="color:#ffffff">${u}</a>`);

// ---- e-mail ----
const smtpConfigured = () => !!(env("BINGR_SMTP_HOST") && env("BINGR_SMTP_USER") && env("BINGR_SMTP_PASSWORD") && env("BINGR_SMTP_FROM"));
function transport() {
  const port = Number(env("BINGR_SMTP_PORT") || 465);
  return nodemailer.createTransport({
    host: env("BINGR_SMTP_HOST"), port, secure: port !== 587 && port !== 25, // 465 = TLS (Supabase blokkeert 25 en 587)
    auth: { user: env("BINGR_SMTP_USER"), pass: env("BINGR_SMTP_PASSWORD") },
    connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 30000,
  });
}
function mailFor(lang: "nl" | "en", title: string, body: string, unsubUrl: string) {
  const nl = lang === "nl";
  const paras = body.split(/\n{2,}/).map((p) => `<p style="margin:0 0 16px;font-size:16px;line-height:24px;color:#d6d6d6">${linkify(esc(p)).replace(/\n/g, "<br>")}</p>`).join("");
  const foot = nl
    ? `Je ontvangt dit bericht omdat je een Bingr-account hebt. <a href="${unsubUrl}" style="color:#b3b3b3">Afmelden voor berichten</a>`
    : `You're receiving this because you have a Bingr account. <a href="${unsubUrl}" style="color:#b3b3b3">Unsubscribe from announcements</a>`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${esc(title)}</title></head>
<body style="margin:0;padding:0;background:#000000">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#000000"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<tr><td style="padding:0 4px 24px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="vertical-align:middle"><img src="${SITE}/apple-touch-icon.png" width="44" height="44" alt="" style="display:block;border-radius:10px"></td>
<td style="vertical-align:middle;padding-left:12px"><div style="font-size:30px;font-weight:900;letter-spacing:1px;color:#ffffff;line-height:30px">BINGR</div><div style="height:4px;width:74px;background:#E50914;border-radius:2px;margin-top:6px"></div></td>
</tr></table></td></tr>
<tr><td style="background:#141414;border-radius:12px;padding:36px 32px;border-top:4px solid #E50914">
<h1 style="margin:0 0 16px;font-size:26px;line-height:32px;font-weight:800;color:#ffffff">${esc(title)}</h1>${paras}
</td></tr>
<tr><td style="padding:24px 8px 0;font-size:12px;line-height:18px;color:#737373;text-align:center">${foot}<br><br>
<a href="${SITE}" style="color:#b3b3b3;text-decoration:none;font-weight:700">bingr.online</a></td></tr>
</table></td></tr></table></body></html>`;
  const text = `${title}\n\n${body}\n\n—\n${nl ? "Afmelden voor berichten" : "Unsubscribe from announcements"}: ${unsubUrl}\n${SITE}`;
  return { html, text };
}

Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > 64 * 1024) return json({ error: "too_large" }, 413);
    body = JSON.parse(text);
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
  } catch { return json({ error: "bad_json" }, 400); }
  try {
    return await handle(req, body, json);
  } catch (e) {
    console.error("admin", String(body.action ?? ""), e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});

async function handle(req: Request, body: Record<string, unknown>, json: (b: unknown, s?: number) => Response): Promise<Response> {
  const ip = clientIp(req);
  const action = String(body.action ?? "");

  if (action === "login") {
    if (!env("BINGR_ADMIN_USER") || !env("BINGR_ADMIN_PASSWORD")) return json({ error: "not_configured" }, 503);
    const { data: gate, error: ge } = await admin.rpc("bingr_admin_gate", { p_ip: ip });
    if (ge) throw new Error(ge.message);
    if (gate?.locked) return json({ error: "locked", retry_after: gate.retry_after ?? 900 }, 429);
    // altijd allebei vergelijken, op hashes van gelijke lengte (geen timing-verschil)
    const [a, b, c, d] = await Promise.all([sha256(String(body.user ?? "")), sha256(env("BINGR_ADMIN_USER")),
      sha256(String(body.password ?? "")), sha256(env("BINGR_ADMIN_PASSWORD"))]);
    const ok = sameBytes(a, b) && sameBytes(c, d);
    await admin.rpc("bingr_admin_result", { p_ip: ip, p_ok: ok });
    await audit(ok ? "login" : "login_failed", ip);
    if (!ok) return json({ error: "invalid_credentials" }, 401);
    return json(await makeToken());
  }

  if (action === "unsubscribe") {
    const id = await unsubUser(body.t);
    if (!id) return json({ error: "invalid_token" }, 400);
    const { error } = await admin.from("account_email_prefs").upsert({ user_id: id, email_opt_out: true, updated_at: new Date().toISOString() });
    // account bestaat niet meer (foreign key): er wordt toch al niets meer gestuurd
    if (error && !/foreign key/i.test(error.message)) throw new Error(error.message);
    return json({ ok: true });
  }

  if (!(await validToken(body.token))) return json({ error: "not_signed_in" }, 401);

  switch (action) {
    case "stats": {
      const { data, error } = await admin.rpc("bingr_admin_stats");
      if (error) throw new Error(error.message);
      return json({ ...data, smtp: smtpConfigured() });
    }
    case "users": {
      const size = Math.min(Math.max(Number(body.page_size ?? 25) || 25, 1), 50);
      const page = Math.max(Math.floor(Number(body.page ?? 0) || 0), 0);
      const q = String(body.q ?? "").trim().toLowerCase().slice(0, 100);
      const { data, error } = await admin.rpc("bingr_admin_users", { p_search: q, p_limit: size, p_offset: page * size });
      if (error) throw new Error(error.message);
      const items = (data?.items ?? []).map((u: Record<string, unknown>) => ({ ...u, email: maskEmail(u.email) }));
      return json({ total: data?.total ?? 0, page, page_size: size, items });
    }
    case "user_detail": {
      if (!isUuid(body.id)) return json({ error: "bad_id" }, 400);
      const { data, error } = await admin.rpc("bingr_admin_user", { p_id: body.id });
      if (error) throw new Error(error.message);
      if (!data) return json({ error: "not_found" }, 404);
      return json({ ...data, email: maskEmail(data.email) });
    }
    case "send_reset": {
      if (!isUuid(body.user_id)) return json({ error: "bad_id" }, 400);
      const { data: u } = await admin.auth.admin.getUserById(String(body.user_id));
      const email = u?.user?.email;
      if (!email) return json({ error: "not_found" }, 404);
      const { error } = await admin.auth.resetPasswordForEmail(email, { redirectTo: `${SITE}/reset/` });
      if (error) {
        const st = (error as { status?: number }).status ?? 500;
        console.error("send_reset", error.message);
        return json({ error: st === 429 ? "too_soon" : "reset_failed" }, st === 429 ? 429 : 502);
      }
      await audit("send_reset", ip, String(body.user_id));
      return json({ ok: true });
    }
    case "announce": {
      const t = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);
      const row = {
        title_nl: t(body.title_nl, 120), body_nl: t(body.body_nl, 4000),
        title_en: t(body.title_en, 120), body_en: t(body.body_en, 4000),
        expires_at: null as string | null, email: body.email === true, email_total: 0,
      };
      if (!row.title_nl || !row.body_nl) return json({ error: "text_missing" }, 400);
      if (body.expires_at) {
        const ms = Date.parse(String(body.expires_at));
        if (!Number.isFinite(ms) || ms < Date.now()) return json({ error: "bad_expires_at" }, 400);
        row.expires_at = new Date(ms).toISOString();
      }
      if (row.email) {
        if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 400);
        const { data: n, error } = await admin.rpc("bingr_email_recipients");
        if (error) throw new Error(error.message);
        row.email_total = Number(n ?? 0);
      }
      const { data, error } = await admin.from("announcements").insert(row).select("id").single();
      if (error) throw new Error(error.message);
      await audit("announce", ip, null, { id: data.id, email: row.email, email_total: row.email_total });
      return json({ ok: true, id: data.id, email_total: row.email_total });
    }
    case "announce_send": {
      if (!isUuid(body.id)) return json({ error: "bad_id" }, 400);
      if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 400);
      const { data: a } = await admin.from("announcements").select("title_nl,body_nl,title_en,body_en").eq("id", body.id).maybeSingle();
      if (!a) return json({ error: "not_found" }, 404);
      const { data: claim, error } = await admin.rpc("bingr_announce_claim", { p_id: body.id, p_batch: BATCH });
      if (error) throw new Error(error.message);
      let sent = 0, failed = 0;
      const items: { id: string; email: string; lang: string | null }[] = claim?.items ?? [];
      if (items.length) {
        const tx = transport();
        try {
          for (const r of items) {
            const en = r.lang !== "nl" && !!a.title_en && !!a.body_en;
            const url = `${SITE}/unsubscribe/?t=${encodeURIComponent(await unsubToken(r.id))}`;
            const { html, text } = mailFor(en ? "en" : "nl", en ? a.title_en : a.title_nl, en ? a.body_en : a.body_nl, url);
            try {
              await tx.sendMail({
                from: env("BINGR_SMTP_FROM"), to: r.email, subject: en ? a.title_en : a.title_nl, text, html,
                headers: { "List-Unsubscribe": `<${url}>` },
              });
              sent++;
            } catch (e) {
              failed++;
              console.error("announce_send", e instanceof Error ? e.message : e);
            }
            await new Promise((r) => setTimeout(r, 150));
          }
        } finally { tx.close(); }
      }
      const { data: rep, error: re } = await admin.rpc("bingr_announce_report", { p_id: body.id, p_sent: sent, p_failed: failed });
      if (re) throw new Error(re.message);
      if (rep?.done || claim?.done) await audit("announce_email", ip, null, { id: body.id, ...rep });
      return json({ ...rep, done: !!(rep?.done || claim?.done), batch_sent: sent, batch_failed: failed });
    }
    case "announcements_list": {
      const { data, error } = await admin.from("announcements")
        .select("id,title_nl,body_nl,title_en,body_en,created_at,expires_at,email,email_total,email_sent,email_failed,email_done_at")
        .order("created_at", { ascending: false }).limit(50);
      if (error) throw new Error(error.message);
      const cut = Date.now() - 30 * 864e5;
      const items = (data ?? []).map((a) => ({
        ...a, active: Date.parse(a.created_at) > cut && (!a.expires_at || Date.parse(a.expires_at) > Date.now()),
      }));
      return json({ items, smtp: smtpConfigured() });
    }
    case "announcement_delete": {
      if (!isUuid(body.id)) return json({ error: "bad_id" }, 400);
      const { error } = await admin.from("announcements").delete().eq("id", body.id);
      if (error) throw new Error(error.message);
      await audit("announcement_delete", ip, null, { id: body.id });
      return json({ ok: true });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}
