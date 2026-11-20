// Build 181 (Bingr Premium): de Premium-acties van de functie billing (docs/ACCOUNT.md, "Build 181", §6). Los van index.ts
// zodat de Lifetime-stroom van build 133/167 leesbaar blijft. Nooit loggen: sleutels, e-mailadressen, klant-id's,
// claimtokens of portal-links; alleen foutcodes, modus en tellingen.
import { type BillingConfig, normalizeLang } from "../_shared/billing.ts";
import {
  APPLE_PREMIUM_PRODUCTS, appleProduct, effectivePlanRow, lifetime49CheckoutParams, lifetimeSource, lookupKey, type PremiumPlan,
  PREMIUM_PLANS, premiumIdempotencyKey, premiumView, portalConfigParams, portalParams, portalReturnUrl, priceParams, PRODUCT_IDS,
  productParams, SUB_PLANS, type SubPlan, subFromStripe, subscriptionCheckoutParams,
} from "../_shared/premium.ts";
import { type PremiumInfo, premiumInfo, saveAppleSub, saveStripeSub } from "../_shared/premium_store.ts";
import { type AllSettings, buildEntitlements, loadSettings } from "../_shared/lifetime_store.ts";
import { APPLE_BUNDLE_ID, appleEnvironment, isAppleTxId } from "../_shared/apple.ts";
import { verifyAppleJws } from "../_shared/apple_jws.ts";
import { normalizePlatform, type Platform } from "../_shared/plans.ts";
import { stripe, stripeError, type StripeResult } from "../_shared/stripe.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
type Json = (b: unknown, s?: number) => Response;
type User = { id: string; email?: string; created_at?: string };

export const isPremiumPlan = (v: unknown): v is PremiumPlan => PREMIUM_PLANS.includes(v as PremiumPlan);

/** Premium-toestand van een account (platform web tenzij anders), met de instellingen. */
export async function premiumState(db: Db, user: User, platform: Platform = "web", settings?: AllSettings) {
  const [s, plan, info] = await Promise.all([
    settings ? Promise.resolve(settings) : loadSettings(db),
    db.from("account_plans").select("plan,source,premium_until,max_streams,max_devices").eq("user_id", user.id.toLowerCase()).maybeSingle(),
    premiumInfo(db, user.id),
  ]);
  if (plan.error) throw new Error(`account_plans: ${plan.error.code ?? "fout"}`);
  const row = effectivePlanRow(plan.data ?? null);
  const view = premiumView({ settings: s.premium, userId: user.id, createdAt: user.created_at, platform, planRow: row, ...info });
  return { s, row, info: info as PremiumInfo, view };
}

/** Stripe-abonnement ophalen en vastleggen (vangnet naast de webhook). */
export async function syncStripeSub(db: Db, key: string, s: AllSettings, subId: string, forUser?: string | null) {
  const r = await stripe(key, "GET", `subscriptions/${subId}`, [], { timeoutMs: 8000 });
  if (!r.ok) return `stripe_${r.status}`;
  const sub = subFromStripe(r.body, s.premium);
  if (!sub) return "not_ours";
  const saved = await saveStripeSub(db, s.premium, sub, forUser);
  return saved.ok ? `saved_${saved.mirror}` : saved.error;
}

/** checkout met `plan` (ingelogd of als gast). Geeft null als dit geen Premium-checkout is (dan de Lifetime-stroom). */
export async function premiumCheckout(db: Db, cfg: BillingConfig, body: Record<string, unknown>, user: User | null, json: Json,
  claimToken: () => string): Promise<Response> {
  const plan = body.plan as PremiumPlan;
  const lang = normalizeLang(body.lang);
  const now = Date.now(), waiverAt = new Date(now).toISOString();
  const s = await loadSettings(db);
  const mode = cfg.mode!;
  const priceId = s.premium.stripe_prices[mode]?.[plan];
  if (!user) {
    // gast: alleen als de groep web publiek meedoet; een abonnement krijgt de proef (er is nog geen account)
    const v = premiumView({ settings: s.premium, createdAt: new Date(now).toISOString(), platform: "web", planRow: null, subscription: null, trialUsed: false, hadSubscription: false });
    if (!v.enabled) return json({ error: "premium_off" }, 409);
    if (!priceId) return json({ error: "premium_not_configured" }, 503);
    const token = claimToken();
    const params = plan === "lifetime"
      ? lifetime49CheckoutParams({ priceId, lang, waiverAt, automaticTax: cfg.automaticTax, claimToken: token })
      : subscriptionCheckoutParams({ plan, priceId, lang, waiverAt, automaticTax: cfg.automaticTax, trialDays: s.premium.trial_days, claimToken: token });
    return await createSession(cfg, params, `bingr-premium-guest-${token}`, json);
  }
  const st = await premiumState(db, user, "web", s);
  if (!st.view.enabled) return json({ error: "premium_off" }, 409);
  if (lifetimeSource(st.row)) return json({ error: "already_lifetime", source: st.view.source }, 409);
  if (plan === "lifetime") {
    if (body.code !== undefined && body.code !== null && body.code !== "") return json({ error: "code_invalid", reason: "not_for_plan" }, 400);
    if (!priceId) return json({ error: "premium_not_configured" }, 503);
    const params = lifetime49CheckoutParams({ priceId, lang, waiverAt, automaticTax: cfg.automaticTax, userId: user.id.toLowerCase(), email: user.email ?? null });
    return await createSession(cfg, params, premiumIdempotencyKey(user.id, plan, lang, false, now), json);
  }
  if (st.view.active) return json({ error: "already_premium", manage: st.view.manage }, 409);
  if (!priceId) return json({ error: "premium_not_configured" }, 503);
  const trial = st.view.trial_eligible ? s.premium.trial_days : 0;
  const params = subscriptionCheckoutParams({
    plan: plan as SubPlan, priceId, lang, waiverAt, automaticTax: cfg.automaticTax, trialDays: trial, userId: user.id.toLowerCase(),
    email: user.email ?? null, customer: st.info.customer,
  });
  return await createSession(cfg, params, premiumIdempotencyKey(user.id, plan, lang, trial > 0, now), json);
}
async function createSession(cfg: BillingConfig, params: [string, string][], idem: string, json: Json): Promise<Response> {
  const r = await stripe(cfg.secretKey, "POST", "checkout/sessions", params, { idempotencyKey: idem });
  const url = r.body?.url;
  if (!r.ok || typeof url !== "string" || !url.startsWith("https://checkout.stripe.com/")) {
    console.error("billing premium checkout stripe", stripeError(r));
    return json({ error: "stripe_error" }, 502);
  }
  console.log("billing premium checkout: sessie aangemaakt", cfg.mode);
  return json({ url });
}

