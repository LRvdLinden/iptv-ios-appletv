// Build 181 (Bingr Premium): database-stappen voor abonnementen (tabellen premium_subscriptions, premium_trials,
// premium_payments en de spiegel in account_plans; supabase/schema.sql, blok "unittest premium"). Gedeeld door
// device-auth, billing, stripe-webhook en apple-notify. Alles idempotent; fouten bevatten alleen een code.
import { sha256Hex, emailHash, CLAIM_DAYS } from "./billing.ts";
import {
  accessUntil, type PremiumPayment, type PremiumSettings, type StripeSub, type SubPlan, type SubRow, type SubStatus,
} from "./premium.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const fail = (where: string, e: { code?: string } | null) => new Error(`${where}: ${e?.code ?? "fout"}`);
export const SUB_COLUMNS = "id,user_id,provider,plan,status,will_renew,expires_at,trial_until,access_until,stripe_customer_id,stripe_subscription_id,mode";

export type PremiumInfo = { subscription: SubRow | null; trialUsed: boolean; hadSubscription: boolean; customer: string | null };
/** De beste rij van dit account (actief eerst, hoogste access_until; anders de laatst bijgewerkte), en of er een proef was. */
export async function premiumInfo(db: Db, userId: string): Promise<PremiumInfo> {
  const uid = userId.toLowerCase();
  const [subs, trial] = await Promise.all([
    db.from("premium_subscriptions").select(SUB_COLUMNS).eq("user_id", uid).order("access_until", { ascending: false, nullsFirst: false })
      .order("updated_at", { ascending: false }).limit(5),
    db.from("premium_trials").select("user_id").eq("user_id", uid).maybeSingle(),
  ]);
  if (subs.error) throw fail("premium_subscriptions", subs.error);
  if (trial.error) throw fail("premium_trials", trial.error);
  const rows = (subs.data ?? []) as (SubRow & { stripe_customer_id: string | null; provider: string })[];
  const r = rows[0] ?? null;
  return {
    subscription: r ? { provider: r.provider as SubRow["provider"], plan: r.plan, status: r.status, expires_at: r.expires_at, trial_until: r.trial_until,
      will_renew: !!r.will_renew, access_until: r.access_until } : null,
    trialUsed: !!trial.data, hadSubscription: rows.length > 0,
    customer: rows.find((x) => x.stripe_customer_id)?.stripe_customer_id ?? null,
  };
}

/** Spiegel in account_plans bijwerken (Lifetime-bescherming in de database: bingr_premium_mirror). */
export async function mirror(db: Db, userId: string | null): Promise<string> {
  if (!userId) return "no_user";
  const { data, error } = await db.rpc("bingr_premium_mirror", { p_user: userId.toLowerCase() });
  if (error) throw fail("bingr_premium_mirror", error);
  return String(data ?? "keep");
}
async function markTrial(db: Db, userId: string, provider: string, subId: number | null) {
  const { error } = await db.from("premium_trials").upsert({ user_id: userId, provider, subscription_id: subId }, { onConflict: "user_id", ignoreDuplicates: true });
  if (error && error.code !== "23503") throw fail("premium_trials", error);
}

export type SaveResult = { ok: true; id: number; userId: string | null; mirror: string } | { ok: false; error: "owned_by_other_account" };
/**
 * Stripe-abonnement vastleggen (op stripe_subscription_id). Een abonnement verhuist nooit naar een ander account: een
 * bestaande user_id blijft; zonder user_id (gast) koppelt alleen claimen of `forUser` (account uit de Checkout Session).
 */
