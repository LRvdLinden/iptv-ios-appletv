// Betalen met Stripe (build 133): Lifetime eenmalig € 4,99 op bingr.online/upgrade/. Contract in docs/ACCOUNT.md,
// "Betalen (Stripe, build 133)". Pure logica zonder database of netwerk (getest in billing_test.ts), gedeeld door de
// functies billing (checkout, status, purchases) en stripe-webhook.
// Nooit loggen: sleutels, handtekeningen, e-mailadressen, namen of betaalgegevens. Alleen tellingen en Stripe-id's.
import { PRICE_CENTS, PRICE_CURRENCY, PRODUCT_NAME } from "./plans.ts";

export const SITE = "https://bingr.online";
export const SUCCESS_URL = `${SITE}/upgrade/?status=success&session_id={CHECKOUT_SESSION_ID}`;
export const CANCEL_URL = `${SITE}/upgrade/?status=cancel`;
// Verkoper (openbare bedrijfsgegevens; ook in de voorwaarden en de privacyverklaring op bingr.online)
export const SELLER = { name: "PixelForges", kvk: "70031576", vat: "NL001876986B40", city: "Apeldoorn", country: "NL", email: "support@bingr.online" };
// Tekst op het bankafschrift na de prefix (bedrijfsnaam, ingesteld in het Stripe-dashboard): "PIXELFORGES* BINGR"
export const STATEMENT_SUFFIX = "BINGR";
// Stripe-belastingcode voor elektronisch geleverde diensten (alleen met automatic_tax)
export const TAX_CODE = "txcd_10000000";
// Tolerantie van de Stripe-handtekening (seconden), zoals de officiële bibliotheken
export const SIG_TOLERANCE_S = 300;
export const WEBHOOK_EVENTS = [
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "charge.refunded",
  "charge.dispute.created",
  // omzet in het beheer: Stripe-kosten (balance transaction) komen soms pas later; dan alsnog ophalen
  "charge.updated",
] as const;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);
// Stripe-id's (cs_test_…, pi_…, ch_…, evt_…): alleen letters, cijfers en _
export const isStripeId = (v: unknown, prefix: string): v is string =>
  typeof v === "string" && v.length <= 255 && v.startsWith(prefix) && /^[A-Za-z0-9_]+$/.test(v);

// ---------------- configuratie ----------------
export type BillingConfig = { secretKey: string; webhookSecret: string; automaticTax: boolean; mode: "test" | "live" | null };
export function billingConfig(env: (k: string) => string | undefined): BillingConfig {
  const secretKey = (env("STRIPE_SECRET_KEY") ?? "").trim();
  const ok = /^(sk|rk)_(test|live)_[A-Za-z0-9]+$/.test(secretKey);
  return {
    secretKey: ok ? secretKey : "",
    webhookSecret: (env("STRIPE_WEBHOOK_SECRET") ?? "").trim(),
    automaticTax: /^(1|true|yes|on|ja)$/i.test((env("STRIPE_AUTOMATIC_TAX") ?? "").trim()),
    mode: !ok ? null : /_live_/.test(secretKey) ? "live" : "test",
  };
}

// ---------------- Checkout Session ----------------
export type CheckoutInput = { userId: string; email?: string | null; lang: "nl" | "en"; automaticTax: boolean; waiverAt: string };
export const normalizeLang = (v: unknown): "nl" | "en" => (String(v ?? "").toLowerCase().startsWith("en") ? "en" : "nl");

