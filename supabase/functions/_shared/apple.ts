// Build 167: aankoop van Lifetime via Apple (StoreKit 2, non-consumable `nl.lrvdlinden.bingr.lifetime`). Pure logica
// zonder database of netwerk (getest in apple_test.ts): wat een geldige transactie is (na de JWS-controle in
// apple_jws.ts) en wat een App Store Server Notification V2 betekent. Contract in docs/ACCOUNT.md, "Build 167".
// Logs: alleen het type en het resultaat, nooit transactie-id's van klanten, account-id's of bedragen per klant.
import { isUuid } from "./billing.ts";
import { APPLE_PREMIUM_PRODUCTS } from "./premium.ts";

export const APPLE_BUNDLE_ID = "nl.lrvdlinden.bingr";
export const APPLE_PRODUCT_ID = "nl.lrvdlinden.bingr.lifetime";
// transactie-id's van Apple zijn decimale getallen (als tekst)
const TX = /^[0-9]{1,32}$/;
export const isAppleTxId = (v: unknown): v is string => typeof v === "string" && TX.test(v);

export type AppleTx = {
  transactionId: string; originalTransactionId: string; environment: "live" | "test";
  /** in centen (Apple geeft milli-eenheden: 4990 = 4,99); null als Apple geen prijs meegaf */
  amount: number | null; currency: string | null; purchasedAt: string | null;
  /** UUID waarmee gekocht is (account-id, of de pendingAccountToken van vóór het account); alleen ter info */
  appAccountToken?: string | null;
  /** build 181: welke Lifetime (lifetime = oud product € 4,99, lifetime49 = Premium Lifetime) */
  plan?: "lifetime" | "lifetime49";
};
export type TxCheck = { ok: true; tx: AppleTx } | { ok: false; error: "bad_transaction" | "wrong_app" | "wrong_product" | "revoked" };
/** build 181: Lifetime-producten (oud en Premium Lifetime € 49,99); de abonnementen gaan via premium.ts appleProduct. */
export const isLifetimeProduct = (id: unknown) => id === APPLE_PRODUCT_ID || id === APPLE_PREMIUM_PRODUCTS.lifetime;

/** Production = live; Sandbox (en alles anders, zoals Xcode) = test. */
export const appleEnvironment = (v: unknown): "live" | "test" => (v === "Production" ? "live" : "test");

/** Prijs van StoreKit (milli-eenheden) naar centen; valuta in kleine letters (ISO 4217). */
export function priceOf(p: Record<string, unknown>): { amount: number | null; currency: string | null } {
  const price = Number(p.price);
  const cur = typeof p.currency === "string" && /^[A-Za-z]{3}$/.test(p.currency) ? p.currency.toLowerCase() : null;
  const amount = Number.isInteger(price) && price >= 0 && price < 1e9 ? Math.round(price / 10) : null;
  return amount !== null && cur ? { amount, currency: cur } : { amount: null, currency: null };
}
const isoMs = (v: unknown) => (Number.isFinite(Number(v)) && Number(v) > 0 ? new Date(Number(v)).toISOString() : null);

/**
 * Een gecontroleerde transactie (payload van een geldige JWS): juiste app en product, niet ingetrokken.
 * Aanvulling 1 (eerst betalen, dan het account): appAccountToken hoeft NIET de account-id te zijn (de app koopt soms
 * vóór er een account is, met een willekeurige UUID). De echte controle is de koppeling op originalTransactionId
 * (uniek in billing_purchases, wie het eerst claimt krijgt hem; zie apple_store.ts grantApple).
 */
// deno-lint-ignore no-explicit-any
export function checkTransaction(p: Record<string, any> | null | undefined): TxCheck {
  if (!p || typeof p !== "object") return { ok: false, error: "bad_transaction" };
  if (!isAppleTxId(p.transactionId) || !isAppleTxId(p.originalTransactionId ?? p.transactionId)) return { ok: false, error: "bad_transaction" };
  if (p.bundleId !== APPLE_BUNDLE_ID) return { ok: false, error: "wrong_app" };
  if (!isLifetimeProduct(p.productId)) return { ok: false, error: "wrong_product" };
  if (p.revocationDate !== undefined && p.revocationDate !== null) return { ok: false, error: "revoked" };
  const { amount, currency } = priceOf(p);
  const token = typeof p.appAccountToken === "string" && isUuid(p.appAccountToken) ? p.appAccountToken.toLowerCase() : null;
  return {
    ok: true,
    tx: {
      transactionId: p.transactionId, originalTransactionId: p.originalTransactionId ?? p.transactionId,
      environment: appleEnvironment(p.environment), amount, currency, purchasedAt: isoMs(p.purchaseDate), appAccountToken: token,
      plan: p.productId === APPLE_PRODUCT_ID ? "lifetime" : "lifetime49",
    },
  };
}

// ---------------- App Store Server Notifications V2 ----------------
export type NotifyDecision =
  | { kind: "revoke"; type: string; signedTransaction: string }
  | { kind: "test"; type: string }
  | { kind: "ignore"; type: string; reason: string };
/** Notificatietypes die een gekochte Lifetime intrekken (terugbetaald door Apple, of Delen met gezin ingetrokken). */
export const REVOKE_TYPES = new Set(["REFUND", "REVOKE"]);

