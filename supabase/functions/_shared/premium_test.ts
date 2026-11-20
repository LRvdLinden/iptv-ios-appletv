// Unittests van build 181 (Bingr Premium) op de gedeelde gevallen in docs/build181_cases.json, plus de Stripe-parameters,
// de webhook-beslissingen en "enabled false = zoals nu". Draaien: deno test --allow-read supabase/functions/_shared/premium_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  accessUntil, appleNotifyStatus, appleProduct, decidePremium, DEFAULT_PREMIUM, effectivePlanRow, lifetime49CheckoutParams, lookupKey,
  normalizePremium, paymentFromInvoice, portalReturnUrl, premiumScreen, premiumView, priceParams, publicPremium, stripeSubPlan,
  stripeSubStatus, subFromStripe, subscriptionCheckoutParams, type SubRow,
} from "./premium.ts";
import { withLifetime, normalizeLifetime } from "./lifetime.ts";
import { DEFAULT_UPGRADE_LINK, entitlements, normalizePlatform } from "./plans.ts";

// deno-lint-ignore no-explicit-any
const cases: any = JSON.parse(await Deno.readTextFile(new URL("../../../docs/build181_cases.json", import.meta.url)));
const t = (v: string | null) => (v === null ? null : Date.parse(v));
// tijden als moment vergelijken
// deno-lint-ignore no-explicit-any
function sameTimes(a: any, b: any, keys: string[], msg: string) {
  for (const k of keys) assertEquals(a[k] === null ? null : t(a[k]), b[k] === null ? null : t(b[k]), `${msg}: ${k}`);
}

Deno.test("standaard = docs/build181_cases.json defaults", () => {
  assertEquals(normalizePremium(null), { ...DEFAULT_PREMIUM });
  assertEquals(normalizePremium(null), cases.defaults);
});

for (const c of cases.access) {
  Deno.test(`access: ${c.name}`, () => {
    const s = normalizePremium({ ...cases.defaults, ...c.settings });
    const v = premiumView({
      settings: s, now: Date.parse(c.now), createdAt: c.created_at, platform: normalizePlatform(c.platform), planRow: c.plan_row,
      subscription: c.subscription as SubRow | null, trialUsed: c.trial_used, hadSubscription: c.had_subscription, test: c.test,
    });
    const e = c.expect;
    assertEquals(v.access ?? "full", e.access, "access");
    for (const k of ["enabled", "active", "source", "plan", "status", "required", "trial_eligible", "legacy_offer", "manage", "will_renew"]) {
      assertEquals((v as Record<string, unknown>)[k], e[k], k);
    }
    sameTimes(v, e, ["expires_at", "trial_until"], c.name);
  });
}
for (const c of cases.stripe) {
  Deno.test(`stripe: ${c.name}`, () => {
    const r = stripeSubStatus(c.sub);
    assertEquals(r.status, c.expect.status);
    assertEquals(r.will_renew, c.expect.will_renew);
    sameTimes(r, c.expect, ["expires_at", "trial_until"], c.name);
  });
}
for (const c of cases.access_until) {
  Deno.test(`access_until: ${c.name}`, () => {
    const r = accessUntil(c.sub, c.grace_days);
    assertEquals(t(r), t(c.expect));
  });
}
for (const c of cases.apple) {
  Deno.test(`apple: ${c.name}`, () => {
    const r = appleProduct(c.tx) as Record<string, unknown>;
    for (const k of Object.keys(c.expect)) {
      if (k === "expires_at") assertEquals(t(r[k] as string), t(c.expect[k]));
      else assertEquals(r[k], c.expect[k], k);
    }
  });
}
for (const c of cases.apple_notify) {
  Deno.test(`apple_notify: ${c.type} ${c.subtype ?? ""}`, () => assertEquals(appleNotifyStatus(c.type, c.subtype, c.renewal ?? null), c.expect));
}
for (const c of cases.client) {
  Deno.test(`client: ${c.name}`, () => assertEquals(premiumScreen(c.entitlements, Date.parse(c.now), c.offline), c.expect));
}