/** Velden van POST /v1/checkout/sessions (form-encoded, volgorde vast voor de tests). */
export function checkoutParams(i: CheckoutInput): [string, string][] {
  const nl = i.lang === "nl";
  const p: [string, string][] = [
    ["mode", "payment"],
    ["line_items[0][quantity]", "1"],
    ["line_items[0][price_data][currency]", PRICE_CURRENCY],
    ["line_items[0][price_data][unit_amount]", String(PRICE_CENTS)],
    ["line_items[0][price_data][product_data][name]", PRODUCT_NAME],
    ["line_items[0][price_data][product_data][description]", nl
      ? "Eenmalig, voor je hele Bingr-account: tot 3 schermen tegelijk, 15 apparaten, onbeperkt servers en alle functies."
      : "One-time, for your whole Bingr account: up to 3 screens at once, 15 devices, unlimited servers and every feature."],
    ["client_reference_id", i.userId],
    ["metadata[user_id]", i.userId],
    ["metadata[plan]", "lifetime"],
    // instemming met directe levering en afstand van het herroepingsrecht (vinkje op bingr.online/upgrade/), als bewijs
    ["metadata[withdrawal_waiver_at]", i.waiverAt],
    ["payment_intent_data[description]", PRODUCT_NAME],
    ["payment_intent_data[statement_descriptor_suffix]", STATEMENT_SUFFIX],
    ["payment_intent_data[metadata][user_id]", i.userId],
    ["payment_intent_data[metadata][plan]", "lifetime"],
    ["locale", i.lang],
    ["success_url", SUCCESS_URL],
    ["cancel_url", CANCEL_URL],
    // kwitantie/factuur na betaling (Stripe mailt hem en hij staat ook op Mijn Bingr)
    ["invoice_creation[enabled]", "true"],
    ["invoice_creation[invoice_data][description]", PRODUCT_NAME],
    ["invoice_creation[invoice_data][footer]", sellerLine(i.lang)],
    ["invoice_creation[invoice_data][metadata][user_id]", i.userId],
    ["custom_text[submit][message]", nl
      ? `Lifetime staat direct na betaling aan. Je hebt ingestemd met directe levering en ziet daarmee af van je herroepingsrecht. Verkoper: ${SELLER.name} (KvK ${SELLER.kvk}).`
      : `Lifetime is active right after payment. You agreed to immediate delivery and thereby waive your right of withdrawal. Seller: ${SELLER.name} (Chamber of Commerce ${SELLER.kvk}).`],
  ];
  if (i.email) p.push(["customer_email", i.email]);
  if (i.automaticTax) {
    p.push(["automatic_tax[enabled]", "true"]);
    p.push(["line_items[0][price_data][tax_behavior]", "inclusive"]);
    p.push(["line_items[0][price_data][product_data][tax_code]", TAX_CODE]);
  }
  return p;
}
export function sellerLine(lang: "nl" | "en"): string {
  return lang === "nl"
    ? `Bingr is een product van ${SELLER.name}, ${SELLER.city}, Nederland · KvK ${SELLER.kvk} · btw ${SELLER.vat} · ${SELLER.email}`
    : `Bingr is a product of ${SELLER.name}, ${SELLER.city}, the Netherlands · Chamber of Commerce ${SELLER.kvk} · VAT ${SELLER.vat} · ${SELLER.email}`;
}
export const formEncode = (p: [string, string][]) => p.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");

/** Idempotency-Key per account, taal en minuut: twee keer klikken geeft dezelfde sessie, geen dubbele. */
export function idempotencyKey(userId: string, lang: string, automaticTax: boolean, nowMs: number): string {
  return `bingr-lifetime-${userId.toLowerCase()}-${lang}-${automaticTax ? "t" : "n"}-${Math.floor(nowMs / 60_000)}`;
}

