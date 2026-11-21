// Build 181: Bingr Premium (abonnementen naast Lifetime). Contract in docs/ACCOUNT.md, "Build 181: Bingr Premium", met de
// vaste testgevallen in docs/build181_cases.json (getest in premium_test.ts). Pure logica zonder database of netwerk,
// gedeeld door device-auth (entitlements, stream_start), billing (config, checkout, portal, refresh, apple_verify, setup),
// stripe-webhook en apple-notify.
//   app_settings.premium = {enabled, new_from_web, new_from_apple, existing_from, trial_days, show_prices_web, grace_days,
//                           prices, stripe_prices, stripe_portal, test_users}
// Zolang enabled false is (standaard) en het account geen testaccount is, verandert er niets aan access en de bestaande
// velden; alleen het nieuwe veld `premium` komt erbij (oudere apps negeren het).
// Nooit loggen: e-mailadressen, account-id's, Stripe-klanten of transactie-id's van klanten.
import { paidGroup, type PaidGroup } from "./lifetime.ts";
import { type Platform } from "./plans.ts";

export type SubPlan = "month" | "half" | "year";
export type PremiumPlan = SubPlan | "lifetime";
export const SUB_PLANS: SubPlan[] = ["month", "half", "year"];
export const PREMIUM_PLANS: PremiumPlan[] = ["month", "half", "year", "lifetime"];
const APPLE = "nl.lrvdlinden.bingr.";
/** Apple-product-id's van Premium (StoreKit 2). De oude Lifetime (€ 4,99) blijft geldig voor herstellen. */
export const APPLE_PREMIUM_PRODUCTS: Record<PremiumPlan, string> = {
  month: `bingr.premium.monthly`, half: `bingr.premium.sixmonths`, year: `bingr.premium.yearly`, lifetime: `bingr.lifetime4999`,
};
export const APPLE_LIFETIME_LEGACY = `${APPLE}lifetime`;
export const DEFAULT_PRICES: Record<PremiumPlan, number> = { month: 499, half: 1999, year: 2999, lifetime: 4999 };
export const DEFAULT_EXISTING_FROM = "2026-12-01T00:01:00+01:00";
export const PREMIUM_CURRENCY = "eur";
const DAY = 86_400_000, HOUR = 3_600_000;

export type StripeMode = "test" | "live";
export type PremiumSettings = {
  enabled: boolean; new_from_web: string | null; new_from_apple: string | null; existing_from: string | null;
  trial_days: number; show_prices_web: boolean; grace_days: number; prices: Record<PremiumPlan, number>;
  stripe_prices: Record<StripeMode, Partial<Record<PremiumPlan, string>>>; stripe_portal: Record<StripeMode, string | null>;
  test_users: string[];
};
export const DEFAULT_PREMIUM: PremiumSettings = {
  enabled: false, new_from_web: null, new_from_apple: null, existing_from: DEFAULT_EXISTING_FROM, trial_days: 3,
  show_prices_web: false, grace_days: 3, prices: { ...DEFAULT_PRICES }, stripe_prices: { test: {}, live: {} },
  stripe_portal: { test: null, live: null }, test_users: [],
};

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {});
const iso = (v: unknown): string | null => {
  if (typeof v !== "string" || !v.trim() || v.length > 40) return null;
  return Number.isFinite(Date.parse(v)) ? v.trim() : null;
};
const intIn = (v: unknown, lo: number, hi: number, d: number) => (Number.isInteger(v) && (v as number) >= lo && (v as number) <= hi ? v as number : d);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ms = (v: string | null | undefined) => (v ? Date.parse(v) : NaN);

