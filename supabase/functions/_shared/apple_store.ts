// Build 167: database-stappen voor Apple-aankopen (functie billing `apple_verify` en functie apple-notify). Tabellen
// billing_purchases (provider 'apple', apple_original_transaction_id uniek), billing_refunds, account_plans en
// billing_apple_events in supabase/schema.sql. Alles idempotent; fouten bevatten alleen een code.
import { appleGrantRow, type AppleTx } from "./apple.ts";
import { revokeAction, type PlanRowFull } from "./billing.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const fail = (where: string, e: { code?: string } | null) => new Error(`${where}: ${e?.code ?? "fout"}`);

async function planOf(db: Db, userId: string): Promise<PlanRowFull> {
  const { data, error } = await db.from("account_plans").select("plan,max_streams,max_devices,source").eq("user_id", userId).maybeSingle();
  if (error) throw fail("account_plans", error);
  return data ?? null;
}
async function byOriginal(db: Db, orig: string) {
  const { data, error } = await db.from("billing_purchases").select("id,user_id,status,amount")
    .eq("apple_original_transaction_id", orig).maybeSingle();
  if (error) throw fail("billing_purchases", error);
  return data as { id: number; user_id: string | null; status: string; amount: number } | null;
}

export type AppleGrant =
  | { ok: true; granted: boolean; already: boolean }
  | { ok: false; error: "owned_by_other_account" | "revoked" };

/**
 * Apple-aankoop vastleggen en Lifetime geven. Een transactie hoort bij precies één account: staat hij al bij een ander
 * (of verwijderd) account, dan owned_by_other_account; een terugbetaalde aankoop wordt niet opnieuw actief.
 */
export async function grantApple(db: Db, userId: string, tx: AppleTx, nowIso = new Date().toISOString()): Promise<AppleGrant> {
  const uid = userId.toLowerCase();
  let prev = await byOriginal(db, tx.originalTransactionId);
  if (!prev) {
    const { error } = await db.from("billing_purchases").insert({
      user_id: uid, provider: "apple", apple_original_transaction_id: tx.originalTransactionId, apple_transaction_id: tx.transactionId,
      environment: tx.environment, amount: tx.amount ?? 0, currency: tx.currency ?? "eur", status: "paid",
      paid_at: tx.purchasedAt ?? nowIso, updated_at: nowIso,
    });
    // tegelijk door een ander verzoek aangemaakt (uniek): opnieuw lezen en vergelijken, nooit overschrijven
    if (error && error.code !== "23505") throw fail("billing_purchases", error);
    prev = error ? await byOriginal(db, tx.originalTransactionId) : null;
  }
  if (prev) {
    if (prev.user_id === null || prev.user_id === undefined || String(prev.user_id).toLowerCase() !== uid) return { ok: false, error: "owned_by_other_account" };
    if (prev.status === "refunded" || prev.status === "disputed") return { ok: false, error: "revoked" };
  }
  const cur = await planOf(db, uid);
  if (cur?.plan === "lifetime" && cur.source === "purchase" && prev) return { ok: true, granted: false, already: true };
  if (cur?.plan === "lifetime" && cur.source !== "purchase") return { ok: true, granted: false, already: true };
  const { error } = await db.from("account_plans").upsert(appleGrantRow(cur, uid, tx, nowIso), { onConflict: "user_id" });
  if (error) throw fail("account_plans", error);
  return { ok: true, granted: cur?.plan !== "lifetime", already: cur?.plan === "lifetime" };
}

/**
 * REFUND / REVOKE van Apple: aankoop 'refunded' (met een rij in billing_refunds voor de omzet, id apl_<transactie>) en
 * een gekochte Lifetime terug naar Gratis, net als bij een terugbetaling via Stripe (Lifetime uit het beheer of cadeau blijft).
 */
export async function revokeApple(db: Db, tx: { originalTransactionId: string; transactionId: string }, nowIso = new Date().toISOString()):
  Promise<{ found: boolean; downgraded: boolean; reason?: string }> {
  const row = await byOriginal(db, tx.originalTransactionId);
  if (!row) return { found: false, downgraded: false };
  if (row.status !== "refunded") {
    const { error } = await db.from("billing_purchases").update({ status: "refunded", refunded_at: nowIso, updated_at: nowIso }).eq("id", row.id);
    if (error) throw fail("billing_purchases", error);
  }
  const { error: re } = await db.from("billing_refunds").upsert({
    id: `apl_${tx.transactionId}`, purchase_id: row.id, kind: "refund", amount: row.amount ?? 0, fee: 0, refunded_at: nowIso,
  }, { onConflict: "id", ignoreDuplicates: true });
  if (re) throw fail("billing_refunds", re);
  if (row.user_id === null || row.user_id === undefined) return { found: true, downgraded: false, reason: "account_deleted" };
  const userId = String(row.user_id);
  const { data: others, error: oe } = await db.from("billing_purchases").select("id").eq("user_id", userId).eq("status", "paid").limit(1);
  if (oe) throw fail("billing_purchases", oe);
  const a = revokeAction(await planOf(db, userId), "refunded", `apple_${tx.originalTransactionId}`, nowIso, (others ?? []).length > 0);
  if (a.kind === "keep") return { found: true, downgraded: false, reason: a.reason };
  const q = a.kind === "delete"
    ? db.from("account_plans").delete().eq("user_id", userId).eq("source", "purchase")
    : db.from("account_plans").update({ ...a.row, granted_by: "apple" }).eq("user_id", userId).eq("source", "purchase");
  const { error: de } = await q;
  if (de) throw fail("account_plans", de);
  return { found: true, downgraded: true };
}

/** Is deze notificatie (notificationUUID) al verwerkt? */
export async function notifySeen(db: Db, id: string): Promise<boolean> {
  const { data, error } = await db.from("billing_apple_events").select("id").eq("id", id).maybeSingle();
  if (error) throw fail("billing_apple_events", error);
  return !!data;
}
export async function notifyDone(db: Db, id: string, type: string, result: string) {
  const { error } = await db.from("billing_apple_events").upsert({ id, type: type.slice(0, 40), result: result.slice(0, 40) }, { onConflict: "id", ignoreDuplicates: true });
  if (error) throw fail("billing_apple_events", error);
}
