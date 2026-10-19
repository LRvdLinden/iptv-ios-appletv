// Bingr: betalen via Stripe (build 133) voor Lifetime (€ 4,99 eenmalig) op https://bingr.online/upgrade/.
// Contract in docs/ACCOUNT.md, "Betalen (Stripe, build 133)". Alleen de website betaalt; de Apple-apps tonen nooit een
// prijs, koopknop of QR-code. Geheimen alleen als function-secrets (STRIPE_SECRET_KEY, via de workflow Backend).
// Nooit loggen: sleutels, e-mailadressen, namen, betaalgegevens, kwitantielinks. Alleen foutcodes en tellingen.
//
// /functions/v1/billing/<actie> (of {action} in de JSON-body, of ?action=), header `apikey`:
//   config     (GET/POST, zonder inloggen) -> {enabled, mode: "test"|"live"|null, price_cents, currency, product}
//   checkout   (POST, ingelogd, body {lang?: "nl"|"en", waiver: true}) -> {url}   (Stripe Checkout, doorsturen)
//              400 waiver_required (geen vinkje directe levering / afstand herroepingsrecht), 409 already_lifetime,
//              429 rate_limited, 503 billing_unavailable (geen STRIPE_SECRET_KEY), 502 stripe_error
//   status     (GET/POST, ingelogd, session_id) -> {paid, status, payment_status, plan}   (vangnet: zet Lifetime meteen als
//              de sessie betaald is, ook als de webhook nog niet binnen is); 404 not_found (niet van dit account)
//   purchases  (GET/POST, ingelogd) -> {items:[{created_at, paid_at, amount, currency, status, refunded_at, receipt_url,
//              invoice_url, invoice_pdf}]}   (eigen aankopen; links van Stripe, alleen voor de klant zelf)
//   Zonder (geldig) token: 401 {error:"not_signed_in"}; geblokkeerd account: 401 user_banned.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { clientIp } from "../_shared/ip.ts";
import {
  billingConfig, checkoutParams, idempotencyKey, isStripeId, normalizeLang, purchaseFromSession, purchaseView, type PurchaseRow,
} from "../_shared/billing.ts";
import { grant } from "../_shared/billing_store.ts";
import { PRICE_CENTS, PRICE_CURRENCY, PRODUCT_NAME } from "../_shared/plans.ts";
import { stripe, stripeError, StripeUnavailable } from "../_shared/stripe.ts";

const env = (k: string) => Deno.env.get(k) ?? undefined;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const ORIGINS = new Set(["https://bingr.online", "https://www.bingr.online"]);
function corsFor(req: Request): Record<string, string> {
  const o = req.headers.get("Origin") ?? "";
  const allow = ORIGINS.has(o) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o) ? o : "https://bingr.online";
  return {
    "Access-Control-Allow-Origin": allow, Vary: "Origin",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Max-Age": "86400",
  };
}