/** app_settings.premium lezen (de database controleert bij het schrijven); ontbrekend of ongeldig = standaard (uit). */
export function normalizePremium(v: unknown): PremiumSettings {
  const o = obj(v), p = obj(o.prices), sp = obj(o.stripe_prices), portal = obj(o.stripe_portal);
  const prices = {} as Record<PremiumPlan, number>;
  for (const k of PREMIUM_PLANS) prices[k] = intIn(p[k], 99, 99999, DEFAULT_PRICES[k]);
  const sprices = (m: unknown) => {
    const r: Partial<Record<PremiumPlan, string>> = {};
    for (const k of PREMIUM_PLANS) { const x = obj(m)[k]; if (typeof x === "string" && /^price_[A-Za-z0-9]+$/.test(x)) r[k] = x; }
    return r;
  };
  const bpc = (x: unknown) => (typeof x === "string" && /^bpc_[A-Za-z0-9]+$/.test(x) ? x : null);
  return {
    enabled: o.enabled === true,
    new_from_web: iso(o.new_from_web),
    new_from_apple: iso(o.new_from_apple),
    existing_from: "existing_from" in o ? iso(o.existing_from) : DEFAULT_EXISTING_FROM,
    trial_days: intIn(o.trial_days, 0, 14, DEFAULT_PREMIUM.trial_days),
    show_prices_web: o.show_prices_web === true,
    grace_days: intIn(o.grace_days, 0, 16, DEFAULT_PREMIUM.grace_days),
    prices,
    stripe_prices: { test: sprices(sp.test), live: sprices(sp.live) },
    stripe_portal: { test: bpc(portal.test), live: bpc(portal.live) },
    test_users: Array.isArray(o.test_users) ? o.test_users.filter((x): x is string => typeof x === "string" && UUID.test(x)).map((x) => x.toLowerCase()).slice(0, 10) : [],
  };
}

export const isTestUser = (s: PremiumSettings, userId: string | null | undefined) => !!userId && s.test_users.includes(userId.toLowerCase());
export const newFromOf = (s: PremiumSettings, g: PaidGroup) => (g === "apple" ? s.new_from_apple : s.new_from_web);
/** Doet deze platformgroep nu mee? Hoofdschakelaar aan, datum gezet en voorbij; of een testaccount. */
export function groupOn(s: PremiumSettings, g: PaidGroup, now = Date.now(), test = false): boolean {
  if (test) return true;
  const t = ms(s.enabled ? newFromOf(s, g) : null);
  return Number.isFinite(t) && now >= t;
}

// ---------------- entitlement `premium` ----------------
export type SubStatus = "incomplete" | "trialing" | "active" | "past_due" | "grace" | "canceled" | "expired" | "revoked";
export type SubRow = {
  provider: "stripe" | "apple"; plan: SubPlan; status: SubStatus; expires_at: string | null; trial_until: string | null;
  will_renew: boolean; access_until: string | null;
};
export type PlanRowP = { plan?: unknown; source?: unknown; premium_until?: unknown; max_streams?: unknown; max_devices?: unknown } | null | undefined;
export type PremiumSource = "legacy" | "admin" | "lifetime" | "stripe" | "apple";
export type PremiumView = {
  enabled: boolean; active: boolean; source: PremiumSource | null; plan: PremiumPlan | null; status: SubStatus | "lifetime" | null;
  expires_at: string | null; trial_until: string | null; will_renew: boolean; required: boolean; trial_eligible: boolean;
  legacy_offer: boolean; manage: "apple" | "stripe" | null; test: boolean;
  prices: Record<PremiumPlan, number> & { currency: string }; products: Record<PremiumPlan, string>;
};
export type PremiumInput = {
  settings: PremiumSettings; now?: number; userId?: string | null; createdAt: string | null | undefined; platform: Platform | null;
  planRow: PlanRowP; subscription: SubRow | null; trialUsed: boolean; hadSubscription: boolean; test?: boolean;
};

/** Lifetime (geen abonnement): de bron volgens account_plans.source, anders null. */
export function lifetimeSource(row: PlanRowP): "legacy" | "admin" | "lifetime" | null {
  if (row?.plan !== "lifetime" || row.source === "subscription") return null;
  return row.source === "legacy" ? "legacy" : row.source === "purchase" ? "lifetime" : "admin";
}
/**
 * Het niveau dat echt geldt: een gespiegeld abonnement (source subscription) met premium_until voorbij telt als Gratis,
 * ook als bingr_premium_sweep nog niet gedraaid heeft. Lifetime (legacy/admin/purchase) blijft altijd Lifetime.
 */
export function effectivePlanRow<T extends PlanRowP>(row: T, now = Date.now()): T {
  if (!row || row.source !== "subscription" || row.plan !== "lifetime") return row;
  const t = ms(typeof row.premium_until === "string" ? row.premium_until : null);
  return Number.isFinite(t) && t > now ? row : { ...row, plan: "free" } as T;
}

