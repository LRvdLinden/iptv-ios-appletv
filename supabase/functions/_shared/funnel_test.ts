// deno test supabase/functions/_shared/funnel_test.ts
// Build 193: de betaaltrechter. Alleen geldige meldingen tellen; vrije tekst komt nooit in de database.
import { funnelEvent } from "./funnel.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("trechter: geldige melding", () => {
  eq(funnelEvent({ action: "funnel", step: "paywall_shown", platform: "ios", build: 193 }),
    { step: "paywall_shown", platform: "ios", build: 193, product: "", error: "" });
  eq(funnelEvent({ step: "purchase_started", platform: "web", build: "193", product: "year" }),
    { step: "purchase_started", platform: "web", build: 193, product: "year", error: "" });
  eq(funnelEvent({ step: "purchase_failed", platform: "androidtv", build: 193, product: "lifetime", error: "network_error" })?.error, "network_error");
  for (const p of ["ios", "ipados", "tvos", "macos", "android", "androidtv", "web", "windows"]) eq(funnelEvent({ step: "restore_ok", platform: p, build: 1 })?.platform, p);
});
Deno.test("trechter: ongeldige melding telt niet", () => {
  for (const b of [null, undefined, {}, { step: "paywall_shown" }, { step: "x", platform: "ios", build: 1 }, { step: "paywall_shown", platform: "tizen", build: 1 },
    { step: "paywall_shown", platform: "ios" }, { step: "paywall_shown", platform: "ios", build: 0 }, { step: "paywall_shown", platform: "ios", build: 1.5 },
    { step: "paywall_shown", platform: "ios", build: "1e3" }, { step: "paywall_shown", platform: "ios", build: 1_000_000 },
    { step: "purchase_started", platform: "ios", build: 1, product: "week" }, { step: "purchase_started", platform: "ios", build: 1, product: 5 }]) {
    eq(funnelEvent(b as Record<string, unknown>), null, JSON.stringify(b));
  }
});
Deno.test("trechter: foutcode alleen als korte code en alleen bij een mislukte stap", () => {
  const base = { step: "purchase_failed", platform: "ios", build: 193 };
  eq(funnelEvent({ ...base, error: "De aankoop is mislukt voor jan@example.invalid" })?.error, "", "vrije tekst nooit");
  eq(funnelEvent({ ...base, error: "Network_Error" })?.error, "", "hoofdletters niet");
  eq(funnelEvent({ ...base, error: "a".repeat(41) })?.error, "", "te lang");
  eq(funnelEvent({ ...base, error: 404 })?.error, "");
  eq(funnelEvent({ ...base, error: "http_413" })?.error, "http_413");
  eq(funnelEvent({ step: "purchase_ok", platform: "ios", build: 193, error: "http_413" })?.error, "", "geen code bij een gelukte stap");
  eq(funnelEvent({ step: "restore_failed", platform: "macos", build: 193, error: "nothing_to_restore" })?.error, "nothing_to_restore");
});
