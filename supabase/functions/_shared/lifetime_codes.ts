// Build 167: kortingscodes in Stripe aanmaken (beheer, functie billing actie admin_codes_generate met de header
// x-lifetime-secret = LIFETIME_ADMIN_SECRET). Eén coupon met een vaste id (percent_off, duration once, redeem_by = geldig
// tot) en per Gratis-account (bevestigd, niet geblokkeerd, zonder code) eerst een rij in lifetime_codes met de code, daarna
// een promotion code (max_redemptions 1, expires_at) met een Idempotency-Key per account en code. Herhalen tot remaining 0.
// Logs: alleen tellingen en foutcodes.
import { billingConfig } from "./billing.ts";
import { codeValidUntil, couponId, couponParams, promotionIdempotencyKey, promotionParams, randomCode } from "./lifetime.ts";
import { loadSettings } from "./lifetime_store.ts";
import { stripe, stripeError, StripeUnavailable } from "./stripe.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const BUDGET_MS = 100_000;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
export const batchSize = (v: unknown, d: number) => (Number.isInteger(v) && (v as number) >= 1 && (v as number) <= 200 ? v as number : d);
async function rpc<T>(db: Db, name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "fout"}`);
  return data as T;
}
export const codesStats = (db: Db) => rpc<Record<string, number>>(db, "bingr_admin_lifetime_stats");

type Coupon = { id: string; percent_off: number; redeem_by: number; mode: string };
async function ensureCoupon(admin: Db, key: string, mode: string, pct: number, validUntil: string): Promise<Coupon | Response> {
  const id = couponId(pct, validUntil);
  const redeemBy = Math.floor(Date.parse(validUntil) / 1000);
  let r = await stripe(key, "GET", `coupons/${id}`);
  if (r.status === 404) r = await stripe(key, "POST", "coupons", couponParams(pct, validUntil), { idempotencyKey: `bingr-${id}` });
  if (!r.ok) { console.error("lifetime coupon", stripeError(r)); return json({ error: "stripe_error", where: "coupon" }, 502); }
  if (Number(r.body.percent_off) !== pct || Number(r.body.redeem_by) !== redeemBy || r.body.duration !== "once") {
    return json({ error: "coupon_mismatch" }, 409);
  }
  const c = { id, percent_off: pct, redeem_by: redeemBy, mode };
  await admin.from("app_settings").upsert({ key: "lifetime_coupon", value: c, updated_at: new Date().toISOString() }, { onConflict: "key" });
  return c;
}

async function createPromotion(key: string, coupon: string, row: { user_id: string; code: string }, validUntil: string): Promise<string | null> {
  const r = await stripe(key, "POST", "promotion_codes", promotionParams(coupon, row.code, row.user_id, validUntil),
    { idempotencyKey: promotionIdempotencyKey(row.user_id, row.code) });
  const id = r.body?.id;
  if (r.ok && typeof id === "string" && id.startsWith("promo_")) return id;
  // bestaat al (bv. een eerdere ronde na de 24 uur van de Idempotency-Key): overnemen als hij van dit account is
  const l = await stripe(key, "GET", "promotion_codes", [["code", row.code], ["coupon", coupon], ["limit", "1"]]);
  // deno-lint-ignore no-explicit-any
  const hit = (Array.isArray(l.body?.data) ? l.body.data : [])[0] as any;
  if (l.ok && hit?.id?.startsWith?.("promo_") && hit?.metadata?.user_id === row.user_id) return hit.id;
  console.error("lifetime promotion_code", stripeError(r));
  return null;
}

/** Actie admin_codes_generate {dry_run?, batch?}; antwoord zie docs/ACCOUNT.md. */
export async function codesGenerate(admin: Db, body: Record<string, unknown>): Promise<Response> {
  const started = Date.now();
  const s = (await loadSettings(admin)).lifetime;
  const validUntil = codeValidUntil(s);
  if (!validUntil) return json({ error: "settings_incomplete" }, 409);
  if (Date.parse(validUntil) <= Date.now()) return json({ error: "valid_until_past" }, 409);
  const cfg = billingConfig((k) => Deno.env.get(k));
  const batch = batchSize(body.batch, 100);
  const mode = cfg.mode;
  const { data: modes, error: me } = await admin.from("lifetime_codes").select("stripe_mode").not("stripe_mode", "is", null).neq("stripe_mode", mode ?? "").limit(1);
  if (me) throw new Error(`lifetime_codes: ${me.code ?? "fout"}`);
  if (mode && (modes ?? []).length) return json({ error: "stripe_mode_mismatch" }, 409);
  const stats = await codesStats(admin);
  if (body.dry_run === true) {
    return json({
      ok: true, dry_run: true, candidates: Number(stats.candidates ?? 0), pending_stripe: Number(stats.pending_stripe ?? 0),
      coupon: couponId(s.discount_pct, validUntil), valid_until: validUntil, discount_pct: s.discount_pct, mode,
    });
  }
  if (!cfg.secretKey || !mode) return json({ error: "billing_unavailable" }, 503);
  const coupon = await ensureCoupon(admin, cfg.secretKey, mode, s.discount_pct, validUntil);
  if (coupon instanceof Response) return coupon;

  // 1. rijen reserveren (code + geldigheid), zonder Stripe; een botsende code (uniek) krijgt een nieuwe
  const ids = await rpc<string[]>(admin, "bingr_lifetime_candidates", { p_limit: batch });
  let created = 0;
  for (const uid of ids ?? []) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const { error } = await admin.from("lifetime_codes").insert({
        user_id: uid, code: randomCode(), stripe_coupon_id: coupon.id, expires_at: validUntil, stripe_mode: mode,
      });
      if (!error) { created++; break; }
      if (error.code !== "23505") throw new Error(`lifetime_codes: ${error.code ?? "fout"}`);
      const { data: has } = await admin.from("lifetime_codes").select("user_id").eq("user_id", uid).maybeSingle();
      if (has) break; // tegelijk door een andere ronde gemaakt
    }
  }
  // 2. promotion codes in Stripe voor alle rijen die er nog geen hebben (ook van een eerdere, afgebroken ronde)
  const { data: open, error: oe } = await admin.from("lifetime_codes").select("user_id,code,expires_at")
    .is("stripe_promotion_code_id", null).is("redeemed_at", null).eq("stripe_mode", mode).limit(batch);
  if (oe) throw new Error(`lifetime_codes: ${oe.code ?? "fout"}`);
  let made = 0, errors = 0;
  for (const row of (open ?? []) as { user_id: string; code: string; expires_at: string }[]) {
    if (Date.now() - started > BUDGET_MS) break;
    try {
      const promo = await createPromotion(cfg.secretKey, coupon.id, row, row.expires_at);
      if (!promo) { errors++; continue; }
      const { error } = await admin.from("lifetime_codes").update({ stripe_promotion_code_id: promo, stripe_coupon_id: coupon.id })
        .eq("user_id", row.user_id).is("stripe_promotion_code_id", null);
      if (error) throw new Error(`lifetime_codes: ${error.code ?? "fout"}`);
      made++;
    } catch (e) {
      if (e instanceof StripeUnavailable) { errors++; break; }
      throw e;
    }
  }
  const after = await codesStats(admin);
  const remaining = Number(after.candidates ?? 0) + Number(after.pending_stripe ?? 0);
  console.log("lifetime codes_generate", JSON.stringify({ created, stripe_created: made, stripe_errors: errors, remaining }));
  return json({ ok: true, created, stripe_created: made, stripe_errors: errors, remaining, coupon: coupon.id });
}