export function premiumView(i: PremiumInput): PremiumView & { access: "full" | "activate" | null } {
  const s = i.settings, now = i.now ?? Date.now();
  const test = i.test ?? isTestUser(s, i.userId);
  const g = paidGroup(i.platform);
  const on = groupOn(s, g, now, test);
  const lt = lifetimeSource(i.planRow);
  const sub = i.subscription;
  const subActive = !!sub && Number.isFinite(ms(sub.access_until)) && ms(sub.access_until) > now;
  const active = !!lt || subActive;
  const nf = ms(newFromOf(s, g)), created = ms(i.createdAt ?? null);
  const isNew = test || (on && Number.isFinite(nf) && Number.isFinite(created) && created >= nf);
  const ex = ms(s.existing_from);
  const afterExisting = Number.isFinite(ex) && now >= ex;
  const required = on && (isNew || afterExisting);
  const view: PremiumView = {
    enabled: on, active,
    source: lt ?? sub?.provider ?? null,
    plan: lt ? "lifetime" : sub?.plan ?? null,
    status: lt ? "lifetime" : sub?.status ?? null,
    expires_at: lt ? null : sub?.expires_at ?? null,
    trial_until: !lt && subActive && sub!.status === "trialing" ? sub!.trial_until : null,
    will_renew: !lt && subActive ? !!sub!.will_renew : false,
    required,
    trial_eligible: on && s.trial_days > 0 && isNew && !i.trialUsed && !i.hadSubscription && !active,
    legacy_offer: on && !active && !isNew && Number.isFinite(ex) && now < ex && g !== "apple",
    manage: lt ? null : sub?.provider ?? null,
    test,
    prices: { ...s.prices, currency: PREMIUM_CURRENCY },
    products: { ...APPLE_PREMIUM_PRODUCTS },
  };
  return { ...view, access: on ? (required && !active ? "activate" : "full") : null };
}

// ---------------- toegangsduur van een abonnement ----------------
/** Tot wanneer een abonnement toegang geeft (zie docs/ACCOUNT.md §7); null = geen toegang. */
export function accessUntil(sub: { status: SubStatus; expires_at: string | null; trial_until?: string | null; grace_until?: string | null },
  graceDays: number): string | null {
  const exp = ms(sub.expires_at);
  const at = (t: number) => (Number.isFinite(t) ? new Date(t).toISOString() : null);
  switch (sub.status) {
    case "trialing": return at(Number.isFinite(ms(sub.trial_until ?? null)) ? ms(sub.trial_until ?? null) : exp);
    case "active": case "canceled": return at(exp + HOUR);
    case "past_due": return at(exp + graceDays * DAY);
    case "grace": {
      const gu = ms(sub.grace_until ?? null);
      return at(Number.isFinite(gu) ? gu : exp + graceDays * DAY);
    }
    default: return null;
  }
}

