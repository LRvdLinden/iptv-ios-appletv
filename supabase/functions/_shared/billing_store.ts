// Betalen (build 133): database-stappen voor billing en stripe-webhook (tabellen billing_purchases, billing_events en
// account_plans in supabase/schema.sql). Alles idempotent: dezelfde aankoop of hetzelfde event twee keer verwerken geeft
// hetzelfde resultaat. Fouten bevatten alleen een code, nooit gegevens van de klant.
import { type ChargeDetails, grantRow, type PlanRowFull, type Purchase, type RefundRow, revokeAction } from "./billing.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const fail = (where: string, e: { code?: string } | null) => new Error(`${where}: ${e?.code ?? "fout"}`);

async function planOf(db: Db, userId: string): Promise<PlanRowFull> {
  const { data, error } = await db.from("account_plans").select("plan,max_streams,max_devices,source").eq("user_id", userId).maybeSingle();
  if (error) throw fail("account_plans", error);
  return data ?? null;
}

// Account verwijderd (fiscale bewaarplicht): de aankoop blijft staan met user_id null en user_deleted_at (trigger
// bingr_billing_user_unlinked in supabase/schema.sql). Een late betaling, terugbetaling of chargeback van zo'n aankoop
// wordt nog vastgelegd, maar geeft of neemt geen Lifetime. Bestaat het account niet meer (23503, foreign key), dan komt
// de aankoop er zonder account bij.
const accountGone = (e: { code?: string } | null) => e?.code === "23503";

/** Betaald: aankoop op 'paid' en Lifetime (bron purchase). Geeft terug of het account nieuw Lifetime kreeg door deze aankoop. */
export async function grant(db: Db, p: Purchase, nowIso = new Date().toISOString()): Promise<{ granted: boolean; already: boolean; deleted?: boolean }> {
  const { data: prev, error: pe } = await db.from("billing_purchases").select("status,user_id").eq("stripe_session_id", p.sessionId).maybeSingle();
  if (pe) throw fail("billing_purchases", pe);
  // een terugbetaalde of betwiste aankoop wordt niet opnieuw actief door een laat of herhaald event
  if (prev && (prev.status === "refunded" || prev.status === "disputed")) return { granted: false, already: false };
  const paidAt = prev?.status === "paid" ? undefined : nowIso;
  // btw volgens Stripe Tax (alleen als bekend; null overschrijft niets)
  const tax = p.taxAmount ?? undefined;
  if (prev && (prev.user_id === null || prev.user_id === undefined)) {
    const { error } = await db.from("billing_purchases").update({ status: "paid", paid_at: paidAt, tax_amount: tax, updated_at: nowIso })
      .eq("stripe_session_id", p.sessionId);
    if (error) throw fail("billing_purchases", error);
    return { granted: false, already: false, deleted: true };
  }
  const row = {
    user_id: p.userId, stripe_session_id: p.sessionId, payment_intent: p.paymentIntent, amount: p.amount, currency: p.currency,
    status: "paid", paid_at: paidAt, updated_at: nowIso, tax_amount: tax,
  };
  const { error: ue } = await db.from("billing_purchases").upsert(row, { onConflict: "stripe_session_id" });
  if (accountGone(ue)) {
    const { error } = await db.from("billing_purchases").upsert({ ...row, user_id: null, user_deleted_at: nowIso }, { onConflict: "stripe_session_id" });
    if (error) throw fail("billing_purchases", error);
    return { granted: false, already: false, deleted: true };
  }
  if (ue) throw fail("billing_purchases", ue);
  const cur = await planOf(db, p.userId);
  if (cur?.plan === "lifetime" && cur.source === "purchase" && prev?.status === "paid") return { granted: false, already: true };
  const { error } = await db.from("account_plans").upsert(grantRow(cur, p, nowIso), { onConflict: "user_id" });
  if (error) throw fail("account_plans", error);
  return { granted: cur?.plan !== "lifetime", already: cur?.plan === "lifetime" };
}

/** Afgerond maar nog niet betaald (vertraagde betaalmethode). Een al betaalde aankoop blijft betaald. */
export async function pending(db: Db, p: Purchase, nowIso = new Date().toISOString()) {
  const { data: prev, error: pe } = await db.from("billing_purchases").select("status").eq("stripe_session_id", p.sessionId).maybeSingle();
  if (pe) throw fail("billing_purchases", pe);
  if (prev) return;
  const { error } = await db.from("billing_purchases").insert({
    user_id: p.userId, stripe_session_id: p.sessionId, payment_intent: p.paymentIntent, amount: p.amount, currency: p.currency,
    status: "pending", updated_at: nowIso,
  });
  if (accountGone(error)) {
    const { error: e2 } = await db.from("billing_purchases").insert({
      user_id: null, user_deleted_at: nowIso, stripe_session_id: p.sessionId, payment_intent: p.paymentIntent, amount: p.amount,
      currency: p.currency, status: "pending", updated_at: nowIso,
    });
    if (e2 && e2.code !== "23505") throw fail("billing_purchases", e2);
    return;
  }
  if (error && error.code !== "23505") throw fail("billing_purchases", error);
}

