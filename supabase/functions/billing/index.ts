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
// Build 167 (docs/ACCOUNT.md, "Build 167: alleen Lifetime"):
//   config      + lifetime_only {enabled, cutover_at, after_cutover, trial_days, announce_at, announced} en iap {apple,
//               product_id} (publiek, ook zonder inloggen); ingelogd (en aan) in lifetime_only ook code, code_valid_until,
//               discount_pct en discounted_price_cents (code null = geen bruikbare code)
//   checkout    + code? (BINGR-XXXX-XXXX; van dít account, ongebruikt, geldig; anders 400 code_invalid). Zonder code de
//               eigen geldige code automatisch. guest: true (zonder inloggen): gastaankoop, Stripe vraagt het e-mailadres,
//               success-URL /upgrade/klaar/?claim=<token>&session_id=…; max. 30 per IP per 10 min.
//   status      + zonder inloggen met {session_id, claim_token} (gastaankoop): {paid, status, payment_status, email?}
//               (email alleen als het claimtoken bij die sessie hoort; anders 404 not_found)
//   claim       (POST, ingelogd, {claim_token?}) -> {claimed, result, plan, entitlements}   koppelt een gastaankoop (token:
//               één keer, 30 dagen) en alle ongeclaimde aankopen met het bevestigde e-mailadres van dit account;
//               400 claim_invalid / claim_expired, 409 owned_by_other_account (al door een ander account geclaimd),
//               409 already_lifetime (account is al Lifetime; de aankoop blijft ongeclaimd)
//   admin_codes_generate {dry_run?, batch?} / admin_codes_stats {}   (beheer; header x-lifetime-secret =
//               LIFETIME_ADMIN_SECRET, anders 403 forbidden): kortingscodes in Stripe aanmaken (_shared/lifetime_codes.ts)
//   apple_verify (POST, ingelogd, {signed_transaction, platform?}) -> {plan:"lifetime", entitlements}   StoreKit 2-JWS
//               (x5c tot Apple Root CA - G3, ES256, bundle/product, geen revocationDate); de originalTransactionId wordt
//               gekoppeld aan het eerste account dat hem claimt. 400 bad_transaction (+reason), 409 owned_by_other_account,
//               409 transaction_revoked, 429 rate_limited.
// Build 181 (Bingr Premium, docs/ACCOUNT.md "Build 181" §6):
//   config      + premium {enabled, web, apple, required_new, new_from, existing_from, existing_after, trial_days,
//               show_prices_web, stripe_ready, prices, products}; ingelogd ook premium.view (premiumView, platform web)
//   checkout    + plan? (month|half|year|lifetime). Zonder plan: oude Lifetime alleen met legacy_offer of als de groep web
//               niet meedoet, anders 400 plan_required. 409 premium_off / already_lifetime / already_premium,
//               503 premium_not_configured. Abonnement: proef alleen als trial_eligible. Gast (guest: true) ook met plan.
//   portal      (POST, ingelogd, {return_url?, lang?}) -> {url}   Stripe Customer Portal; 404 no_customer
//   refresh     (POST, ingelogd, {platform?}) -> {synced, premium, entitlements}   Stripe-abonnementen opnieuw ophalen
//   status      + sessies met mode=subscription: {paid, status, payment_status, plan, premium}
//   claim       + gast-abonnementen (claimtoken of e-mailadres)
//   apple_verify+ de drie abonnementen en lifetime49 -> {plan: month|half|year|lifetime, premium, entitlements}
//   admin_premium_setup {dry_run?} (x-lifetime-secret): Stripe-producten, -prijzen en Customer Portal aanmaken
// Build 193 (docs/ACCOUNT.md, "Build 193"):
//   apple_verify+ een Lifetime uit de Apple-sandbox (TestFlight, App Review) is alleen voor een testaccount
//               (app_settings.premium.test_users) blijvend. Elk ander account krijgt eenmalig 3 dagen toegang, gerekend vanaf
//               zijn eerste sandbox-aankoop; het antwoord heeft dan ook sandbox: "temporary"|"expired" en sandbox_until.
//   funnel      (POST, zonder inloggen, {step, platform, build, product?, error?}) -> altijd 200 {ok:true} (ongeldig:
//               {ok:false}); anonieme dagtelling van de betaalstappen (_shared/funnel.ts, tabel billing_funnel_daily)
import { createClient } from "jsr:@supabase/supabase-js@2";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { clientIp } from "../_shared/ip.ts";
import {
  billingConfig, checkoutParams, guestCheckoutParams, guestFromSession, guestSubFromSession, guestIdempotencyKey, idempotencyKey, isClaimToken, isStripeId,
  MAX_BODY_CHARS, newClaimToken, normalizeLang, purchaseFromSession, purchaseView, type PurchaseRow, sha256Hex,
} from "../_shared/billing.ts";
import { grant } from "../_shared/billing_store.ts";
import { normalizePlatform, PRICE_CENTS, PRICE_CURRENCY, PRODUCT_NAME } from "../_shared/plans.ts";
import { APPLE_PRODUCT_ID, checkTransaction } from "../_shared/apple.ts";
import { verifyAppleJws } from "../_shared/apple_jws.ts";
import { grantApple } from "../_shared/apple_store.ts";
import { checkCode, configGroup, normalizeLifetime, priceAfter, promotionCodeOf, publicLifetime } from "../_shared/lifetime.ts";
import { buildEntitlements, codeByText, codeOf, loadSettings, markRedeemed } from "../_shared/lifetime_store.ts";
import { claimByEmail, claimToken, grantGuest } from "../_shared/guest_store.ts";
import { codesGenerate, codesStats } from "../_shared/lifetime_codes.ts";
import { sameSecret } from "../newsletter/logic.ts";
import { funnelEvent } from "../_shared/funnel.ts";
import { effectivePlanRow, isTestUser, normalizePremium, publicPremium } from "../_shared/premium.ts";
const normalizePremiumNull = () => normalizePremium(null);
import { claimSubToken } from "../_shared/premium_store.ts";
import { appleSubscription, isPremiumPlan, portal, premiumCheckout, premiumSetup, premiumState, refresh, syncStripeSub } from "./premium.ts";
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