/** Customer Portal (opzeggen, betaalmethode, facturen). */
export async function portal(db: Db, cfg: BillingConfig, body: Record<string, unknown>, user: User, json: Json): Promise<Response> {
  const [info, s] = await Promise.all([premiumInfo(db, user.id), loadSettings(db)]);
  if (!info.customer) return json({ error: "no_customer" }, 404);
  const conf = s.premium.stripe_portal[cfg.mode!] ?? null;
  const r = await stripe(cfg.secretKey, "POST", "billing_portal/sessions",
    portalParams(info.customer, portalReturnUrl(body.return_url), conf, normalizeLang(body.lang)));
  const url = r.body?.url;
  if (!r.ok || typeof url !== "string" || !url.startsWith("https://billing.stripe.com/")) {
    console.error("billing portal stripe", stripeError(r));
    return json({ error: r.status === 400 && !conf ? "premium_not_configured" : "stripe_error" }, r.status === 400 && !conf ? 503 : 502);
  }
  return json({ url });
}

/** Stripe-abonnementen van dit account opnieuw ophalen en de entitlements geven. */
export async function refresh(db: Db, cfg: BillingConfig, body: Record<string, unknown>, user: User, json: Json): Promise<Response> {
  const uid = user.id.toLowerCase();
  const s = await loadSettings(db);
  let synced = 0;
  if (cfg.secretKey) {
    const { data } = await db.from("premium_subscriptions").select("stripe_customer_id").eq("user_id", uid).eq("provider", "stripe").not("stripe_customer_id", "is", null).limit(5);
    const customers = [...new Set(((data ?? []) as { stripe_customer_id: string }[]).map((r) => r.stripe_customer_id))];
    for (const c of customers) {
      const r = await stripe(cfg.secretKey, "GET", "subscriptions", [["customer", c], ["status", "all"], ["limit", "10"]], { timeoutMs: 8000 });
      if (!r.ok) { console.error("billing refresh stripe", stripeError(r)); continue; }
      for (const o of (r.body?.data ?? []) as Record<string, unknown>[]) {
        const sub = subFromStripe(o, s.premium);
        if (sub && (await saveStripeSub(db, s.premium, sub, uid)).ok) synced++;
      }
    }
  }
  const ent = await buildEntitlements(db, uid, user.created_at, normalizePlatform(body.platform) ?? "web", s);
  return json({ synced, premium: ent.premium, entitlements: ent });
}

/**
 * apple_verify voor de drie abonnementen. Geeft null als de transactie geen abonnement is (dan de Lifetime-stroom van
 * build 167). De JWS is al gecontroleerd (payload).
 */