export async function saveStripeSub(db: Db, s: PremiumSettings, sub: StripeSub, forUser?: string | null, nowIso = new Date().toISOString()): Promise<SaveResult> {
  const { data: prev, error: pe } = await db.from("premium_subscriptions").select("id,user_id,claim_token_hash").eq("stripe_subscription_id", sub.stripe_subscription_id).maybeSingle();
  if (pe) throw fail("premium_subscriptions", pe);
  const want = (forUser ?? sub.userId)?.toLowerCase() ?? null;
  if (prev?.user_id && want && String(prev.user_id).toLowerCase() !== want) return { ok: false, error: "owned_by_other_account" };
  const userId = prev?.user_id ? String(prev.user_id).toLowerCase() : want;
  const row: Record<string, unknown> = {
    provider: "stripe", plan: sub.plan, status: sub.status, will_renew: sub.will_renew, expires_at: sub.expires_at, trial_until: sub.trial_until,
    access_until: accessUntil(sub, s.grace_days), started_at: sub.started_at, canceled_at: sub.canceled_at, mode: sub.mode,
    stripe_subscription_id: sub.stripe_subscription_id, stripe_customer_id: sub.stripe_customer_id, stripe_price_id: sub.stripe_price_id,
    user_id: userId, updated_at: nowIso,
  };
  if (!userId && sub.claimToken && !prev?.claim_token_hash) {
    row.claim_token_hash = await sha256Hex(sub.claimToken);
    row.claim_expires_at = new Date(Date.now() + CLAIM_DAYS * 86_400_000).toISOString();
  }
  const { data, error } = await db.from("premium_subscriptions").upsert(row, { onConflict: "stripe_subscription_id" }).select("id").single();
  if (error?.code === "23503") { // account verwijderd
    const { data: d2, error: e2 } = await db.from("premium_subscriptions").upsert({ ...row, user_id: null, user_deleted_at: nowIso }, { onConflict: "stripe_subscription_id" }).select("id").single();
    if (e2) throw fail("premium_subscriptions", e2);
    return { ok: true, id: d2.id, userId: null, mirror: "account_deleted" };
  }
  if (error) throw fail("premium_subscriptions", error);
  if (userId && sub.trial_until) await markTrial(db, userId, "stripe", data.id);
  return { ok: true, id: data.id, userId, mirror: await mirror(db, userId) };
}
/** E-mailhash van een gast-abonnement (voor automatisch koppelen via het bevestigde adres). */
export async function setClaimEmail(db: Db, stripeSubId: string, email: string) {
  const { error } = await db.from("premium_subscriptions").update({ claim_email_hash: await emailHash(email) })
    .eq("stripe_subscription_id", stripeSubId).is("user_id", null).is("claim_email_hash", null);
  if (error) throw fail("premium_subscriptions", error);
}
export async function claimMailedSub(db: Db, stripeSubId: string) {
  const { data, error } = await db.from("premium_subscriptions").update({ claim_notified_at: new Date().toISOString() })
    .eq("stripe_subscription_id", stripeSubId).is("claim_notified_at", null).select("id");
  if (error) throw fail("premium_subscriptions", error);
  return (data ?? []).length > 0;
}

export type AppleSubInput = { originalTransactionId: string; productId: string; plan: SubPlan; status: SubStatus; expires_at: string | null; trial: boolean;
  will_renew: boolean; grace_until?: string | null; environment: "live" | "test" };
/**
 * Apple-abonnement vastleggen (op apple_original_transaction_id). `userId` (apple_verify) koppelt een rij zonder account;
 * een rij van een ander account geeft owned_by_other_account. Zonder `userId` (apple-notify) alleen bijwerken of een rij
 * zonder account aanmaken.
 */
export async function saveAppleSub(db: Db, s: PremiumSettings, a: AppleSubInput, userId: string | null, nowIso = new Date().toISOString()): Promise<SaveResult> {
  const { data: prev, error: pe } = await db.from("premium_subscriptions").select("id,user_id,user_deleted_at").eq("apple_original_transaction_id", a.originalTransactionId).maybeSingle();
  if (pe) throw fail("premium_subscriptions", pe);
  const uid = userId?.toLowerCase() ?? null;
  if (prev && uid && ((prev.user_id && String(prev.user_id).toLowerCase() !== uid) || prev.user_deleted_at)) return { ok: false, error: "owned_by_other_account" };
  const owner = prev?.user_id ? String(prev.user_id).toLowerCase() : uid;
  const trialUntil = a.status === "trialing" ? a.expires_at : null;
  const row: Record<string, unknown> = {
    provider: "apple", plan: a.plan, status: a.status, will_renew: a.status === "canceled" || a.status === "expired" || a.status === "revoked" ? false : a.will_renew,
    expires_at: a.expires_at, trial_until: trialUntil, mode: a.environment,
    access_until: accessUntil({ status: a.status, expires_at: a.expires_at, trial_until: trialUntil, grace_until: a.grace_until ?? null }, s.grace_days),
    apple_original_transaction_id: a.originalTransactionId, apple_product_id: a.productId, user_id: owner, updated_at: nowIso,
    canceled_at: a.status === "canceled" ? nowIso : undefined,
  };
  if (!prev) row.started_at = nowIso;
  if (prev && uid && !prev.user_id) row.claimed_at = nowIso;
  const { data, error } = await db.from("premium_subscriptions").upsert(row, { onConflict: "apple_original_transaction_id" }).select("id").single();
  if (error) throw fail("premium_subscriptions", error);
  if (owner && a.trial) await markTrial(db, owner, "apple", data.id);
  return { ok: true, id: data.id, userId: owner, mirror: await mirror(db, owner) };
}
/** Laatste bekende status van een Apple-abonnement (voor notificaties zonder transactie-info). */
export async function appleSubOf(db: Db, orig: string) {
  const { data, error } = await db.from("premium_subscriptions").select(SUB_COLUMNS).eq("apple_original_transaction_id", orig).maybeSingle();
  if (error) throw fail("premium_subscriptions", error);
  return data as (SubRow & { user_id: string | null }) | null;
}