type Authed = { id: string; email?: string; created_at?: string };
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
  const { data, error } = await admin.from("account_plans").select("plan,source,premium_until").eq("user_id", userId).maybeSingle();
  if (error) throw new Error(`account_plans: ${error.code ?? "fout"}`);
  // build 193: een verlopen (tijdelijke sandbox-)Lifetime telt niet als "al Lifetime"
  return effectivePlanRow(data as { plan?: string; source?: string; premium_until?: string | null } | null);
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
    // build 187: een Apple-abonnement stuurt twee JWS'en mee (transactie + verlengingsinfo, elk ~5.000 tekens met de certificaatketen);
    // de oude grens van 10.000 tekens gaf bij elke abonnementsaankoop een 413. Zie MAX_BODY_CHARS in _shared/billing.ts.
    if (text.length > MAX_BODY_CHARS) return json({ error: "too_large" }, 413);
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
      const base = { ok: true, enabled: !!cfg.secretKey, mode: cfg.mode, price_cents: PRICE_CENTS, currency: PRICE_CURRENCY, product: PRODUCT_NAME };
      if (action === "ping") return json(base);
      // build 167: publiek deel van Lifetime-only en de koopknop in de Apple-apps (bij een fout: zoals nu, alles uit)
      let s: Awaited<ReturnType<typeof loadSettings>> | null = null;
      try { s = await loadSettings(admin); } catch (e) { console.error("billing config settings", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
      const lo = s?.lifetime ?? normalizeLifetime(null);
      const on = lo.enabled;
      // build 168: per platformgroep (body.platform of ?platform=, anders de User-Agent; onbekend = Apple, de voorzichtige kant)
      const group = configGroup(body.platform ?? url.searchParams.get("platform"), req.headers.get("User-Agent"));
      let lifetimeOnly: Record<string, unknown> = publicLifetime(lo, group);
      // ingelogd (optioneel): de eigen kortingscode, tot wanneer, het percentage en de prijs na korting (null = geen code)
      if ((req.headers.get("Authorization") ?? "").split(".").length === 3 && on) {
        const u = await authed(req, json);
        if (!(u instanceof Response)) {
          // build 168: after_cutover / new_paid per account (een bestaand account blijft gratis tot cutover_at)
          lifetimeOnly = publicLifetime(lo, group, Date.now(), { createdAt: u.created_at });
          const c = lifetimeOnly.new_paid ? { ok: false as const } : checkCode(await codeOf(admin, u.id).catch(() => null), u.id);
          Object.assign(lifetimeOnly, {
            code: c.ok ? c.row.code : null, code_valid_until: c.ok ? c.row.expires_at : null, discount_pct: lo!.discount_pct,
            discounted_price_cents: c.ok ? priceAfter(PRICE_CENTS, lo!.discount_pct) : null,
          });
        }
      }
      // build 181: Premium (publiek; ingelogd ook de eigen toestand)
      const premium: Record<string, unknown> = { ...publicPremium(s?.premium ?? normalizePremiumNull(), group, cfg.mode) };
      if (s && (req.headers.get("Authorization") ?? "").split(".").length === 3) {
        const u = await authed(req, json);
        if (!(u instanceof Response)) {
          try { premium.view = (await premiumState(admin, u, "web", s)).view; } catch (e) { console.error("billing config premium", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
        }
      }
      return json({ ...base, lifetime_only: lifetimeOnly, iap: { apple: !!s?.iap.apple, product_id: APPLE_PRODUCT_ID }, premium });
    }
    // build 167: beheer (functie admin in bingr-beheer), header x-lifetime-secret = LIFETIME_ADMIN_SECRET
    if (action === "admin_codes_generate" || action === "admin_codes_stats") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (!sameSecret(req.headers.get("x-lifetime-secret"), Deno.env.get("LIFETIME_ADMIN_SECRET"))) return json({ error: "forbidden" }, 403);
      if (action === "admin_codes_stats") return json({ ok: true, ...(await codesStats(admin)) });
      return await codesGenerate(admin, body);
    }
    if (action === "admin_premium_setup") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (!sameSecret(req.headers.get("x-lifetime-secret"), Deno.env.get("LIFETIME_ADMIN_SECRET"))) return json({ error: "forbidden" }, 403);
      return await premiumSetup(admin, cfg, body, json);
    }
    // build 193: betaaltrechter (zonder inloggen; alleen dagtellingen). Altijd 200: een app mag hier nooit op stuklopen.
    if (action === "funnel") {
      try {
        const ev = req.method === "POST" ? funnelEvent(body) : null;
        if (!ev) return json({ ok: false });
        if (await rateLimited(`billing:funnel:ip:${clientIp(req)}`, 120, 600)) return json({ ok: true });
        const { error } = await admin.rpc("bingr_funnel_hit", { p_platform: ev.platform, p_step: ev.step, p_product: ev.product, p_error: ev.error });
        if (error) console.error("billing funnel", error.code ?? "fout");
      } catch (e) { console.error("billing funnel", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
      return json({ ok: true });
    }
    if (!["checkout", "status", "purchases", "claim", "apple_verify", "portal", "refresh"].includes(action)) return json({ error: "unknown_action" }, 400);
    // build 181: Premium-checkout als gast (met plan)
    if (action === "checkout" && body.guest === true && isPremiumPlan(body.plan) && !(req.headers.get("Authorization") ?? "").includes(".")) {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (!cfg.secretKey) return json({ error: "billing_unavailable" }, 503);
      if (body.waiver !== true) return json({ error: "waiver_required" }, 400);
      if (await rateLimited(`billing:ip:${clientIp(req)}`, 30, 600)) return json({ error: "rate_limited" }, 429);
      return await premiumCheckout(admin, cfg, body, null, json, newClaimToken);
    }

    // build 167: gastaankoop (eerst betalen, dan het account)
    if (action === "checkout" && body.guest === true && !(req.headers.get("Authorization") ?? "").includes(".")) {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (!cfg.secretKey) { console.log("billing checkout guest: billing_unavailable"); return json({ error: "billing_unavailable" }, 503); }
      if (body.waiver !== true) return json({ error: "waiver_required" }, 400);
      if (await rateLimited(`billing:ip:${clientIp(req)}`, 30, 600)) return json({ error: "rate_limited" }, 429);
      const lang = normalizeLang(body.lang), token = newClaimToken();
      const r = await stripe(cfg.secretKey, "POST", "checkout/sessions",
        guestCheckoutParams({ lang, automaticTax: cfg.automaticTax, waiverAt: new Date().toISOString(), claimToken: token }),
        { idempotencyKey: guestIdempotencyKey(token) });
      const sUrl = r.body?.url;
      if (!r.ok || typeof sUrl !== "string" || !sUrl.startsWith("https://checkout.stripe.com/")) {
        console.error("billing checkout guest stripe", stripeError(r));
        return json({ error: "stripe_error" }, 502);
      }
      console.log("billing checkout guest: sessie aangemaakt", cfg.mode);
      return json({ url: sUrl });
    }
    // build 167: status van een gastaankoop zonder inloggen (alleen met het claimtoken van die sessie)
    if (action === "status" && !(req.headers.get("Authorization") ?? "").includes(".") && body.claim_token !== undefined) {
      const sid = String(body.session_id ?? "");
      if (!isStripeId(sid, "cs_") || !isClaimToken(body.claim_token)) return json({ error: "bad_session_id" }, 400);
      if (!cfg.secretKey) return json({ error: "billing_unavailable" }, 503);
      if (await rateLimited(`billing:status:ip:${clientIp(req)}`, 60, 600)) return json({ error: "rate_limited" }, 429);
      const r = await stripe(cfg.secretKey, "GET", `checkout/sessions/${sid}`);
      if (r.status === 404) return json({ error: "not_found" }, 404);
      if (!r.ok) { console.error("billing status stripe", stripeError(r)); return json({ error: "stripe_error" }, 502); }
      const g = guestFromSession(r.body);
      // build 193: ook een gast-abonnement (Premium) is zo op te vragen, zodat /upgrade/klaar/ het e-mailadres kan invullen
      const gs = g ? null : guestSubFromSession(r.body, body.claim_token);
      if (gs) return json({ paid: gs.paid, status: r.body.status ?? null, payment_status: r.body.payment_status ?? null, email: gs.email });
      if (!g || g.claimToken !== body.claim_token) return json({ error: "not_found" }, 404);
      const paid = r.body.payment_status === "paid";
      if (paid) await grantGuest(admin, g); // vangnet als de webhook nog niet binnen is (idempotent)
      return json({ paid, status: r.body.status ?? null, payment_status: r.body.payment_status ?? null, email: g.email });
    }
    const user = await authed(req, json);
    if (user instanceof Response) return user;
    const uid = user.id.toLowerCase();

    if (action === "portal" || action === "refresh") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (await rateLimited(`billing:${action}:u:${uid}`, 20, 600)) return json({ error: "rate_limited" }, 429);
      if (action === "portal") return cfg.secretKey ? await portal(admin, cfg, body, user, json) : json({ error: "billing_unavailable" }, 503);
      return await refresh(admin, cfg, body, user, json);
    }

    if (action === "checkout") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      // build 181: Premium (met plan), of zonder plan de oude Lifetime alleen als dat nog mag
      if (body.plan !== undefined && body.plan !== null && body.plan !== "") {
        if (!isPremiumPlan(body.plan)) return json({ error: "bad_plan" }, 400);
        if (!cfg.secretKey) return json({ error: "billing_unavailable" }, 503);
        if (body.waiver !== true) return json({ error: "waiver_required" }, 400);
        if (await rateLimited(`billing:u:${uid}`, 10, 600) || await rateLimited(`billing:ip:${clientIp(req)}`, 30, 600)) return json({ error: "rate_limited" }, 429);
        return await premiumCheckout(admin, cfg, body, user, json, newClaimToken);
      }
      try {
        const st = await premiumState(admin, user, "web");
        if (st.view.enabled && !st.view.legacy_offer) return json({ error: "plan_required" }, 400);
      } catch (e) { console.error("billing checkout premium", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
      const cur = await planOf(uid);
      if (cur?.plan === "lifetime" && cur.source !== "subscription") return json({ error: "already_lifetime", source: cur.source ?? null }, 409);
      if (!cfg.secretKey) { console.log("billing checkout: billing_unavailable"); return json({ error: "billing_unavailable" }, 503); }
      if (body.waiver !== true) return json({ error: "waiver_required" }, 400);
      if (await rateLimited(`billing:u:${uid}`, 10, 600) || await rateLimited(`billing:ip:${clientIp(req)}`, 30, 600)) {
        return json({ error: "rate_limited" }, 429);
      }
      const lang = normalizeLang(body.lang);
      const now = Date.now();
      // build 167: kortingscode. Meegegeven: moet van dit account zijn, ongebruikt en geldig (anders 400 code_invalid).
      // Zonder: de eigen geldige code automatisch (als die er is). Alleen codes uit dezelfde Stripe-modus.
      let promo: string | null = null;
      if (body.code !== undefined && body.code !== null && body.code !== "") {
        const c = checkCode(await codeByText(admin, body.code), uid, now);
        const mode = c.ok ? (await admin.from("lifetime_codes").select("stripe_mode").eq("user_id", uid).maybeSingle()).data?.stripe_mode : null;
        if (!c.ok || (mode && mode !== cfg.mode)) return json({ error: "code_invalid", reason: c.ok ? "other_mode" : c.reason }, 400);
        promo = c.row.stripe_promotion_code_id;
      } else {
        const own = await codeOf(admin, uid).catch(() => null);
        const c = checkCode(own, uid, now);
        if (c.ok) {
          const { data: m } = await admin.from("lifetime_codes").select("stripe_mode").eq("user_id", uid).maybeSingle();
          if (!m?.stripe_mode || m.stripe_mode === cfg.mode) promo = c.row.stripe_promotion_code_id;
        }
      }
      const params = checkoutParams({ userId: uid, email: user.email ?? null, lang, automaticTax: cfg.automaticTax, waiverAt: new Date(now).toISOString(), promotionCode: promo });
      const r = await stripe(cfg.secretKey, "POST", "checkout/sessions", params, { idempotencyKey: idempotencyKey(uid, lang, cfg.automaticTax, now, promo) });
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
      // build 181: abonnement (mode subscription): vastleggen als vangnet en de Premium-toestand geven
      if (s.mode === "subscription") {
        const ref = String(s.client_reference_id ?? (s.metadata as Record<string, unknown> | undefined)?.user_id ?? "").toLowerCase();
        if (ref !== uid) return json({ error: "not_found" }, 404);
        const subId = typeof s.subscription === "string" ? s.subscription : (s.subscription as { id?: string } | null)?.id;
        if (subId && s.status === "complete") console.log("billing status premium", await syncStripeSub(admin, cfg.secretKey, await loadSettings(admin), subId, uid));
        const st = await premiumState(admin, user, "web");
        return json({ paid: s.status === "complete", status: s.status ?? null, payment_status: s.payment_status ?? null, plan: st.view.plan, premium: st.view });
      }
      const p = purchaseFromSession(s);
      // alleen de eigen sessie (zelfde account-id); anders alsof hij niet bestaat
      if (!p || p.userId !== uid) return json({ error: "not_found" }, 404);
      const paid = s.payment_status === "paid";
      if (paid) {
        const g = await grant(admin, p);
        if (g.granted) console.log("billing status: Lifetime gezet (vangnet)");
        const promo = promotionCodeOf(s);
        if (promo) await markRedeemed(admin, uid, promo, p.sessionId);
      }
      const plan = await planOf(uid);
      return json({ paid, status: s.status ?? null, payment_status: s.payment_status ?? null, plan: plan?.plan === "lifetime" ? "lifetime" : "free" });
    }

    if (action === "claim") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (await rateLimited(`billing:claim:u:${uid}`, 20, 600)) return json({ error: "rate_limited" }, 429);
      let result = "none";
      if (body.claim_token !== undefined && body.claim_token !== null && body.claim_token !== "") {
        if (!isClaimToken(body.claim_token)) return json({ error: "claim_invalid" }, 400);
        // al Lifetime (bv. cadeau, beheer of eerder gekocht): niet nog een aankoop aan dit account hangen; de aankoop blijft
        // ongeclaimd (ander account, of terugbetalen via support / koppelen in het beheer)
        const cur = await planOf(uid);
        // build 181: een abonnement (spiegel) mag nog een gekochte Lifetime claimen
        if (cur?.plan === "lifetime" && cur.source !== "subscription") {
          const mine = await admin.from("billing_purchases").select("id").eq("user_id", uid).eq("claim_token_hash", await sha256Hex(body.claim_token)).maybeSingle();
          if (!mine.data) return json({ error: "already_lifetime", source: cur.source ?? null }, 409);
        }
        let c = await claimToken(admin, uid, body.claim_token);
        // build 181: geen Lifetime-aankoop met dit token: misschien een gast-abonnement (Premium)
        if (c.result === "invalid") {
          const r = await claimSubToken(admin, uid, body.claim_token);
          if (r === "already_lifetime") return json({ error: "already_lifetime", source: cur?.source ?? null }, 409);
          c = { ok: r === "claimed" || r === "already_yours", result: (["claimed", "already_yours", "expired", "owned_by_other_account"].includes(r) ? r : "invalid") as typeof c.result };
        }
        result = c.result;
        if (c.result === "invalid") return json({ error: "claim_invalid" }, 400);
        if (c.result === "expired") return json({ error: "claim_expired" }, 400);
        if (c.result === "revoked") return json({ error: "claim_invalid", reason: "revoked" }, 400);
        if (c.result === "owned_by_other_account") return json({ error: "owned_by_other_account" }, 409);
      }
      const byMail = await claimByEmail(admin, uid);
      if (result === "none" && byMail > 0) result = "claimed_by_email";
      const ent = await buildEntitlements(admin, uid, user.created_at, normalizePlatform(body.platform) ?? "web");
      console.log("billing claim", result);
      return json({ claimed: result === "claimed" || result === "claimed_by_email" || result === "already_yours", result, plan: ent.plan, entitlements: ent });
    }

    if (action === "apple_verify") {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (await rateLimited(`billing:apple:u:${uid}`, 30, 600)) return json({ error: "rate_limited" }, 429);
      const v = await verifyAppleJws(body.signed_transaction);
      if (!v.ok) { console.log("billing apple_verify", v.error); return json({ error: "bad_transaction", reason: v.error }, 400); }
      // build 181: abonnementen (Premium); Lifetime (oud en lifetime49) gaat verder zoals build 167
      const premiumRes = await appleSubscription(admin, v.payload, body, user, json);
      if (premiumRes) return premiumRes;
      const t = checkTransaction(v.payload);
      if (!t.ok) {
        console.log("billing apple_verify", t.error);
        return t.error === "revoked" ? json({ error: "transaction_revoked" }, 409) : json({ error: "bad_transaction", reason: t.error }, 400);
      }
      // build 193: sandbox (TestFlight, App Review) geeft alleen een testaccount blijvend Lifetime; anders 3 dagen, eenmalig
      let testUser = false;
      if (t.tx.environment === "test") {
        try { testUser = isTestUser((await loadSettings(admin)).premium, uid); }
        catch (e) { console.error("billing apple_verify settings", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
      }
      const g = await grantApple(admin, uid, t.tx, new Date().toISOString(), { testUser });
      if (!g.ok) {
        console.log("billing apple_verify", g.error);
        return g.error === "revoked" ? json({ error: "transaction_revoked" }, 409) : json({ error: "owned_by_other_account" }, 409);
      }
      console.log("billing apple_verify", g.granted ? "granted" : "already", t.tx.environment, g.sandbox ?? (testUser ? "test_user" : ""));
      const ent = await buildEntitlements(admin, uid, user.created_at, normalizePlatform(body.platform) ?? "ios");
      return json({ plan: ent.plan, premium: ent.premium, entitlements: ent, ...(g.sandbox ? { sandbox: g.sandbox, sandbox_until: g.sandbox_until } : {}) });
    }

    // purchases (build 167: eerst ongeclaimde aankopen met het bevestigde e-mailadres koppelen, best effort)
    try { await claimByEmail(admin, uid); } catch (e) { console.error("billing claim_email", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
    const { data, error } = await admin.from("billing_purchases")
      .select("stripe_session_id,provider,created_at,paid_at,amount,currency,status,refunded_at").eq("user_id", uid)
      .in("status", ["paid", "refunded", "disputed", "pending"]).order("created_at", { ascending: false }).limit(10);
    if (error) throw new Error(`billing_purchases: ${error.code ?? "fout"}`);
    const rows = (data ?? []) as (PurchaseRow & { stripe_session_id: string | null; provider?: string })[];
    const items = await Promise.all(rows.map(async (row) => {
      // build 167: Apple-aankopen hebben geen Stripe-sessie (kwitantie in de App Store); provider erbij
      if (!row.stripe_session_id) return { ...purchaseView(row), provider: row.provider ?? "apple" };
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
