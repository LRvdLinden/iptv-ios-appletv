// Build 167 (aanvulling 1, eerst betalen, dan het account): database-stappen voor een gastaankoop via Stripe. De aankoop
// staat in billing_purchases met user_id null, claim_token_hash (SHA-256 van het claimtoken, 30 dagen geldig) en
// claim_email_hash (SHA-256 van het e-mailadres uit Stripe). Claimen gebeurt atomair in de database (bingr_billing_claim,
// bingr_billing_claim_email in supabase/schema.sql). Fouten bevatten alleen een code; nooit e-mailadressen of tokens loggen.
import { CLAIM_DAYS, emailHash, type GuestPurchase, sha256Hex } from "./billing.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const fail = (where: string, e: { code?: string } | null) => new Error(`${where}: ${e?.code ?? "fout"}`);

export type GuestResult = { inserted: boolean; claimed: boolean; revoked: boolean; mailed: boolean };
/**
 * Betaald zonder account: aankoop vastleggen (idempotent op de sessie; een al geclaimde of terugbetaalde aankoop blijft
 * zoals hij is) en meteen proberen te koppelen aan een bevestigd account met hetzelfde e-mailadres.
 */
export async function grantGuest(db: Db, p: GuestPurchase, nowMs = Date.now()): Promise<GuestResult> {
  const nowIso = new Date(nowMs).toISOString();
  const { data: prev, error: pe } = await db.from("billing_purchases").select("id,status,user_id,claim_notified_at").eq("stripe_session_id", p.sessionId).maybeSingle();
  if (pe) throw fail("billing_purchases", pe);
  if (prev && (prev.status === "refunded" || prev.status === "disputed")) return { inserted: false, claimed: false, revoked: true, mailed: true };
  const hash = p.email ? await emailHash(p.email) : null;
  if (!prev) {
    const { error } = await db.from("billing_purchases").insert({
      user_id: null, provider: "stripe", stripe_session_id: p.sessionId, payment_intent: p.paymentIntent, amount: p.amount, currency: p.currency,
      status: "paid", paid_at: nowIso, updated_at: nowIso, tax_amount: p.taxAmount ?? undefined,
      claim_token_hash: await sha256Hex(p.claimToken), claim_expires_at: new Date(nowMs + CLAIM_DAYS * 86_400_000).toISOString(),
      claim_email_hash: hash,
    });
    if (error && error.code !== "23505") throw fail("billing_purchases", error);
  } else if (prev.status !== "paid") {
    const { error } = await db.from("billing_purchases").update({ status: "paid", paid_at: nowIso, updated_at: nowIso }).eq("stripe_session_id", p.sessionId);
    if (error) throw fail("billing_purchases", error);
  }
  if (prev?.user_id) return { inserted: false, claimed: true, revoked: false, mailed: true };
  let claimed = false;
  if (hash) {
    const { data, error } = await db.rpc("bingr_billing_claim_hash", { p_email_hash: hash });
    if (error) throw fail("bingr_billing_claim_hash", error);
    claimed = Number((data as { claimed?: number } | null)?.claimed ?? 0) > 0;
  }
  return { inserted: !prev, claimed, revoked: false, mailed: !!prev?.claim_notified_at };
}
/** Claimmail verstuurd: moment vastleggen (één keer per aankoop). */
export async function claimMailed(db: Db, sessionId: string, nowIso = new Date().toISOString()) {
  const { error } = await db.from("billing_purchases").update({ claim_notified_at: nowIso }).eq("stripe_session_id", sessionId).is("claim_notified_at", null);
  if (error) throw fail("billing_purchases", error);
}

export type ClaimResult = { ok: boolean; result: "claimed" | "already_yours" | "invalid" | "expired" | "owned_by_other_account" | "revoked" };
/** Claimtoken inwisselen voor dit account (bingr_billing_claim: één keer, 30 dagen, alleen betaalde aankopen). */
export async function claimToken(db: Db, userId: string, token: string): Promise<ClaimResult> {
  const { data, error } = await db.rpc("bingr_billing_claim", { p_user: userId, p_token_hash: await sha256Hex(token) });
  if (error) throw fail("bingr_billing_claim", error);
  const r = String((data as { result?: string } | null)?.result ?? "invalid") as ClaimResult["result"];
  return { ok: r === "claimed" || r === "already_yours", result: r };
}
/** Alle ongeclaimde aankopen met het (bevestigde) e-mailadres van dit account koppelen. */
export async function claimByEmail(db: Db, userId: string): Promise<number> {
  const { data, error } = await db.rpc("bingr_billing_claim_email", { p_user: userId });
  if (error) throw fail("bingr_billing_claim_email", error);
  return Number((data as { claimed?: number } | null)?.claimed ?? 0);
}