/** build 187: na een mislukte betaling nooit meer toegang dan de respijt vanaf nu (de periode in de database kan al verlengd zijn). */
export function capGrace(until: string | null, graceDays: number, nowIso: string): string | null {
  const cap = Date.parse(nowIso) + graceDays * 86_400_000;
  const u = until ? Date.parse(until) : NaN;
  return Number.isFinite(u) && u <= cap ? until : new Date(cap).toISOString();
}
/** Status van een Stripe-abonnement zetten zonder het hele object (invoice.payment_failed: vangnet). */
export async function markPastDue(db: Db, s: PremiumSettings, stripeSubId: string, nowIso = new Date().toISOString()) {
  const { data, error } = await db.from("premium_subscriptions").select("id,user_id,status,expires_at").eq("stripe_subscription_id", stripeSubId).maybeSingle();
  if (error) throw fail("premium_subscriptions", error);
  if (!data || !["active", "canceled"].includes(data.status)) return "skipped";
  const { error: ue } = await db.from("premium_subscriptions").update({
    status: "past_due", access_until: capGrace(accessUntil({ status: "past_due", expires_at: data.expires_at }, s.grace_days), s.grace_days, nowIso), updated_at: nowIso,
  }).eq("id", data.id);
  if (ue) throw fail("premium_subscriptions", ue);
  return await mirror(db, data.user_id);
}

/** Betaalde factuur vastleggen (premium_payments, idempotent op de factuur-id). */
export async function savePayment(db: Db, p: PremiumPayment): Promise<boolean> {
  const { data: sub } = await db.from("premium_subscriptions").select("id,user_id,plan").eq("stripe_subscription_id", p.subscriptionId).maybeSingle();
  const { error } = await db.from("premium_payments").upsert({
    id: p.id, subscription_id: sub?.id ?? null, user_id: sub?.user_id ?? null, plan: sub?.plan ?? null, amount: p.amount, currency: p.currency,
    tax_amount: p.taxAmount, billing_reason: p.billingReason, mode: p.mode, paid_at: p.paidAt, payment_intent: p.paymentIntent,
  }, { onConflict: "id", ignoreDuplicates: true });
  if (error && error.code !== "23503") throw fail("premium_payments", error);
  return true;
}
export async function savePaymentDetails(db: Db, paymentIntent: string, d: { chargeId: string | null; fee: number | null; net: number | null }) {
  const patch: Record<string, unknown> = {};
  if (d.chargeId) patch.charge_id = d.chargeId;
  if (d.fee !== null) patch.fee = d.fee;
  if (d.net !== null) patch.net_amount = d.net;
  if (!Object.keys(patch).length) return;
  const { error } = await db.from("premium_payments").update(patch).eq("payment_intent", paymentIntent);
  if (error) throw fail("premium_payments", error);
}
/** Terugbetaling van een abonnementsbetaling: bedrag bijhouden. false = geen abonnementsbetaling. */
export async function refundPayment(db: Db, paymentIntent: string, amountRefunded: number, nowIso = new Date().toISOString()): Promise<boolean> {
  const { data, error } = await db.from("premium_payments").update({ refunded_amount: amountRefunded, refunded_at: nowIso })
    .eq("payment_intent", paymentIntent).select("id");
  if (error) throw fail("premium_payments", error);
  return (data ?? []).length > 0;
}

/** Gast-abonnement claimen met het token (bingr_premium_claim). */
export async function claimSubToken(db: Db, userId: string, token: string): Promise<string> {
  const { data, error } = await db.rpc("bingr_premium_claim", { p_user: userId, p_token_hash: await sha256Hex(token) });
  if (error) throw fail("bingr_premium_claim", error);
  return String((data as { result?: string } | null)?.result ?? "invalid");
}
export async function claimSubByEmail(db: Db, userId: string): Promise<number> {
  const { data, error } = await db.rpc("bingr_premium_claim_email", { p_user: userId });
  if (error) throw fail("bingr_premium_claim_email", error);
  return Number((data as { claimed?: number } | null)?.claimed ?? 0);
}