export async function failed(db: Db, sessionId: string, nowIso = new Date().toISOString()) {
  const { error } = await db.from("billing_purchases").update({ status: "failed", updated_at: nowIso })
    .eq("stripe_session_id", sessionId).eq("status", "pending");
  if (error) throw fail("billing_purchases", error);
}

/** Terugbetaald of chargeback: aankoop markeren en een gekochte Lifetime terug naar Gratis. */
export async function revoke(db: Db, paymentIntent: string, status: "refunded" | "disputed", nowIso = new Date().toISOString()):
  Promise<{ found: boolean; downgraded: boolean; reason?: string }> {
  const { data: rows, error } = await db.from("billing_purchases").select("id,user_id,status").eq("payment_intent", paymentIntent).limit(5);
  if (error) throw fail("billing_purchases", error);
  if (!rows?.length) return { found: false, downgraded: false };
  const { error: ue } = await db.from("billing_purchases").update({ status, refunded_at: nowIso, updated_at: nowIso }).eq("payment_intent", paymentIntent);
  if (ue) throw fail("billing_purchases", ue);
  // account verwijderd: de aankoop is gemarkeerd, er is geen Lifetime meer om in te trekken
  if (rows[0].user_id === null || rows[0].user_id === undefined) return { found: true, downgraded: false, reason: "account_deleted" };
  const userId = String(rows[0].user_id);
  const { data: others, error: oe } = await db.from("billing_purchases").select("id").eq("user_id", userId).eq("status", "paid").limit(1);
  if (oe) throw fail("billing_purchases", oe);
  const a = revokeAction(await planOf(db, userId), status, paymentIntent, nowIso, (others ?? []).length > 0);
  if (a.kind === "keep") return { found: true, downgraded: false, reason: a.reason };
  const q = a.kind === "delete"
    ? db.from("account_plans").delete().eq("user_id", userId).eq("source", "purchase")
    : db.from("account_plans").update(a.row).eq("user_id", userId).eq("source", "purchase");
  const { error: de } = await q;
  if (de) throw fail("account_plans", de);
  return { found: true, downgraded: true };
}

/** Is dit Stripe-event al verwerkt? */
export async function eventSeen(db: Db, id: string): Promise<boolean> {
  const { data, error } = await db.from("billing_events").select("id").eq("id", id).maybeSingle();
  if (error) throw fail("billing_events", error);
  return !!data;
}
export async function eventDone(db: Db, id: string, type: string, result: string) {
  const { error } = await db.from("billing_events").upsert({ id, type: type.slice(0, 80), result: result.slice(0, 40) }, { onConflict: "id", ignoreDuplicates: true });
  if (error) throw fail("billing_events", error);
}

// ---------------- omzet (beheer, tab Omzet) ----------------

/** Heeft deze betaling nog geen Stripe-kosten? null = onbekende betaling. */
export async function needsDetails(db: Db, paymentIntent: string): Promise<boolean | null> {
  const { data, error } = await db.from("billing_purchases").select("id,fee").eq("payment_intent", paymentIntent).limit(1);
  if (error) throw fail("billing_purchases", error);
  if (!data?.length) return null;
  return data[0].fee === null || data[0].fee === undefined;
}

/** Stripe-kosten, netto, betaalmethode en land bij de aankoop zetten (alleen wat bekend is). */
export async function saveDetails(db: Db, paymentIntent: string, d: ChargeDetails, nowIso = new Date().toISOString()): Promise<boolean> {
  const patch: Record<string, unknown> = { details_at: nowIso, updated_at: nowIso };
  if (d.chargeId) patch.charge_id = d.chargeId;
  if (d.fee !== null) patch.fee = d.fee;
  if (d.net !== null) patch.net_amount = d.net;
  if (d.method) patch.payment_method = d.method;
  if (d.country) patch.country = d.country;
  const { error } = await db.from("billing_purchases").update(patch).eq("payment_intent", paymentIntent);
  if (error) throw fail("billing_purchases", error);
  return d.fee !== null;
}

/**
 * Terugbetalingen/chargebacks van een betaling vastleggen (billing_refunds, één rij per Stripe-id; idempotent).
 * Komen er echte refund-id's (re_…), dan vervalt een eerdere rij per charge (ch_…, zonder Stripe-sleutel gemaakt).
 */
export async function recordRefunds(db: Db, paymentIntent: string, rows: RefundRow[]): Promise<{ found: boolean; rows: number }> {
  const { data, error } = await db.from("billing_purchases").select("id").eq("payment_intent", paymentIntent).limit(1);
  if (error) throw fail("billing_purchases", error);
  if (!data?.length) return { found: false, rows: 0 };
  const purchaseId = data[0].id;
  if (rows.some((r) => r.id.startsWith("re_") || r.id.startsWith("pyr_"))) {
    const { error: de } = await db.from("billing_refunds").delete().eq("purchase_id", purchaseId).eq("kind", "refund").like("id", "ch_%");
    if (de) throw fail("billing_refunds", de);
  }
  for (const r of rows) {
    const { error: ue } = await db.from("billing_refunds").upsert({
      id: r.id, purchase_id: purchaseId, kind: r.kind, amount: r.amount, fee: r.fee, refunded_at: r.at,
    }, { onConflict: "id" });
    if (ue) throw fail("billing_refunds", ue);
  }
  return { found: true, rows: rows.length };
}