/** Wat te doen met de (al gecontroleerde) payload van een notificatie. */
// deno-lint-ignore no-explicit-any
export function decideNotification(p: Record<string, any> | null | undefined): NotifyDecision {
  const type = typeof p?.notificationType === "string" ? p.notificationType.slice(0, 40).replace(/[^A-Z_]/g, "") || "?" : "?";
  if (!p || typeof p !== "object") return { kind: "ignore", type, reason: "bad_payload" };
  if (type === "TEST") return { kind: "test", type };
  const data = p.data && typeof p.data === "object" ? p.data : null;
  if (!data) return { kind: "ignore", type, reason: "no_data" };
  if (data.bundleId !== APPLE_BUNDLE_ID) return { kind: "ignore", type, reason: "wrong_app" };
  if (!REVOKE_TYPES.has(type)) return { kind: "ignore", type, reason: "other_type" };
  if (typeof data.signedTransactionInfo !== "string") return { kind: "ignore", type, reason: "no_transaction" };
  return { kind: "revoke", type, signedTransaction: data.signedTransactionInfo };
}
/** notificationUUID (idempotentie); anders null. */
export function notificationId(p: Record<string, unknown> | null | undefined): string | null {
  const v = p?.notificationUUID;
  return typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v) ? v.toLowerCase() : null;
}

// ---------------- build 193: sandbox-aankopen ----------------
/** Zo lang geeft een sandbox-Lifetime toegang aan een account dat geen testaccount is (genoeg voor App Review). */
export const SANDBOX_DAYS = 3;
/**
 * Einde van de tijdelijke toegang: SANDBOX_DAYS na de EERSTE sandbox-aankoop van het account (eenmalig; opnieuw kopen of
 * herstellen verlengt niets). Zonder bruikbaar moment: vanaf nu.
 */
export function sandboxUntil(firstSandboxAt: string | null | undefined, nowIso: string): string {
  const f = firstSandboxAt ? Date.parse(firstSandboxAt) : NaN, n = Date.parse(nowIso);
  const start = Number.isFinite(f) && f <= n ? f : n;
  return new Date(start + SANDBOX_DAYS * 86_400_000).toISOString();
}
export type SandboxPlanRow = { plan?: unknown; source?: unknown; premium_until?: unknown } | null | undefined;
/** Lifetime die echt geldt (een verlopen tijdelijke sandbox-Lifetime of abonnementsspiegel telt niet). */
function lifetimeNow(cur: SandboxPlanRow, now: number): boolean {
  if (cur?.plan !== "lifetime") return false;
  if (cur.source !== "subscription" && cur.source !== "purchase") return true;
  if (cur.source === "purchase" && (cur.premium_until === null || cur.premium_until === undefined)) return true;
  const t = typeof cur.premium_until === "string" ? Date.parse(cur.premium_until) : NaN;
  return Number.isFinite(t) && t > now;
}
export type SandboxDecision =
  /** gewoon doorgaan zoals een echte aankoop (Production, of een testaccount in de sandbox): blijvende Lifetime */
  | { kind: "permanent" }
  /** tijdelijke toegang tot `until` (alleen als het account nu niets heeft) */
  | { kind: "temporary"; until: string }
  /** niets veranderen: het account heeft al toegang (echte Lifetime, abonnement of de lopende tijdelijke toegang) */
  | { kind: "keep" }
  /** de tijdelijke toegang van dit account is op: geen toegang meer via de sandbox */
  | { kind: "expired"; until: string };
/**
 * Wat een Lifetime-aankoop betekent voor de toegang. Production en testaccounts (app_settings.premium.test_users):
 * blijvend, zoals altijd. Elke andere sandbox-aankoop (TestFlight, App Review): hooguit SANDBOX_DAYS tijdelijke toegang,
 * gerekend vanaf de eerste sandbox-aankoop van het account, en nooit over bestaande toegang heen.
 */
export function sandboxDecision(i: { environment: "live" | "test"; testUser: boolean; cur: SandboxPlanRow; firstSandboxAt: string | null; nowIso: string }): SandboxDecision {
  if (i.environment !== "test" || i.testUser) return { kind: "permanent" };
  const now = Date.parse(i.nowIso);
  if (lifetimeNow(i.cur, now)) return { kind: "keep" };
  const until = sandboxUntil(i.firstSandboxAt, i.nowIso);
  return Date.parse(until) > now ? { kind: "temporary", until } : { kind: "expired", until };
}

/**
 * Rij voor account_plans na een Apple-aankoop: Lifetime, bron purchase, door apple; eigen limieten blijven.
 * build 193: `until` = einde van een tijdelijke sandbox-Lifetime (premium_until); null = blijvend. De vlag sandbox en
 * sandbox_at zet de database zelf (trigger bingr_account_plans_sandbox, op de notitie "Apple sandbox …").
 */
export function appleGrantRow(cur: { max_streams?: number | null; max_devices?: number | null } | null, userId: string, tx: AppleTx, nowIso: string,
  until: string | null = null) {
  return {
    user_id: userId, plan: "lifetime", source: "purchase", granted_by: "apple", updated_at: nowIso,
    max_streams: cur?.max_streams ?? null, max_devices: cur?.max_devices ?? null,
    note: `Apple ${tx.environment === "test" ? "sandbox " : ""}${tx.originalTransactionId.slice(0, 32)}`,
    premium_until: tx.environment === "test" ? until : null,
  };
}