// deno-lint-ignore no-explicit-any
export async function appleSubscription(db: Db, payload: Record<string, any>, body: Record<string, unknown>, user: User, json: Json): Promise<Response | null> {
  const k = appleProduct(payload);
  if (k.kind !== "subscription") return null;
  if (payload.bundleId !== APPLE_BUNDLE_ID) return json({ error: "bad_transaction", reason: "wrong_app" }, 400);
  const orig = payload.originalTransactionId ?? payload.transactionId;
  if (!isAppleTxId(payload.transactionId) || !isAppleTxId(orig)) return json({ error: "bad_transaction", reason: "bad_transaction" }, 400);
  let willRenew = true, graceUntil: string | null = null;
  if (typeof body.signed_renewal_info === "string" && body.signed_renewal_info) {
    const rv = await verifyAppleJws(body.signed_renewal_info);
    if (rv.ok && (rv.payload.originalTransactionId ?? orig) === orig) {
      willRenew = Number(rv.payload.autoRenewStatus) === 1;
      const g = Number(rv.payload.gracePeriodExpiresDate);
      if (Number.isFinite(g) && g > 0) graceUntil = new Date(g).toISOString();
    }
  }
  const s = await loadSettings(db);
  const status = k.status === "active" && !willRenew ? "canceled" : k.status;
  const r = await saveAppleSub(db, s.premium, {
    originalTransactionId: String(orig), productId: String(payload.productId), plan: k.plan, status, expires_at: k.expires_at, trial: k.trial,
    will_renew: willRenew, grace_until: graceUntil, environment: appleEnvironment(payload.environment),
  }, user.id);
  if (!r.ok) { console.log("billing apple_verify premium", r.error); return json({ error: "owned_by_other_account" }, 409); }
  if (k.status === "revoked") return json({ error: "transaction_revoked" }, 409);
  console.log("billing apple_verify premium", k.plan, r.mirror, appleEnvironment(payload.environment));
  const ent = await buildEntitlements(db, user.id.toLowerCase(), user.created_at, normalizePlatform(body.platform) ?? "ios", s);
  return json({ plan: k.plan, premium: ent.premium, entitlements: ent });
}
export { APPLE_PREMIUM_PRODUCTS };

/** Beheer: Stripe-producten, -prijzen en de Customer Portal-configuratie idempotent aanmaken en de id's opslaan. */
export async function premiumSetup(db: Db, cfg: BillingConfig, body: Record<string, unknown>, json: Json): Promise<Response> {
  if (!cfg.secretKey || !cfg.mode) return json({ error: "billing_unavailable" }, 503);
  const dry = body.dry_run === true;
  const s = (await loadSettings(db)).premium;
  const key = cfg.secretKey, mode = cfg.mode;
  const created: string[] = [];
  const fail = (what: string, r: StripeResult) => {
    console.error("billing premium_setup", what, stripeError(r));
    return json({ error: "stripe_error", step: what }, 502);
  };
  const products: Record<string, string | null> = {};
  for (const kind of ["sub", "lifetime"] as const) {
    const id = PRODUCT_IDS[kind];
    const g = await stripe(key, "GET", `products/${id}`);
    if (g.ok) { products[kind] = id; continue; }
    if (g.status !== 404) return fail(`product_${kind}`, g);
    if (dry) { products[kind] = null; continue; }
    const p = await stripe(key, "POST", "products", productParams(kind), { idempotencyKey: `bingr-premium-product-${id}` });
    if (!p.ok) return fail(`product_${kind}`, p);
    products[kind] = id; created.push(`product_${kind}`);
  }
  const prices: Partial<Record<PremiumPlan, string | null>> = {};
  for (const plan of PREMIUM_PLANS) {
    const lk = lookupKey(plan, s.prices[plan]);
    const g = await stripe(key, "GET", "prices", [["lookup_keys[]", lk], ["active", "true"], ["limit", "1"]]);
    if (!g.ok) return fail(`price_${plan}`, g);
    const found = ((g.body?.data ?? []) as { id: string; unit_amount: number; product: string }[])
      .find((x) => x.unit_amount === s.prices[plan] && x.product === (plan === "lifetime" ? PRODUCT_IDS.lifetime : PRODUCT_IDS.sub));
    if (found) { prices[plan] = found.id; continue; }
    if (dry) { prices[plan] = null; continue; }
    const p = await stripe(key, "POST", "prices", priceParams(plan, s.prices[plan]), { idempotencyKey: `bingr-premium-${mode}-${lk}` });
    if (!p.ok || typeof p.body?.id !== "string") return fail(`price_${plan}`, p);
    prices[plan] = p.body.id as string; created.push(`price_${plan}`);
  }
  let portalId = s.stripe_portal[mode];
  if (portalId) {
    const g = await stripe(key, "GET", `billing_portal/configurations/${portalId}`);
    if (!g.ok) portalId = null;
  }
  if (!portalId && !dry) {
    const p = await stripe(key, "POST", "billing_portal/configurations", portalConfigParams(), { idempotencyKey: `bingr-premium-portal-${mode}-${Date.now() >> 26}` });
    if (!p.ok || typeof p.body?.id !== "string") return fail("portal", p);
    portalId = p.body.id as string; created.push("portal");
  }
  if (!dry) {
    const patch = { stripe_prices: { [mode]: prices }, stripe_portal: { [mode]: portalId } };
    const { error } = await db.rpc("bingr_admin_premium_settings", { p_premium: patch });
    if (error) { console.error("billing premium_setup settings", error.code ?? "fout"); return json({ error: "settings_failed" }, 500); }
  }
  console.log("billing premium_setup", mode, dry ? "dry_run" : `aangemaakt ${created.length}`);
  return json({ ok: true, dry_run: dry, mode, products, prices, portal: portalId ?? null, created });
}
export { SUB_PLANS };
