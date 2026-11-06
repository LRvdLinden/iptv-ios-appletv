// Build 167: database-stappen rond Lifetime-only (app_settings lifetime_only / iap / upgrade_link en de tabel
// lifetime_codes in supabase/schema.sql). Gedeeld door device-auth, billing en stripe-webhook. Fouten: alleen een code.
import { entitlements, normalizePlan, normalizeUpgradeLink, type Platform, type PlanRow } from "./plans.ts";
import {
  type CodeRow, euAppleLink, type LifetimeEntitlements, withLifetime, type IapSettings, type LifetimeSettings, normalizeIap, normalizeLifetime, normalizeCode,
} from "./lifetime.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const fail = (where: string, e: { code?: string } | null) => new Error(`${where}: ${e?.code ?? "fout"}`);
export const CODE_COLUMNS = "user_id,code,stripe_promotion_code_id,expires_at,redeemed_at";

export type AllSettings = { lifetime: LifetimeSettings; iap: IapSettings; euApple: boolean; upgradeLink: unknown };
/** De drie instellingen in één keer; bij een fout gooit hij (de aanroeper kiest: veilig terugvallen op "uit"). */
export async function loadSettings(db: Db): Promise<AllSettings> {
  const { data, error } = await db.from("app_settings").select("key,value").in("key", ["lifetime_only", "iap", "upgrade_link"]);
  if (error) throw fail("app_settings", error);
  const m = new Map<string, unknown>(((data ?? []) as { key: string; value: unknown }[]).map((r) => [r.key, r.value]));
  return {
    lifetime: normalizeLifetime(m.get("lifetime_only")), iap: normalizeIap(m.get("iap")), euApple: euAppleLink(m.get("upgrade_link")),
    upgradeLink: m.get("upgrade_link"),
  };
}

/** Eigen code van een account (of null). */
export async function codeOf(db: Db, userId: string): Promise<CodeRow | null> {
  const { data, error } = await db.from("lifetime_codes").select(CODE_COLUMNS).eq("user_id", userId.toLowerCase()).maybeSingle();
  if (error) throw fail("lifetime_codes", error);
  return data ?? null;
}
/** Rij bij een ingetypte code (of null bij een ongeldige vorm of onbekende code). */
export async function codeByText(db: Db, text: unknown): Promise<CodeRow | null> {
  const c = normalizeCode(text);
  if (!c) return null;
  const { data, error } = await db.from("lifetime_codes").select(CODE_COLUMNS).eq("code", c).maybeSingle();
  if (error) throw fail("lifetime_codes", error);
  return data ?? null;
}

/**
 * Betaald met een promotion code: de code van dít account met die promotion code krijgt redeemed_at en purchase_id
 * (de aankoop bij de Checkout Session). Idempotent: een al gebruikte code verandert niet meer.
 */
export async function markRedeemed(db: Db, userId: string, promotionCode: string, sessionId: string, nowIso = new Date().toISOString()):
  Promise<"redeemed" | "already" | "no_code"> {
  const uid = userId.toLowerCase();
  const { data: row, error } = await db.from("lifetime_codes").select("user_id,redeemed_at").eq("user_id", uid)
    .eq("stripe_promotion_code_id", promotionCode).maybeSingle();
  if (error) throw fail("lifetime_codes", error);
  if (!row) return "no_code";
  if (row.redeemed_at) return "already";
  const { data: p, error: pe } = await db.from("billing_purchases").select("id").eq("stripe_session_id", sessionId).maybeSingle();
  if (pe) throw fail("billing_purchases", pe);
  const { error: ue } = await db.from("lifetime_codes").update({ redeemed_at: nowIso, purchase_id: p?.id ?? null })
    .eq("user_id", uid).eq("stripe_promotion_code_id", promotionCode).is("redeemed_at", null);
  if (ue) throw fail("lifetime_codes", ue);
  return "redeemed";
}

/**
 * Entitlements van build 167 voor één account: abonnement (account_plans, bij een databasefout een fout: nooit "Gratis"
 * naar de apps sturen), instellingen (meegegeven, of gelezen) en de eigen kortingscode (alleen als Lifetime-only aan
 * staat en het account Gratis is). Gedeeld door device-auth (entitlements, heartbeat, config) en billing.
 */
export async function buildEntitlements(db: Db, userId: string, createdAt: string | null | undefined, platform: Platform | null,
  settings?: AllSettings, now = Date.now()): Promise<LifetimeEntitlements> {
  const [planRes, s] = await Promise.all([
    db.from("account_plans").select("plan,max_streams,max_devices").eq("user_id", userId).maybeSingle(),
    settings ? Promise.resolve(settings) : loadSettings(db),
  ]);
  if (planRes.error) throw fail("account_plans", planRes.error);
  const row = (planRes.data ?? null) as PlanRow;
  let code: CodeRow | null = null;
  if (s.lifetime.enabled && normalizePlan(row?.plan) !== "lifetime") {
    try { code = await codeOf(db, userId); } catch { code = null; } // zonder code is het antwoord nog steeds juist
  }
  return withLifetime(entitlements(row, normalizeUpgradeLink(s.upgradeLink), platform), {
    settings: s.lifetime, iap: s.iap, euApple: s.euApple, platform, createdAt, code, now,
  });
}