// ---------------- Stripe ----------------
// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
const secIso = (v: unknown) => (Number.isInteger(v) && (v as number) > 0 ? new Date((v as number) * 1000).toISOString() : null);
const sid = (v: unknown, prefix: string) => {
  const id = typeof v === "string" ? v : (v as Obj | null)?.id;
  return typeof id === "string" && id.length <= 255 && id.startsWith(prefix) && /^[A-Za-z0-9_]+$/.test(id) ? id : null;
};
/** Status van een Stripe-abonnement (object "subscription") in onze termen. */
export function stripeSubStatus(sub: Obj): { status: SubStatus; will_renew: boolean; expires_at: string | null; trial_until: string | null } {
  const st = String(sub?.status ?? "");
  const end = secIso(sub?.items?.data?.[0]?.current_period_end) ?? secIso(sub?.current_period_end);
  const cancel = sub?.cancel_at_period_end === true;
  let status: SubStatus;
  if (st === "trialing") status = "trialing";
  else if (st === "active") status = cancel ? "canceled" : "active";
  else if (st === "past_due") status = "past_due";
  else if (st === "incomplete") status = "incomplete";
  else status = "expired"; // canceled, unpaid, incomplete_expired, paused en onbekend
  const live = status === "trialing" || status === "active" || status === "past_due";
  return {
    status, will_renew: live && !cancel, expires_at: end,
    trial_until: status === "trialing" ? (secIso(sub?.trial_end) ?? end) : null,
  };
}
/** Plan van een Stripe-abonnement: metadata.plan, anders de price-id volgens de instellingen, anders de looptijd. */
export function stripeSubPlan(sub: Obj, s: PremiumSettings): SubPlan | null {
  const m = sub?.metadata?.plan;
  if (SUB_PLANS.includes(m)) return m;
  const price = sub?.items?.data?.[0]?.price;
  const pid = sid(price, "price_");
  for (const mode of ["live", "test"] as StripeMode[]) for (const k of SUB_PLANS) if (pid && s.stripe_prices[mode][k] === pid) return k;
  const rec = price?.recurring;
  if (rec?.interval === "year") return "year";
  if (rec?.interval === "month") return rec.interval_count === 6 ? "half" : rec.interval_count === 1 ? "month" : null;
  return null;
}
export type StripeSub = {
  stripe_subscription_id: string; stripe_customer_id: string | null; stripe_price_id: string | null; plan: SubPlan;
  status: SubStatus; will_renew: boolean; expires_at: string | null; trial_until: string | null; started_at: string | null;
  canceled_at: string | null; mode: StripeMode; userId: string | null; claimToken: string | null;
};
export function subFromStripe(sub: Obj, s: PremiumSettings): StripeSub | null {
  if (!sub || sub.object !== "subscription") return null;
  const id = sid(sub.id, "sub_");
  const plan = stripeSubPlan(sub, s);
  if (!id || !plan) return null;
  const st = stripeSubStatus(sub);
  const uid = sub.metadata?.user_id;
  const tok = sub.metadata?.claim_token;
  return {
    stripe_subscription_id: id, stripe_customer_id: sid(sub.customer, "cus_"), stripe_price_id: sid(sub.items?.data?.[0]?.price, "price_"),
    plan, ...st, started_at: secIso(sub.start_date) ?? secIso(sub.created), canceled_at: secIso(sub.canceled_at),
    mode: sub.livemode === true ? "live" : "test",
    userId: typeof uid === "string" && UUID.test(uid) ? uid.toLowerCase() : null,
    claimToken: typeof tok === "string" && /^[A-Za-z0-9_-]{43}$/.test(tok) ? tok : null,
  };
}
export type PremiumPayment = {
  id: string; subscriptionId: string | null; amount: number; currency: string; taxAmount: number | null; billingReason: string | null;
  paidAt: string; mode: StripeMode; paymentIntent: string | null;
};
/** Betaalde factuur van een abonnement (invoice.paid). Een factuur van 0 (proef) telt niet: null. */
export function paymentFromInvoice(inv: Obj, nowIso = new Date().toISOString()): PremiumPayment | null {
  if (!inv || inv.object !== "invoice") return null;
  const id = sid(inv.id, "in_");
  const amount = Number.isInteger(inv.amount_paid) ? inv.amount_paid : 0;
  const subId = sid(inv.parent?.subscription_details?.subscription, "sub_") ?? sid(inv.subscription, "sub_");
  if (!id || amount <= 0 || !subId) return null;
  const taxes = Array.isArray(inv.total_taxes) ? inv.total_taxes.reduce((a: number, t: Obj) => a + (Number.isInteger(t?.amount) ? t.amount : 0), 0) : null;
  return {
    id, subscriptionId: subId, amount, currency: String(inv.currency || PREMIUM_CURRENCY).toLowerCase(),
    taxAmount: Number.isInteger(inv.tax) ? inv.tax : taxes, billingReason: typeof inv.billing_reason === "string" ? inv.billing_reason.slice(0, 40) : null,
    paidAt: secIso(inv.status_transitions?.paid_at) ?? nowIso, mode: inv.livemode === true ? "live" : "test",
    paymentIntent: sid(inv.payment_intent, "pi_"),
  };
}
export type PremiumDecision =
  | { kind: "sub_checkout"; subscriptionId: string; sessionId: string; userId: string | null; claimToken: string | null; email: string | null; lang: "nl" | "en" }
  | { kind: "sub_update"; sub: Obj }
  | { kind: "invoice_paid"; invoice: Obj }
  | { kind: "invoice_failed"; subscriptionId: string };
