// Build 193: de betaaltrechter. De apps en de website melden anoniem welke stap van het kopen is bereikt
// (POST /functions/v1/billing {action:"funnel", …}, zonder inloggen). Er wordt alleen per dag geteld
// (tabel billing_funnel_daily: dag, platform, stap, product, foutcode, aantal): geen account, geen apparaat, geen IP.
// Pure logica (getest in funnel_test.ts); het tellen zelf doet de databasefunctie bingr_funnel_hit.
export const FUNNEL_STEPS = [
  "paywall_shown", "purchase_started", "purchase_ok", "purchase_failed", "purchase_cancelled",
  "restore_started", "restore_ok", "restore_failed",
] as const;
export type FunnelStep = typeof FUNNEL_STEPS[number];
export const FUNNEL_PLATFORMS = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "web", "windows"] as const;
export type FunnelPlatform = typeof FUNNEL_PLATFORMS[number];
export const FUNNEL_PRODUCTS = ["month", "half", "year", "lifetime"] as const;
export type FunnelProduct = typeof FUNNEL_PRODUCTS[number];
export type FunnelEvent = { step: FunnelStep; platform: FunnelPlatform; build: number; product: FunnelProduct | ""; error: string };

const ERROR = /^[a-z0-9_]{1,40}$/;
/**
 * Een melding van een app controleren. Alles moet precies kloppen; anders null (de functie antwoordt dan 200 {ok:false},
 * nooit een fout waar een app op kan stuklopen). `error` alleen bij een mislukte stap en alleen als korte code; vrije
 * tekst (een foutmelding van het systeem, een adres) wordt nooit opgeslagen: dan telt de stap zonder code.
 */
export function funnelEvent(b: Record<string, unknown> | null | undefined): FunnelEvent | null {
  if (!b || typeof b !== "object") return null;
  const step = b.step, platform = b.platform;
  if (typeof step !== "string" || !(FUNNEL_STEPS as readonly string[]).includes(step)) return null;
  if (typeof platform !== "string" || !(FUNNEL_PLATFORMS as readonly string[]).includes(platform)) return null;
  const build = typeof b.build === "number" ? b.build : typeof b.build === "string" && /^[0-9]{1,6}$/.test(b.build) ? Number(b.build) : NaN;
  if (!Number.isInteger(build) || build < 1 || build > 999_999) return null;
  let product: FunnelProduct | "" = "";
  if (b.product !== undefined && b.product !== null && b.product !== "") {
    if (typeof b.product !== "string" || !(FUNNEL_PRODUCTS as readonly string[]).includes(b.product)) return null;
    product = b.product as FunnelProduct;
  }
  const failed = step === "purchase_failed" || step === "restore_failed";
  const error = failed && typeof b.error === "string" && ERROR.test(b.error) ? b.error : "";
  return { step: step as FunnelStep, platform: platform as FunnelPlatform, build, product, error };
}