type Authed = { id: string; email?: string };
async function authed(req: Request, json: (b: unknown, s?: number) => Response): Promise<Authed | Response> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return json({ error: "not_signed_in" }, 401);
  const { data, error } = await admin.auth.getUser(token);
  if (!error && data?.user) return bannedUntilActive((data.user as { banned_until?: string }).banned_until) ? json(BANNED_BODY, 401) : data.user;
  if (isBanError(error)) return json(BANNED_BODY, 401);
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? json({ error: "not_signed_in" }, 401) : json({ error: "unavailable" }, 503);
}
async function rateLimited(key: string, max: number, windowS: number): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: key, p_max: max, p_window: windowS });
  if (error) { console.error("billing rate_hit", error.code ?? "fout"); return false; }
  return data === false;
}
async function planOf(userId: string) {
  const { data, error } = await admin.from("account_plans").select("plan,source").eq("user_id", userId).maybeSingle();
  if (error) throw new Error(`account_plans: ${error.code ?? "fout"}`);
  return data as { plan?: string; source?: string } | null;
}

Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "GET" && req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const url = new URL(req.url);
  let body: Record<string, unknown> = {};
  if (req.method === "POST") {
    const text = await req.text().catch(() => "");
    if (text.length > 10_000) return json({ error: "too_large" }, 413);
    if (text.trim()) {
      try { const b = JSON.parse(text); if (b && typeof b === "object" && !Array.isArray(b)) body = b; else return json({ error: "bad_json" }, 400); }
      catch { return json({ error: "bad_json" }, 400); }
    }
  }
  const seg = url.pathname.split("/").filter(Boolean);
  const last = seg[seg.length - 1];
  const action = String(body.action ?? url.searchParams.get("action") ?? (last && last !== "billing" ? last : "")).toLowerCase();
  const cfg = billingConfig(env);
  try {
    if (action === "config" || action === "ping") {
      return json({ ok: true, enabled: !!cfg.secretKey, mode: cfg.mode, price_cents: PRICE_CENTS, currency: PRICE_CURRENCY, product: PRODUCT_NAME });
    }
    if (!["checkout", "status", "purchases"].includes(action)) return json({ error: "unknown_action" }, 400);
    const user = await authed(req, json);
    if (user instanceof Response) return user;
    const uid = user.id.toLowerCase();

    if (action === "checkout") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const cur = await planOf(uid);
      if (cur?.plan === "lifetime") return json({ error: "already_lifetime", source: cur.source ?? null }, 409);
      if (!cfg.secretKey) { console.log("billing checkout: billing_unavailable"); return json({ error: "billing_unavailable" }, 503); }
      if (body.waiver !== true) return json({ error: "waiver_required" }, 400);
      if (await rateLimited(`billing:u:${uid}`, 10, 600) || await rateLimited(`billing:ip:${clientIp(req)}`, 30, 600)) {
        return json({ error: "rate_limited" }, 429);
      }
      const lang = normalizeLang(body.lang);
      const now = Date.now();
      const params = checkoutParams({ userId: uid, email: user.email ?? null, lang, automaticTax: cfg.automaticTax, waiverAt: new Date(now).toISOString() });
      const r = await stripe(cfg.secretKey, "POST", "checkout/sessions", params, { idempotencyKey: idempotencyKey(uid, lang, cfg.automaticTax, now) });
      const sUrl = r.body?.url;
      if (!r.ok || typeof sUrl !== "string" || !sUrl.startsWith("https://checkout.stripe.com/")) {
        console.error("billing checkout stripe", stripeError(r));
        return json({ error: "stripe_error" }, 502);
      }
      console.log("billing checkout: sessie aangemaakt", cfg.mode);
      return json({ url: sUrl });
    }

    if (action === "status") {
      const sid = String(body.session_id ?? url.searchParams.get("session_id") ?? "");
      if (!isStripeId(sid, "cs_")) return json({ error: "bad_session_id" }, 400);
      if (!cfg.secretKey) return json({ error: "billing_unavailable" }, 503);
      const r = await stripe(cfg.secretKey, "GET", `checkout/sessions/${sid}`);
      if (r.status === 404) return json({ error: "not_found" }, 404);
      if (!r.ok) { console.error("billing status stripe", stripeError(r)); return json({ error: "stripe_error" }, 502); }
      const s = r.body as Record<string, unknown>;
      const p = purchaseFromSession(s);
      // alleen de eigen sessie (zelfde account-id); anders alsof hij niet bestaat
      if (!p || p.userId !== uid) return json({ error: "not_found" }, 404);
      const paid = s.payment_status === "paid";
      if (paid) {
        const g = await grant(admin, p);
        if (g.granted) console.log("billing status: Lifetime gezet (vangnet)");
      }
      const plan = await planOf(uid);
      return json({ paid, status: s.status ?? null, payment_status: s.payment_status ?? null, plan: plan?.plan === "lifetime" ? "lifetime" : "free" });
    }

    // purchases
    const { data, error } = await admin.from("billing_purchases")
      .select("stripe_session_id,created_at,paid_at,amount,currency,status,refunded_at").eq("user_id", uid)
      .in("status", ["paid", "refunded", "disputed", "pending"]).order("created_at", { ascending: false }).limit(10);
    if (error) throw new Error(`billing_purchases: ${error.code ?? "fout"}`);
    const rows = (data ?? []) as (PurchaseRow & { stripe_session_id: string })[];
    const items = await Promise.all(rows.map(async (row) => {
      if (!cfg.secretKey || row.status === "pending") return purchaseView(row);
      try {
        const r = await stripe(cfg.secretKey, "GET", `checkout/sessions/${row.stripe_session_id}`,
          [["expand[]", "invoice"], ["expand[]", "payment_intent.latest_charge"]], { timeoutMs: 8000 });
        if (!r.ok) return purchaseView(row);
        // deno-lint-ignore no-explicit-any
        const s = r.body as any;
        return purchaseView(row, {
          receipt_url: s?.payment_intent?.latest_charge?.receipt_url,
          invoice_url: s?.invoice?.hosted_invoice_url, invoice_pdf: s?.invoice?.invoice_pdf,
        });
      } catch { return purchaseView(row); }
    }));
    return json({ items });
  } catch (e) {
    console.error("billing", action, e instanceof StripeUnavailable ? "stripe_unreachable" : e instanceof Error ? e.message.slice(0, 80) : "fout");
    return json({ error: e instanceof StripeUnavailable ? "stripe_unavailable" : "server_error" }, e instanceof StripeUnavailable ? 503 : 500);
  }
});