export const PREMIUM_WEBHOOK_EVENTS = [
  "customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted", "invoice.paid", "invoice.payment_failed",
] as const;
/** Events van Premium-abonnementen; null = geen Premium-event (dan de Lifetime-logica van build 133/167). */
export function decidePremium(event: Obj | null | undefined): PremiumDecision | null {
  const o = event?.data?.object;
  if (!event || !o) return null;
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      if (o.object !== "checkout.session" || o.mode !== "subscription") return null;
      const subId = sid(o.subscription, "sub_"), sess = sid(o.id, "cs_");
      if (!subId || !sess) return null;
      const uid = o.client_reference_id ?? o.metadata?.user_id;
      const tok = o.metadata?.claim_token;
      const email = typeof o.customer_details?.email === "string" && o.customer_details.email.includes("@") ? o.customer_details.email : null;
      return {
        kind: "sub_checkout", subscriptionId: subId, sessionId: sess, userId: typeof uid === "string" && UUID.test(uid) ? uid.toLowerCase() : null,
        claimToken: typeof tok === "string" && /^[A-Za-z0-9_-]{43}$/.test(tok) ? tok : null, email,
        lang: String(o.locale ?? "").startsWith("en") ? "en" : "nl",
      };
    }
    case "customer.subscription.created": case "customer.subscription.updated": case "customer.subscription.deleted":
      return o.object === "subscription" ? { kind: "sub_update", sub: o } : null;
    case "invoice.paid": return o.object === "invoice" ? { kind: "invoice_paid", invoice: o } : null;
    case "invoice.payment_failed": {
      const subId = sid(o.parent?.subscription_details?.subscription, "sub_") ?? sid(o.subscription, "sub_");
      return o.object === "invoice" && subId ? { kind: "invoice_failed", subscriptionId: subId } : null;
    }
    default: return null;
  }
}