// ---------------- Stripe-handtekening (Stripe-Signature: t=…,v1=…) ----------------
export function parseSignature(header: string | null | undefined): { t: number; v1: string[] } | null {
  if (!header || header.length > 2000) return null;
  let t = NaN; const v1: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 1) continue;
    const k = part.slice(0, i).trim(), v = part.slice(i + 1).trim();
    if (k === "t" && /^\d{1,12}$/.test(v)) t = Number(v);
    else if (k === "v1" && /^[0-9a-f]{64}$/i.test(v)) v1.push(v.toLowerCase());
  }
  return Number.isFinite(t) && v1.length ? { t, v1 } : null;
}
export async function hmacHex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}
function sameHex(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
export type SigResult = "ok" | "no_secret" | "bad_header" | "too_old" | "mismatch";
/** Controleert de handtekening over de ruwe body (zoals ontvangen, niet opnieuw geserialiseerd). */
export async function verifySignature(rawBody: string, header: string | null, secret: string, nowMs = Date.now(), toleranceS = SIG_TOLERANCE_S): Promise<SigResult> {
  if (!secret) return "no_secret";
  const s = parseSignature(header);
  if (!s) return "bad_header";
  if (Math.abs(nowMs / 1000 - s.t) > toleranceS) return "too_old";
  const want = await hmacHex(secret, `${s.t}.${rawBody}`);
  return s.v1.some((v) => sameHex(v, want)) ? "ok" : "mismatch";
}
/** Header zoals Stripe hem maakt (voor tests en de rooktest). */
export async function signHeader(rawBody: string, secret: string, tSec: number): Promise<string> {
  return `t=${tSec},v1=${await hmacHex(secret, `${tSec}.${rawBody}`)}`;
}

// ---------------- events -> wat te doen ----------------
// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
/** taxAmount: btw volgens Stripe Tax (total_details.amount_tax) als automatic_tax aan stond, anders null (onbekend). */
export type Purchase = { userId: string; sessionId: string; paymentIntent: string | null; amount: number; currency: string; taxAmount: number | null };
/** Terugbetaling of chargeback (bedrag en Stripe-kosten in centen, moment ISO). Alleen bedragen, geen gegevens van de klant. */
export type RefundRow = { id: string; kind: "refund" | "dispute"; amount: number; fee: number; at: string };
export type Decision =
  | { kind: "grant"; purchase: Purchase }
  | { kind: "pending"; purchase: Purchase }
  | { kind: "failed"; sessionId: string }
  // charge.refunded: ook gedeeltelijk (voor de omzet); alleen volledig zet een gekochte Lifetime terug naar Gratis
  | { kind: "refund"; paymentIntent: string; chargeId: string | null; amountRefunded: number; full: boolean }
  | { kind: "revoke"; paymentIntent: string; status: "refunded" | "disputed"; dispute?: RefundRow }
  | { kind: "details"; paymentIntent: string }
  | { kind: "ignore"; reason: string };

/** Aankoop uit een Checkout Session (alleen onze Lifetime-sessies, met een geldig account-id). */
export function purchaseFromSession(s: Obj | null | undefined): Purchase | null {
  if (!s || typeof s !== "object" || s.object !== "checkout.session" || s.mode !== "payment") return null;
  const userId = s.client_reference_id ?? s.metadata?.user_id;
  if (!isUuid(userId) || (s.metadata?.plan && s.metadata.plan !== "lifetime")) return null;
  if (!isStripeId(s.id, "cs_")) return null;
  const pi = typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id;
  return {
    userId: userId.toLowerCase(), sessionId: s.id, paymentIntent: isStripeId(pi, "pi_") ? pi : null,
    amount: Number.isInteger(s.amount_total) ? s.amount_total : PRICE_CENTS, currency: String(s.currency || PRICE_CURRENCY).toLowerCase(),
    taxAmount: s.automatic_tax?.enabled === true && Number.isInteger(s.total_details?.amount_tax) && s.total_details.amount_tax >= 0
      ? s.total_details.amount_tax : null,
  };
}
export function decide(event: Obj | null | undefined): Decision {
  if (!event || typeof event !== "object" || event.object !== "event" || !isStripeId(event.id, "evt_")) return { kind: "ignore", reason: "bad_event" };
  const o = event.data?.object;
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const p = purchaseFromSession(o);
      if (!p) return { kind: "ignore", reason: "not_ours" };
      if (o.payment_status === "paid") return { kind: "grant", purchase: p };
      // bv. een vertraagde betaalmethode: Lifetime pas bij async_payment_succeeded
      if (event.type === "checkout.session.completed" && o.payment_status === "unpaid") return { kind: "pending", purchase: p };
      return { kind: "ignore", reason: "not_paid" };
    }
    case "checkout.session.async_payment_failed": {
      const p = purchaseFromSession(o);
      return p ? { kind: "failed", sessionId: p.sessionId } : { kind: "ignore", reason: "not_ours" };
    }
    case "charge.refunded": {
      if (!o || o.object !== "charge") return { kind: "ignore", reason: "bad_object" };
      const pi = typeof o.payment_intent === "string" ? o.payment_intent : o.payment_intent?.id;
      if (!isStripeId(pi, "pi_")) return { kind: "ignore", reason: "no_payment_intent" };
      const refunded = Number.isInteger(o.amount_refunded) && o.amount_refunded > 0 ? o.amount_refunded : 0;
      const full = o.refunded === true || (Number.isInteger(o.amount) && refunded >= o.amount);
      return { kind: "refund", paymentIntent: pi, chargeId: isStripeId(o.id, "ch_") || isStripeId(o.id, "py_") ? o.id : null, amountRefunded: refunded, full };
    }
    case "charge.dispute.created": {
      if (!o || o.object !== "dispute") return { kind: "ignore", reason: "bad_object" };
      const pi = typeof o.payment_intent === "string" ? o.payment_intent : o.payment_intent?.id;
      if (!isStripeId(pi, "pi_")) return { kind: "ignore", reason: "no_payment_intent" };
      const d = disputeRow(o, event.created);
      return d ? { kind: "revoke", paymentIntent: pi, status: "disputed", dispute: d } : { kind: "revoke", paymentIntent: pi, status: "disputed" };
    }
    case "charge.updated": {
      // alleen interessant als de balance transaction (Stripe-kosten) er nu is
      if (!o || o.object !== "charge" || !o.balance_transaction) return { kind: "ignore", reason: "no_balance" };
      const pi = typeof o.payment_intent === "string" ? o.payment_intent : o.payment_intent?.id;
      return isStripeId(pi, "pi_") ? { kind: "details", paymentIntent: pi } : { kind: "ignore", reason: "no_payment_intent" };
    }
    default:
      return { kind: "ignore", reason: "other_event" };
  }
}