Deno.test("enabled false: entitlements gelijk aan build 180 op premium na", () => {
  const lo = normalizeLifetime(null), s = normalizePremium(null);
  for (const row of [null, { plan: "lifetime", source: "legacy" }, { plan: "free", max_devices: 4 }]) {
    for (const platform of ["ios", "android", "web", null] as const) {
      const base = entitlements(row, DEFAULT_UPGRADE_LINK, platform);
      const ctx = { settings: lo, iap: { apple: false }, euApple: false, platform, createdAt: "2026-11-25T10:00:00Z", now: Date.parse("2026-12-05T10:00:00Z") };
      const old = withLifetime(base, ctx);
      const pv = premiumView({ settings: s, now: ctx.now, createdAt: ctx.createdAt, platform, planRow: row, subscription: null, trialUsed: false, hadSubscription: false });
      const neu = withLifetime(base, { ...ctx, premium: pv });
      const { premium, ...rest } = neu as Record<string, unknown>;
      assert(premium);
      assertEquals(rest, old);
    }
  }
});
Deno.test("premium aan: access uit premium, ook als Lifetime-only aan staat", () => {
  const lo = normalizeLifetime({ enabled: true, cutover_at: "2026-12-01T00:00:00+01:00" });
  const s = normalizePremium({ enabled: true, new_from_web: "2026-11-21T12:00:00+01:00" });
  const now = Date.parse("2026-11-25T10:00:00Z");
  const base = entitlements(null, DEFAULT_UPGRADE_LINK, "android");
  const pv = premiumView({ settings: s, now, createdAt: "2026-11-24T10:00:00Z", platform: "android", planRow: null, subscription: null, trialUsed: false, hadSubscription: false });
  const e = withLifetime(base, { settings: lo, iap: { apple: false }, euApple: false, platform: "android", createdAt: "2026-11-24T10:00:00Z", now, premium: pv });
  assertEquals(e.access, "activate");
  // Apple doet niet mee: Lifetime-only blijft daar beslissen (vóór cutover = full)
  const pa = premiumView({ settings: s, now, createdAt: "2026-11-24T10:00:00Z", platform: "ios", planRow: null, subscription: null, trialUsed: false, hadSubscription: false });
  assertEquals(withLifetime(entitlements(null, DEFAULT_UPGRADE_LINK, "ios"), { settings: lo, iap: { apple: false }, euApple: false, platform: "ios", createdAt: "2026-11-24T10:00:00Z", now, premium: pa }).access, "full");
});
Deno.test("effectivePlanRow: verlopen spiegel = gratis, Lifetime blijft", () => {
  const now = Date.parse("2026-12-05T10:00:00Z");
  assertEquals(effectivePlanRow({ plan: "lifetime", source: "subscription", premium_until: "2026-12-01T00:00:00Z" }, now)?.plan, "free");
  assertEquals(effectivePlanRow({ plan: "lifetime", source: "subscription", premium_until: "2026-12-31T00:00:00Z" }, now)?.plan, "lifetime");
  assertEquals(effectivePlanRow({ plan: "lifetime", source: "subscription", premium_until: null }, now)?.plan, "free");
  assertEquals(effectivePlanRow({ plan: "lifetime", source: "legacy", premium_until: null }, now)?.plan, "lifetime");
  assertEquals(effectivePlanRow(null, now), null);
});
Deno.test("Checkout abonnement: proef alleen met trialDays, waiver en account", () => {
  const p = new Map(subscriptionCheckoutParams({ plan: "year", priceId: "price_Y", lang: "nl", waiverAt: "x", automaticTax: false, trialDays: 3, userId: "u-1" }));
  assertEquals(p.get("mode"), "subscription");
  assertEquals(p.get("line_items[0][price]"), "price_Y");
  assertEquals(p.get("subscription_data[trial_period_days]"), "3");
  assertEquals(p.get("subscription_data[metadata][user_id]"), "u-1");
  assertEquals(p.get("payment_method_collection"), "always");
  const q = new Map(subscriptionCheckoutParams({ plan: "month", priceId: "price_M", lang: "en", waiverAt: "x", automaticTax: true, trialDays: 0, userId: "u-1", customer: "cus_1", email: "a@example.invalid" }));
  assertEquals(q.has("subscription_data[trial_period_days]"), false);
  assertEquals(q.get("customer"), "cus_1");
  assertEquals(q.has("customer_email"), false);
  assertEquals(q.get("automatic_tax[enabled]"), "true");
  const g = new Map(subscriptionCheckoutParams({ plan: "half", priceId: "price_H", lang: "nl", waiverAt: "x", automaticTax: false, trialDays: 3, claimToken: "a".repeat(43) }));
  assertEquals(g.get("subscription_data[metadata][claim_token]"), "a".repeat(43));
  assert(g.get("success_url")!.startsWith("https://bingr.online/upgrade/klaar/?claim="));
  const l = new Map(lifetime49CheckoutParams({ priceId: "price_L", lang: "nl", waiverAt: "x", automaticTax: false, userId: "u-1" }));
  assertEquals(l.get("mode"), "payment");
  assertEquals(l.get("metadata[plan]"), "lifetime49");
});
Deno.test("prijzen en portal", () => {
  assertEquals(lookupKey("half", 1999), "bingr_premium_half_eur_1999");
  const h = new Map(priceParams("half", 1999));
  assertEquals(h.get("recurring[interval_count]"), "6");
  assertEquals(new Map(priceParams("lifetime", 4999)).has("recurring[interval]"), false);
  assertEquals(portalReturnUrl("https://bingr.online/web/#instellingen"), "https://bingr.online/web/#instellingen");
  assertEquals(portalReturnUrl("https://evil.example/"), "https://bingr.online/upgrade/");
  assertEquals(portalReturnUrl("javascript:alert(1)"), "https://bingr.online/upgrade/");
});
Deno.test("Stripe-abonnement en factuur", () => {
  const s = normalizePremium({ stripe_prices: { live: { year: "price_Y" } } });
  const sub = { object: "subscription", id: "sub_1", customer: "cus_1", status: "trialing", trial_end: 1764496800, start_date: 1764237600, livemode: true,
    items: { data: [{ current_period_end: 1764496800, price: { id: "price_Y", recurring: { interval: "year", interval_count: 1 } } }] },
    metadata: { user_id: "00000000-0000-4000-8000-00000000000A" } };
  const r = subFromStripe(sub, s)!;
  assertEquals(r.plan, "year");
  assertEquals(r.userId, "00000000-0000-4000-8000-00000000000a");
  assertEquals(r.mode, "live");
  assertEquals(stripeSubPlan({ items: { data: [{ price: { id: "price_X", recurring: { interval: "month", interval_count: 6 } } }] } }, s), "half");
  assertEquals(subFromStripe({ object: "subscription", id: "sub_2", items: { data: [{ price: { recurring: { interval: "week" } } }] } }, s), null);
  assertEquals(paymentFromInvoice({ object: "invoice", id: "in_1", amount_paid: 0, subscription: "sub_1" }), null);
  const p = paymentFromInvoice({ object: "invoice", id: "in_2", amount_paid: 2999, currency: "EUR", parent: { subscription_details: { subscription: "sub_1" } },
    billing_reason: "subscription_cycle", total_taxes: [{ amount: 520 }], status_transitions: { paid_at: 1764496800 } })!;
  assertEquals([p.amount, p.currency, p.taxAmount, p.subscriptionId], [2999, "eur", 520, "sub_1"]);
});
Deno.test("webhook: Premium-events herkennen, Lifetime-events niet", () => {
  const ev = (type: string, object: Record<string, unknown>) => ({ object: "event", id: "evt_1", type, data: { object } });
  assertEquals(decidePremium(ev("checkout.session.completed", { object: "checkout.session", mode: "payment", id: "cs_1" })), null);
  const d = decidePremium(ev("checkout.session.completed", { object: "checkout.session", mode: "subscription", id: "cs_1", subscription: "sub_1",
    client_reference_id: "00000000-0000-4000-8000-00000000000a", locale: "en" }));
  assertEquals(d?.kind, "sub_checkout");
  assertEquals(decidePremium(ev("customer.subscription.deleted", { object: "subscription", id: "sub_1" }))?.kind, "sub_update");
  assertEquals(decidePremium(ev("invoice.payment_failed", { object: "invoice", subscription: "sub_1" }))?.kind, "invoice_failed");
  assertEquals(decidePremium(ev("charge.refunded", { object: "charge" })), null);
});
Deno.test("publieke config", () => {
  const off = publicPremium(normalizePremium(null), "other", "test", Date.parse("2026-12-05T10:00:00Z"));
  assertEquals([off.enabled, off.web, off.apple, off.trial_days, off.stripe_ready, off.new_from], [false, false, false, 0, false, null]);
  const s = normalizePremium({ enabled: true, new_from_web: "2026-11-21T12:00:00+01:00", show_prices_web: true,
    stripe_prices: { test: { month: "price_a", half: "price_b", year: "price_c", lifetime: "price_d" } } });
  const on = publicPremium(s, "other", "test", Date.parse("2026-12-05T10:00:00Z"));
  assertEquals([on.enabled, on.web, on.apple, on.existing_after, on.trial_days, on.stripe_ready], [true, true, false, true, 3, true]);
  assertEquals(publicPremium(s, "apple", "live", Date.parse("2026-12-05T10:00:00Z")).enabled, false);
});