// ---------------- Stripe: Checkout, Customer Portal en producten ----------------
export const PREMIUM_SUCCESS_URL = "https://bingr.online/upgrade/?status=success&session_id={CHECKOUT_SESSION_ID}";
export const PREMIUM_CANCEL_URL = "https://bingr.online/upgrade/?status=cancel";
export const PREMIUM_GUEST_SUCCESS_URL = (t: string) => `https://bingr.online/upgrade/klaar/?claim=${encodeURIComponent(t)}&session_id={CHECKOUT_SESSION_ID}`;
export const PLAN_NAMES: Record<PremiumPlan, { nl: string; en: string }> = {
  month: { nl: "Bingr Premium maandelijks", en: "Bingr Premium monthly" },
  half: { nl: "Bingr Premium halfjaarlijks", en: "Bingr Premium every 6 months" },
  year: { nl: "Bingr Premium jaarlijks", en: "Bingr Premium yearly" },
  lifetime: { nl: "Bingr Premium Lifetime", en: "Bingr Premium Lifetime" },
};
export type SubCheckoutInput = {
  plan: SubPlan; priceId: string; lang: "nl" | "en"; waiverAt: string; automaticTax: boolean; trialDays: number;
  userId?: string | null; email?: string | null; customer?: string | null; claimToken?: string | null;
};
/** POST /v1/checkout/sessions voor een abonnement. Proef alleen als trialDays > 0 (de aanroeper controleert trial_eligible). */
export function subscriptionCheckoutParams(i: SubCheckoutInput): [string, string][] {
  const nl = i.lang === "nl";
  const p: [string, string][] = [
    ["mode", "subscription"],
    ["line_items[0][price]", i.priceId], ["line_items[0][quantity]", "1"],
    ["metadata[plan]", i.plan], ["metadata[withdrawal_waiver_at]", i.waiverAt],
    ["subscription_data[metadata][plan]", i.plan],
    ["payment_method_collection", "always"],
    ["locale", i.lang], ["cancel_url", PREMIUM_CANCEL_URL],
    ["custom_text[submit][message]", nl
      ? "Premium staat direct aan. Je hebt ingestemd met directe levering en ziet daarmee af van je herroepingsrecht. Opzeggen kan altijd, tot het einde van de periode. Verkoper: PixelForges (KvK 70031576)."
      : "Premium is active right away. You agreed to immediate delivery and thereby waive your right of withdrawal. Cancel any time, until the end of the period. Seller: PixelForges (Chamber of Commerce 70031576)."],
  ];
  if (i.userId) {
    p.push(["client_reference_id", i.userId], ["metadata[user_id]", i.userId], ["subscription_data[metadata][user_id]", i.userId]);
    p.push(["success_url", PREMIUM_SUCCESS_URL]);
  } else if (i.claimToken) {
    p.push(["metadata[guest]", "1"], ["metadata[claim_token]", i.claimToken], ["subscription_data[metadata][guest]", "1"],
      ["subscription_data[metadata][claim_token]", i.claimToken], ["success_url", PREMIUM_GUEST_SUCCESS_URL(i.claimToken)]);
  }
  if (i.customer) p.push(["customer", i.customer]);
  else if (i.email) p.push(["customer_email", i.email]);
  if (i.trialDays > 0) {
    p.push(["subscription_data[trial_period_days]", String(i.trialDays)],
      ["subscription_data[trial_settings][end_behavior][missing_payment_method]", "cancel"]);
  }
  if (i.automaticTax) p.push(["automatic_tax[enabled]", "true"]);
  return p;
}
export type LifetimeCheckoutInput = {
  priceId: string; lang: "nl" | "en"; waiverAt: string; automaticTax: boolean; userId?: string | null; email?: string | null; claimToken?: string | null;
};
/** POST /v1/checkout/sessions voor Lifetime € 49,99 (eenmalig, metadata.plan = lifetime49). */
export function lifetime49CheckoutParams(i: LifetimeCheckoutInput): [string, string][] {
  const nl = i.lang === "nl";
  const p: [string, string][] = [
    ["mode", "payment"], ["line_items[0][price]", i.priceId], ["line_items[0][quantity]", "1"],
    ["metadata[plan]", "lifetime49"], ["metadata[withdrawal_waiver_at]", i.waiverAt],
    ["payment_intent_data[description]", PLAN_NAMES.lifetime.nl], ["payment_intent_data[statement_descriptor_suffix]", "BINGR"],
    ["payment_intent_data[metadata][plan]", "lifetime49"],
    ["invoice_creation[enabled]", "true"], ["invoice_creation[invoice_data][description]", PLAN_NAMES.lifetime[i.lang]],
    ["locale", i.lang], ["cancel_url", PREMIUM_CANCEL_URL],
    ["custom_text[submit][message]", nl
      ? "Lifetime staat direct na betaling aan. Je hebt ingestemd met directe levering en ziet daarmee af van je herroepingsrecht. Verkoper: PixelForges (KvK 70031576)."
      : "Lifetime is active right after payment. You agreed to immediate delivery and thereby waive your right of withdrawal. Seller: PixelForges (Chamber of Commerce 70031576)."],
  ];
  if (i.userId) {
    p.push(["client_reference_id", i.userId], ["metadata[user_id]", i.userId], ["payment_intent_data[metadata][user_id]", i.userId],
      ["success_url", PREMIUM_SUCCESS_URL]);
  } else if (i.claimToken) {
    p.push(["metadata[guest]", "1"], ["metadata[claim_token]", i.claimToken], ["payment_intent_data[metadata][guest]", "1"],
      ["customer_creation", "always"], ["success_url", PREMIUM_GUEST_SUCCESS_URL(i.claimToken)]);
  }
  if (i.email) p.push(["customer_email", i.email]);
  if (i.automaticTax) p.push(["automatic_tax[enabled]", "true"]);
  return p;
}
export const premiumIdempotencyKey = (who: string, plan: PremiumPlan, lang: string, trial: boolean, nowMs: number) =>
  `bingr-premium-${who.toLowerCase().slice(0, 64)}-${plan}-${lang}-${trial ? "t" : "n"}-${Math.floor(nowMs / 60_000)}`;