// ---------------- omzet: Stripe-kosten, betaalmethode, land, terugbetalingen ----------------
const int0 = (v: unknown) => (Number.isInteger(v) && (v as number) >= 0 ? v as number : null);
const isoOf = (sec: unknown, fallback: string) => (Number.isInteger(sec) && (sec as number) > 0 ? new Date((sec as number) * 1000).toISOString() : fallback);
/** Gegevens voor de omzet uit een charge (met of zonder uitgeklapte balance_transaction). Alleen bedragen en codes. */
export type ChargeDetails = { chargeId: string | null; fee: number | null; net: number | null; method: string | null; country: string | null };
export function detailsFromCharge(ch: Obj | null | undefined): ChargeDetails | null {
  if (!ch || typeof ch !== "object" || ch.object !== "charge") return null;
  const bt = ch.balance_transaction && typeof ch.balance_transaction === "object" ? ch.balance_transaction : null;
  const pm = ch.payment_method_details && typeof ch.payment_method_details === "object" ? ch.payment_method_details : {};
  // Apple Pay / Google Pay zijn een kaart met een wallet; anders het type (ideal, bancontact, card, …)
  const wallet = pm.type === "card" ? pm.card?.wallet?.type : null;
  const m = String(wallet || pm.type || "").toLowerCase();
  const cc = String(ch.billing_details?.address?.country || pm.card?.country || pm[String(pm.type)]?.country || "").toUpperCase();
  return {
    chargeId: isStripeId(ch.id, "ch_") || isStripeId(ch.id, "py_") ? ch.id : null,
    fee: bt ? int0(bt.fee) : null,
    net: bt && Number.isInteger(bt.net) ? bt.net : null,
    method: /^[a-z_]{1,32}$/.test(m) ? m : null,
    country: /^[A-Z]{2}$/.test(cc) ? cc : null,
  };
}
/** Uit een PaymentIntent met expand[]=latest_charge.balance_transaction. */
export function detailsFromPaymentIntent(pi: Obj | null | undefined): ChargeDetails | null {
  if (!pi || typeof pi !== "object" || pi.object !== "payment_intent") return null;
  return detailsFromCharge(pi.latest_charge && typeof pi.latest_charge === "object" ? pi.latest_charge : null);
}
/** Parameters voor GET /v1/payment_intents/{id}. */
export const DETAILS_EXPAND: [string, string][] = [["expand[]", "latest_charge.balance_transaction"]];
/** Terugbetalingen uit GET /v1/refunds?charge=… (alleen gelukt of onderweg; mislukt/geannuleerd telt niet). */
export function refundRows(list: Obj | null | undefined, nowIso: string): RefundRow[] {
  const data = Array.isArray(list?.data) ? list!.data : [];
  return data.filter((r: Obj) => r?.object === "refund" && (isStripeId(r.id, "re_") || isStripeId(r.id, "pyr_")))
    .filter((r: Obj) => !["failed", "canceled"].includes(String(r.status)) && int0(r.amount) !== null)
    .map((r: Obj) => ({ id: r.id, kind: "refund" as const, amount: r.amount, fee: 0, at: isoOf(r.created, nowIso) }));
}
/** Zonder Stripe-sleutel: één rij per charge met het totaal terugbetaalde bedrag (wordt bijgewerkt). */
export function refundFallback(chargeId: string, amountRefunded: number, nowIso: string): RefundRow {
  return { id: chargeId, kind: "refund", amount: amountRefunded, fee: 0, at: nowIso };
}
/** Chargeback: bedrag en de dispute-kosten (som van de fees in balance_transactions). */
export function disputeRow(d: Obj | null | undefined, eventCreated?: unknown, nowIso = new Date().toISOString()): RefundRow | null {
  if (!d || d.object !== "dispute" || !(isStripeId(d.id, "dp_") || isStripeId(d.id, "du_")) || int0(d.amount) === null) return null;
  const fee = (Array.isArray(d.balance_transactions) ? d.balance_transactions : [])
    .reduce((a: number, b: Obj) => a + (int0(b?.fee) ?? 0), 0);
  return { id: d.id, kind: "dispute", amount: d.amount, fee, at: isoOf(d.created ?? eventCreated, nowIso) };
}