/** return_url van de Customer Portal: alleen https://bingr.online/…, anders /upgrade/. */
export function portalReturnUrl(v: unknown): string {
  if (typeof v === "string" && v.length <= 300) {
    try { const u = new URL(v); if (u.protocol === "https:" && (u.hostname === "bingr.online" || u.hostname === "www.bingr.online")) return u.toString(); } catch { /* standaard */ }
  }
  return "https://bingr.online/upgrade/";
}
export function portalParams(customer: string, returnUrl: string, configuration: string | null, lang: "nl" | "en"): [string, string][] {
  const p: [string, string][] = [["customer", customer], ["return_url", returnUrl], ["locale", lang]];
  if (configuration) p.push(["configuration", configuration]);
  return p;
}
/** lookup_key van een prijs (met het bedrag erin: een andere prijs = een nieuwe Stripe-prijs). */
export const lookupKey = (plan: PremiumPlan, cents: number) => `bingr_premium_${plan}_eur_${cents}`;
export const PRODUCT_IDS = { sub: "bingr_premium", lifetime: "bingr_premium_lifetime" } as const;
export function productParams(kind: "sub" | "lifetime"): [string, string][] {
  return kind === "sub"
    ? [["id", PRODUCT_IDS.sub], ["name", "Bingr Premium"], ["description", "Bingr Premium: alle functies op al je apparaten."], ["tax_code", "txcd_10000000"], ["metadata[bingr]", "premium"]]
    : [["id", PRODUCT_IDS.lifetime], ["name", "Bingr Premium Lifetime"], ["description", "Eenmalig, voor altijd alle functies op al je apparaten."], ["tax_code", "txcd_10000000"], ["metadata[bingr]", "premium"]];
}
export function priceParams(plan: PremiumPlan, cents: number): [string, string][] {
  const p: [string, string][] = [
    ["product", plan === "lifetime" ? PRODUCT_IDS.lifetime : PRODUCT_IDS.sub], ["currency", PREMIUM_CURRENCY], ["unit_amount", String(cents)],
    ["tax_behavior", "inclusive"], ["lookup_key", lookupKey(plan, cents)], ["nickname", PLAN_NAMES[plan].nl], ["metadata[plan]", plan],
  ];
  if (plan === "month") p.push(["recurring[interval]", "month"], ["recurring[interval_count]", "1"]);
  if (plan === "half") p.push(["recurring[interval]", "month"], ["recurring[interval_count]", "6"]);
  if (plan === "year") p.push(["recurring[interval]", "year"], ["recurring[interval_count]", "1"]);
  return p;
}
/** Customer Portal: opzeggen aan het eind van de periode, betaalmethode en facturen; geen plan wisselen. */
export function portalConfigParams(): [string, string][] {
  return [
    ["business_profile[headline]", "Bingr Premium"],
    ["business_profile[privacy_policy_url]", "https://bingr.online/privacy/"],
    ["business_profile[terms_of_service_url]", "https://bingr.online/voorwaarden/"],
    ["features[subscription_cancel][enabled]", "true"], ["features[subscription_cancel][mode]", "at_period_end"],
    ["features[subscription_cancel][cancellation_reason][enabled]", "true"],
    ["features[subscription_cancel][cancellation_reason][options][]", "too_expensive"],
    ["features[subscription_cancel][cancellation_reason][options][]", "unused"],
    ["features[subscription_cancel][cancellation_reason][options][]", "missing_features"],
    ["features[subscription_cancel][cancellation_reason][options][]", "other"],
    ["features[payment_method_update][enabled]", "true"], ["features[invoice_history][enabled]", "true"],
    ["features[customer_update][enabled]", "false"], ["features[subscription_update][enabled]", "false"],
    ["metadata[bingr]", "premium"],
  ];
}
/** Zijn alle vier de price-id's er in deze modus? */
export const stripeReady = (s: PremiumSettings, mode: StripeMode | null) => !!mode && PREMIUM_PLANS.every((k) => !!s.stripe_prices[mode][k]);

// ---------------- Apple ----------------
export type AppleProductKind =
  | { kind: "subscription"; plan: SubPlan; status: SubStatus; expires_at: string | null; trial: boolean }
  | { kind: "lifetime"; plan: "lifetime" | "lifetime49" }
  | { kind: "error"; error: "wrong_product" };
const msIso = (v: unknown) => (Number.isFinite(Number(v)) && Number(v) > 0 ? new Date(Number(v)).toISOString() : null);
/** Soort product van een (gecontroleerde) StoreKit-transactie. */
// deno-lint-ignore no-explicit-any
export function appleProduct(tx: Record<string, any>): AppleProductKind {
  const pid = tx?.productId;
  if (pid === APPLE_LIFETIME_LEGACY) return { kind: "lifetime", plan: "lifetime" };
  if (pid === APPLE_PREMIUM_PRODUCTS.lifetime) return { kind: "lifetime", plan: "lifetime49" };
  const plan = SUB_PLANS.find((k) => APPLE_PREMIUM_PRODUCTS[k] === pid);
  if (!plan) return { kind: "error", error: "wrong_product" };
  const trial = tx.offerDiscountType === "FREE_TRIAL" || (Number(tx.offerType) === 1 && Number(tx.price) === 0);
  const revoked = tx.revocationDate !== undefined && tx.revocationDate !== null;
  return { kind: "subscription", plan, status: revoked ? "revoked" : trial ? "trialing" : "active", expires_at: msIso(tx.expiresDate), trial: trial && !revoked };
}
/** Wat een App Store Server Notification met een abonnement doet (status), of "ignore". */
export function appleNotifyStatus(type: string, subtype: string | null | undefined, renewal?: { autoRenewStatus?: unknown } | null):
  SubStatus | "ignore" {
  switch (type) {
    case "SUBSCRIBED": case "DID_RENEW": case "OFFER_REDEEMED": case "DID_CHANGE_RENEWAL_PREF": case "RENEWAL_EXTENDED": return "active";
    case "DID_CHANGE_RENEWAL_STATUS": return Number(renewal?.autoRenewStatus) === 0 || subtype === "AUTO_RENEW_DISABLED" ? "canceled" : "active";
    case "DID_FAIL_TO_RENEW": return subtype === "GRACE_PERIOD" ? "grace" : "past_due";
    case "GRACE_PERIOD_EXPIRED": case "EXPIRED": return "expired";
    case "REFUND": case "REVOKE": return "revoked";
    default: return "ignore";
  }
}

// ---------------- publieke billing config ----------------
export type PublicPremium = {
  enabled: boolean; web: boolean; apple: boolean; required_new: boolean; new_from: string | null; existing_from: string | null;
  existing_after: boolean; trial_days: number; show_prices_web: boolean; stripe_ready: boolean;
  prices: Record<PremiumPlan, number> & { currency: string }; products: Record<PremiumPlan, string>;
};
export function publicPremium(s: PremiumSettings, group: PaidGroup, mode: StripeMode | null, now = Date.now()): PublicPremium {
  const on = groupOn(s, group, now);
  const ex = ms(s.existing_from);
  return {
    enabled: on, web: groupOn(s, "other", now), apple: groupOn(s, "apple", now), required_new: on,
    new_from: on ? newFromOf(s, group) : null, existing_from: on ? s.existing_from : null,
    existing_after: on && Number.isFinite(ex) && now >= ex, trial_days: on ? s.trial_days : 0,
    show_prices_web: s.show_prices_web, stripe_ready: stripeReady(s, mode),
    prices: { ...s.prices, currency: PREMIUM_CURRENCY }, products: { ...APPLE_PREMIUM_PRODUCTS },
  };
}

// ---------------- apps: wat tonen (referentie voor Apple, Android en web; groep "client" van de testgevallen) ----------------
export function premiumScreen(ent: { access?: string; premium?: Partial<PremiumView> | null } | null | undefined, now = Date.now(), offline = false):
  { blocked: boolean; paywall: "legacy" | "trial" | "plans" | null; trial_badge: boolean; manage: "apple" | "stripe" | null } {
  const p = ent?.premium;
  const activate = ent?.access === "activate";
  if (!p || !p.enabled) return { blocked: activate, paywall: activate ? "legacy" : null, trial_badge: false, manage: p?.manage ?? null };
  const lapsed = offline && p.active === true && p.status !== "lifetime" && !p.will_renew && Number.isFinite(ms(p.expires_at ?? null)) && ms(p.expires_at ?? null) <= now;
  const blocked = activate || lapsed;
  return {
    blocked, paywall: blocked ? (p.trial_eligible ? "trial" : "plans") : null, trial_badge: blocked && p.trial_eligible === true,
    manage: p.manage ?? null,
  };
}