// ---------------- account_plans ----------------
export type PlanRowFull = { plan?: string; max_streams?: number | null; max_devices?: number | null; source?: string | null } | null;
const shortId = (id: string | null) => (id ? id.slice(0, 40) : "-");
/** Rij voor account_plans na een betaalde aankoop: Lifetime, bron 'purchase', eigen limieten blijven. */
export function grantRow(cur: PlanRowFull, p: Purchase, nowIso: string) {
  return {
    user_id: p.userId, plan: "lifetime", source: "purchase", granted_by: "stripe", updated_at: nowIso,
    max_streams: cur?.max_streams ?? null, max_devices: cur?.max_devices ?? null,
    note: `Stripe ${shortId(p.sessionId)} / ${shortId(p.paymentIntent)}`,
  };
}
/**
 * Na terugbetaling of chargeback: alleen een gekochte Lifetime gaat terug naar Gratis. Geen eigen limieten = rij weg
 * ("delete"); wel eigen limieten = rij met plan 'free' ("update"). Lifetime uit het beheer of cadeau blijft ("keep").
 */
export function revokeAction(cur: PlanRowFull, status: "refunded" | "disputed", paymentIntent: string, nowIso: string, otherPaid = false):
  | { kind: "keep"; reason: string } | { kind: "delete" } | { kind: "update"; row: Record<string, unknown> } {
  if (!cur || cur.plan !== "lifetime") return { kind: "keep", reason: "not_lifetime" };
  if (cur.source !== "purchase") return { kind: "keep", reason: "not_purchase" };
  if (otherPaid) return { kind: "keep", reason: "other_purchase" };
  if (cur.max_streams == null && cur.max_devices == null) return { kind: "delete" };
  return { kind: "update", row: { plan: "free", source: null, granted_by: "stripe", updated_at: nowIso,
    note: `${status === "refunded" ? "Terugbetaald" : "Chargeback"}: ${shortId(paymentIntent)}` } };
}

// ---------------- weergave ----------------
export type PurchaseRow = { created_at: string; paid_at?: string | null; amount: number; currency: string; status: string; refunded_at?: string | null };
export function purchaseView(r: PurchaseRow, receipt?: { receipt_url?: string | null; invoice_url?: string | null; invoice_pdf?: string | null }) {
  const https = (u: unknown) => (typeof u === "string" && /^https:\/\/[a-z0-9.-]*stripe\.com\//i.test(u) ? u : null);
  return {
    created_at: r.created_at, paid_at: r.paid_at ?? null, amount: r.amount, currency: r.currency, status: r.status,
    refunded_at: r.refunded_at ?? null,
    receipt_url: https(receipt?.receipt_url), invoice_url: https(receipt?.invoice_url), invoice_pdf: https(receipt?.invoice_pdf),
  };
}
/** "€ 4,99" / "€4.99" */
export function formatAmount(cents: number, currency: string, lang: "nl" | "en" = "nl"): string {
  const v = (cents / 100).toFixed(2);
  const cur = currency.toLowerCase() === "eur" ? "€" : currency.toUpperCase() + " ";
  return lang === "nl" ? `${cur}${cur === "€" ? " " : ""}${v.replace(".", ",")}` : `${cur}${v}`;
}
