// deno test supabase/functions/_shared/lifetime_test.ts
// Build 167 (alleen Lifetime): instellingen, toegang en proefperiode, kortingscodes (vorm en controle), entitlements (met
// enabled false precies zoals nu), Stripe-coupon en promotion codes, de webhook voor een gebruikte code, gastaankoop
// (aanvulling 1) en de mails. Pure logica en een nep-database; geen netwerk, geen echte gegevens.
import {
  accessFor, ACTIVATION_REQUIRED, DEFAULT_CUTOVER, checkCode, CODE_ALPHABET, CODE_RE, codeValidUntil, couponId, couponParams, DEFAULT_LIFETIME, euAppleLink,
  normalizeCode, normalizeIap, normalizeLifetime, priceAfter, promotionCodeOf, promotionIdempotencyKey, promotionParams, randomCode, trialUntil,
  withLifetime,
} from "./lifetime.ts";
import { buildEntitlements, loadSettings, markRedeemed } from "./lifetime_store.ts";
import { DEFAULT_UPGRADE_LINK, entitlements, PRICE_CENTS } from "./plans.ts";
import {
  checkoutParams, decide, emailHash, guestCheckoutParams, guestFromSession, idempotencyKey, isClaimToken, newClaimToken, sha256Hex,
} from "./billing.ts";
import { claimByEmail, claimToken, grantGuest } from "./guest_store.ts";
import { claimUrl, renderClaimMail } from "./claim_mail.ts";
import { lastValidDay, renderLifetimeMail, SAMPLE_CODE, upgradeUrl } from "../lifetime-notice/mail.ts";
import { batchSize, remindWindow } from "../lifetime-notice/logic.ts";
import { fakeDb } from "./testdb.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
const UID = "0b6f3c1e-2a4d-4e5f-8a9b-1c2d3e4f5a6b", UID2 = "1c7a4d2f-3b5e-4f60-9bac-2d3e4f5a6b7c";
const D = Date.parse("2026-11-07T00:00:00+01:00");

const CUT = "2026-12-01T00:00:00+01:00"; // aanvulling 2
const DAY = 86_400_000;
const on = (o: Record<string, unknown> = {}) => normalizeLifetime({ enabled: true, announce_at: "2026-11-07T00:00:00+01:00", cutover_at: CUT, ...o });

// ---------------- instellingen ----------------
Deno.test("instellingen: standaard uit, ongeldige waarden = standaard", () => {
  eq(normalizeLifetime(undefined), DEFAULT_LIFETIME);
  eq(normalizeLifetime({ enabled: "ja", discount_pct: 95, trial_days: -1, cutover_at: "morgen" }), DEFAULT_LIFETIME);
  eq(normalizeLifetime({ enabled: true, discount_pct: 40, trial_days: 7, cutover_at: CUT }).trial_days, 7);
  eq(normalizeIap(null), { apple: false }); eq(normalizeIap({ apple: true }), { apple: true }); eq(normalizeIap({ apple: 1 }), { apple: false });
  eq(euAppleLink({ apple_eu: true }), true); eq(euAppleLink({ apple: true }), false); eq(euAppleLink(null), false);
  eq(codeValidUntil(on()), CUT, "zonder code_valid_until = cutover_at");
  eq(codeValidUntil(on({ code_valid_until: "2026-12-01T00:00:00Z" })), "2026-12-01T00:00:00Z");
});

// ---------------- toegang ----------------
Deno.test("toegang: uit = altijd full; vóór cutover full; daarna activate voor Gratis, Lifetime full", () => {
  eq(accessFor(DEFAULT_LIFETIME, "free", "2020-01-01T00:00:00Z", D + 100 * DAY).access, "full", "uit");
  eq(accessFor(on(), "free", "2020-01-01T00:00:00Z", D).access, "full", "aankondiging");
  eq(accessFor(on(), "free", "2020-01-01T00:00:00Z", Date.parse(CUT) - 1).access, "full", "net ervoor");
  eq(accessFor(on(), "free", "2020-01-01T00:00:00Z", Date.parse(CUT)).access, "activate", "vanaf cutover");
  eq(accessFor(on(), undefined, null, Date.parse(CUT) + DAY).access, "activate", "geen rij = Gratis");
  eq(accessFor(on(), "lifetime", "2020-01-01T00:00:00Z", Date.parse(CUT) + DAY).access, "full", "Lifetime");
  eq(accessFor(normalizeLifetime({ enabled: true }), "free", null, D + 999 * DAY).access, "full", "zonder cutover_at nooit activate");
  eq(ACTIVATION_REQUIRED, { error: "activation_required", plan: "free" });
});
Deno.test("proefperiode: alleen nieuwe accounts na cutover_at, alleen met trial_days", () => {
  const s = on({ trial_days: 7 }), cut = Date.parse(CUT);
  const newAcc = new Date(cut + DAY).toISOString();
  eq(trialUntil(s, newAcc), new Date(cut + 8 * DAY).toISOString());
  eq(trialUntil(s, "2026-01-01T00:00:00Z"), null, "bestaand account: geen proefperiode");
  eq(trialUntil(on(), newAcc), null, "trial_days 0");
  eq(accessFor(s, "free", newAcc, cut + 3 * DAY), { access: "full", trial_until: new Date(cut + 8 * DAY).toISOString() }, "in de proefperiode");
  eq(accessFor(s, "free", newAcc, cut + 9 * DAY).access, "activate", "proefperiode voorbij");
  eq(accessFor(s, "free", "2026-01-01T00:00:00Z", cut + DAY).access, "activate", "oud account");
});

// ---------------- codes ----------------
Deno.test("codes: vorm BINGR-XXXX-XXXX zonder verwarrende tekens, willekeurig", () => {
  for (const c of "01OIL") ok(!CODE_ALPHABET.includes(c), `geen ${c}`);
  const seen = new Set<string>();
  for (let i = 0; i < 500; i++) { const c = randomCode(); ok(CODE_RE.test(c), c); seen.add(c); }
  eq(seen.size, 500, "geen dubbele in 500");
  // vaste bron: bytes >= 248 worden overgeslagen (geen scheefheid)
  let n = 0;
  eq(randomCode(() => new Uint8Array(16).map(() => (n++ % 2 ? 250 : 0))), "BINGR-AAAA-AAAA");
  eq(normalizeCode(" bingr abcd efgh "), "BINGR-ABCD-EFGH");
  eq(normalizeCode("abcdefgh"), "BINGR-ABCD-EFGH");
  eq(normalizeCode("BINGR-ABCD-EFG0"), null, "0 bestaat niet");
  eq(normalizeCode("BINGR-ABC"), null);
  eq(normalizeCode(12345678), null);
  eq(normalizeCode("x".repeat(100)), null);
});
Deno.test("codes: alleen het eigen account, één keer, tot en met de einddatum, met promotion code", () => {
  const row = { user_id: UID, code: "BINGR-ABCD-EFGH", stripe_promotion_code_id: "promo_1", expires_at: CUT, redeemed_at: null };
  ok(checkCode(row, UID, D).ok);
  ok(checkCode(row, UID.toUpperCase(), D).ok, "hoofdletters");
  eq(checkCode(row, UID2, D), { ok: false, reason: "other_account" });
  eq(checkCode({ ...row, redeemed_at: "2026-11-10T00:00:00Z" }, UID, D), { ok: false, reason: "redeemed" });
  eq(checkCode(row, UID, Date.parse(CUT) + 1), { ok: false, reason: "expired" });
  ok(checkCode(row, UID, Date.parse(CUT)).ok, "op het moment zelf nog geldig");
  eq(checkCode({ ...row, stripe_promotion_code_id: null }, UID, D), { ok: false, reason: "not_ready" });
  eq(checkCode(null, UID, D), { ok: false, reason: "not_found" });
  eq(priceAfter(499, 30), 349); eq(priceAfter(PRICE_CENTS, 50), 249); eq(priceAfter(499, 0), 499);
});

// ---------------- entitlements ----------------
const SET_OFF = { lifetime: DEFAULT_LIFETIME, iap: { apple: false }, euApple: false };
Deno.test("entitlements: enabled false = precies zoals nu, plus alleen access full, iap uit en link_eu_apple false", () => {
  for (const [row, platform] of [[null, "web"], [{ plan: "lifetime", max_devices: 20 }, "ios"], [{ plan: "free" }, "android"]] as const) {
    const base = entitlements(row, DEFAULT_UPGRADE_LINK, platform);
    const e = withLifetime(base, { settings: DEFAULT_LIFETIME, iap: { apple: false }, euApple: false, platform, createdAt: "2026-01-01T00:00:00Z" });
    const { access, iap, lifetime_only, ...rest } = e;
    const { link_eu_apple, ...upgrade } = rest.upgrade;
    eq({ ...rest, upgrade }, base, `bestaande velden ongewijzigd (${platform})`);
    eq(access, "full"); eq(iap, { apple: false, product_id: "nl.lrvdlinden.bingr.lifetime" }); eq(link_eu_apple, false);
    eq(lifetime_only, undefined, "geen lifetime_only");
    ok(!("lifetime_only" in e), "sleutel ontbreekt echt");
  }
  // het oude contract van plans.ts blijft exact gelijk (plans_test.ts dekt dat ook)
  eq(Object.keys(entitlements(null, DEFAULT_UPGRADE_LINK, "web")), ["plan", "limits", "features", "upgrade", "plans"]);
});
Deno.test("entitlements: aan - aankondiging, code alleen voor Gratis en nooit op Apple, activate na cutover", () => {
  const code = { user_id: UID, code: "BINGR-ABCD-EFGH", stripe_promotion_code_id: "promo_1", expires_at: CUT, redeemed_at: null };
  const ctx = (platform: "web" | "ios" | "android", now: number, extra: Record<string, unknown> = {}) =>
    ({ settings: on(), iap: { apple: true }, euApple: true, platform, createdAt: "2026-01-01T00:00:00Z", code, now, ...extra });
  const web = withLifetime(entitlements(null, DEFAULT_UPGRADE_LINK, "web"), ctx("web", D + 1));
  eq(web.lifetime_only, { enabled: true, announced: true, cutover_at: CUT, code: "BINGR-ABCD-EFGH", code_valid_until: CUT, discount_pct: 30, trial_until: null });
  eq(web.access, "full"); eq(web.iap.apple, true); eq(web.upgrade.link_eu_apple, true);
  const ios = withLifetime(entitlements(null, DEFAULT_UPGRADE_LINK, "ios"), ctx("ios", D + 1));
  eq([ios.lifetime_only?.code, ios.lifetime_only?.code_valid_until], [null, null], "Apple: geen code (korting buiten Apple om)");
  eq(ios.upgrade.link, false, "Apple: upgrade.link blijft uit");
  const before = withLifetime(entitlements(null, DEFAULT_UPGRADE_LINK, "web"), ctx("web", D - DAY));
  eq(before.lifetime_only?.announced, false, "vóór announce_at");
  const life = withLifetime(entitlements({ plan: "lifetime" }, DEFAULT_UPGRADE_LINK, "android"), ctx("android", D + 1));
  eq(life.lifetime_only?.code, null, "Lifetime: geen code");
  const after = withLifetime(entitlements(null, DEFAULT_UPGRADE_LINK, "android"), ctx("android", Date.parse(CUT) + 1));
  eq(after.access, "activate"); eq(after.lifetime_only?.code, null, "code verlopen");
  eq(after.plan, "free"); eq(after.limits, { streams: 1, devices: 2, servers: 1 }, "limieten ongewijzigd");
});
Deno.test("entitlements uit de database: instellingen, abonnement en eigen code; databasefout = fout (nooit Gratis)", async () => {
  const db = fakeDb();
  db.tab("app_settings").push(
    { key: "lifetime_only", value: { enabled: true, announce_at: "2026-11-01T00:00:00Z", cutover_at: CUT } },
    { key: "iap", value: { apple: true } }, { key: "upgrade_link", value: { ...DEFAULT_UPGRADE_LINK, apple_eu: true } });
  db.tab("lifetime_codes").push({ user_id: UID, code: "BINGR-ABCD-EFGH", stripe_promotion_code_id: "promo_1", expires_at: CUT, redeemed_at: null });
  const s = await loadSettings(db);
  eq([s.lifetime.enabled, s.iap.apple, s.euApple], [true, true, true]);
  const e = await buildEntitlements(db, UID, "2026-01-01T00:00:00Z", "web", undefined, D);
  eq([e.access, e.lifetime_only?.code, e.upgrade.link], ["full", "BINGR-ABCD-EFGH", true]);
  const off = fakeDb();
  const e2 = await buildEntitlements(off, UID, null, "web", undefined, D + 400 * DAY);
  eq([e2.access, "lifetime_only" in e2, e2.iap.apple], ["full", false, false], "geen instellingen = zoals nu");
  const broken = { ...off, from: (t: string) => t === "account_plans" ? { select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null, error: { code: "57014" } }) }) }) } : off.from(t) };
  let threw = false;
  try { await buildEntitlements(broken, UID, null, "web", undefined, D); } catch { threw = true; }
  ok(threw, "fout gooit");
});

// ---------------- Stripe ----------------
Deno.test("Stripe: coupon met vaste id, promotion code één keer en tot de einddatum, idempotent", () => {
  eq(couponId(30, CUT), "bingr_lifetime_30_20261130", "UTC-datum van 00:00 Amsterdam");
  const c = Object.fromEntries(couponParams(30, CUT));
  eq([c.id, c.percent_off, c.duration, c.redeem_by], ["bingr_lifetime_30_20261130", "30", "once", String(Date.parse(CUT) / 1000)]);
  const p = Object.fromEntries(promotionParams("bingr_lifetime_30_20261130", "BINGR-ABCD-EFGH", UID, CUT));
  eq([p.coupon, p.code, p.max_redemptions, p.expires_at, p["metadata[user_id]"]], ["bingr_lifetime_30_20261130", "BINGR-ABCD-EFGH", "1", String(Date.parse(CUT) / 1000), UID]);
  eq(promotionIdempotencyKey(UID.toUpperCase(), "BINGR-ABCD-EFGH"), promotionIdempotencyKey(UID, "BINGR-ABCD-EFGH"));
});
Deno.test("checkout: met kortingscode discounts[0][promotion_code] en een eigen idempotency-key; zonder ongewijzigd", () => {
  const base = { userId: UID, email: null, lang: "nl" as const, automaticTax: false, waiverAt: "x" };
  const p = Object.fromEntries(checkoutParams({ ...base, promotionCode: "promo_1" }));
  eq(p["discounts[0][promotion_code]"], "promo_1"); eq(p["metadata[promotion_code]"], "promo_1");
  eq("allow_promotion_codes" in p, false, "zelf intypen bij Stripe kan niet (alleen de eigen code via de server)");
  eq(checkoutParams(base), checkoutParams({ ...base, promotionCode: null }), "zonder code precies zoals nu");
  ok(idempotencyKey(UID, "nl", false, D, "promo_1") !== idempotencyKey(UID, "nl", false, D));
  eq(idempotencyKey(UID, "nl", false, D, null), idempotencyKey(UID, "nl", false, D));
});
Deno.test("webhook: promotion code uit discounts of metadata", () => {
  eq(promotionCodeOf({ discounts: [{ coupon: "c", promotion_code: "promo_9" }] }), "promo_9");
  eq(promotionCodeOf({ discounts: [{ promotion_code: { id: "promo_8" } }] }), "promo_8");
  eq(promotionCodeOf({ discounts: [], metadata: { promotion_code: "promo_7" } }), "promo_7");
  eq(promotionCodeOf({ discounts: [{ promotion_code: "geen" }] }), null);
  eq(promotionCodeOf(null), null);
});
Deno.test("webhook: code gebruikt -> redeemed_at en purchase_id, alleen eigen code, idempotent", async () => {
  const db = fakeDb();
  db.tab("billing_purchases").push({ id: 41, user_id: UID, stripe_session_id: "cs_test_a1", status: "paid" });
  db.tab("lifetime_codes").push({ user_id: UID, code: "BINGR-ABCD-EFGH", stripe_promotion_code_id: "promo_1", redeemed_at: null, purchase_id: null });
  db.tab("lifetime_codes").push({ user_id: UID2, code: "BINGR-HJKM-NPQR", stripe_promotion_code_id: "promo_2", redeemed_at: null, purchase_id: null });
  eq(await markRedeemed(db, UID, "promo_2", "cs_test_a1"), "no_code", "code van een ander account");
  eq(await markRedeemed(db, UID, "promo_1", "cs_test_a1", "2026-11-20T10:00:00.000Z"), "redeemed");
  eq([db.tab("lifetime_codes")[0].redeemed_at, db.tab("lifetime_codes")[0].purchase_id], ["2026-11-20T10:00:00.000Z", 41]);
  eq(await markRedeemed(db, UID, "promo_1", "cs_test_a1", "2026-11-21T10:00:00.000Z"), "already");
  eq(db.tab("lifetime_codes")[0].redeemed_at, "2026-11-20T10:00:00.000Z", "niet overschreven");
  eq(db.tab("lifetime_codes")[1].redeemed_at, null);
});

// ---------------- gastaankoop (aanvulling 1) ----------------
const TOKEN = "A".repeat(43);
const guestSession = (o: Record<string, unknown> = {}) => ({
  id: "cs_test_g1", object: "checkout.session", mode: "payment", client_reference_id: null, metadata: { plan: "lifetime", guest: "1", claim_token: TOKEN },
  payment_intent: "pi_g1", amount_total: 499, currency: "eur", payment_status: "paid", status: "complete", customer_details: { email: "Nieuw@Example.invalid" }, ...o,
});
Deno.test("gast: checkout zonder account, claimtoken in metadata en success-URL", () => {
  const t = newClaimToken();
  ok(isClaimToken(t) && t.length === 43, "32 bytes base64url");
  ok(t !== newClaimToken(), "willekeurig");
  const p = Object.fromEntries(guestCheckoutParams({ lang: "en", automaticTax: false, waiverAt: "x", claimToken: TOKEN }));
  eq(p.success_url, `https://bingr.online/upgrade/klaar/?claim=${TOKEN}&session_id={CHECKOUT_SESSION_ID}`);
  eq([p["metadata[guest]"], p["metadata[claim_token]"], p.customer_creation, p.locale], ["1", TOKEN, "always", "en"]);
  for (const k of ["client_reference_id", "metadata[user_id]", "customer_email"]) eq(k in p, false, k);
  eq(p["line_items[0][price_data][unit_amount]"], "499");
});
Deno.test("gast: events - betaald = guest, onbetaald wachten, kapot token negeren; gewone aankopen ongewijzigd", () => {
  const ev = (type: string, object: unknown) => ({ id: "evt_g", object: "event", type, data: { object } });
  const d = decide(ev("checkout.session.completed", guestSession()));
  eq(d.kind, "guest");
  if (d.kind === "guest") eq([d.purchase.sessionId, d.purchase.claimToken, d.purchase.email, d.purchase.amount], ["cs_test_g1", TOKEN, "Nieuw@Example.invalid", 499]);
  eq(decide(ev("checkout.session.completed", guestSession({ payment_status: "unpaid" }))), { kind: "ignore", reason: "not_paid" });
  eq(decide(ev("checkout.session.async_payment_succeeded", guestSession())).kind, "guest");
  eq(decide(ev("checkout.session.completed", guestSession({ metadata: { guest: "1", claim_token: "kort" } }))), { kind: "ignore", reason: "not_ours" });
  eq(guestFromSession({ ...guestSession(), mode: "subscription" }), null);
});
Deno.test("gast: e-mailhash = sha256 van het kleine-letteradres (gelijk aan bingr_email_hash)", async () => {
  eq(await emailHash(" Nieuw@Example.invalid "), await sha256Hex("nieuw@example.invalid"));
  eq(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "testvector");
});
Deno.test("gast: database - vastleggen zonder account, idempotent, meteen koppelen als het adres bekend is", async () => {
  let claimHash: unknown = null;
  const db = fakeDb({ billing_purchases: ["stripe_session_id", "claim_token_hash"] }, {
    bingr_billing_claim_hash: (a) => { claimHash = a.p_email_hash; return { claimed: 0 }; },
  });
  const ev = decide({ id: "evt_g", object: "event", type: "checkout.session.completed", data: { object: guestSession() } });
  if (ev.kind !== "guest") throw new Error("guest");
  const r = await grantGuest(db, ev.purchase, D);
  eq(r, { inserted: true, claimed: false, revoked: false, mailed: false });
  const row = db.tab("billing_purchases")[0];
  eq([row.user_id, row.status, row.provider], [null, "paid", "stripe"]);
  eq(row.claim_token_hash, await sha256Hex(TOKEN), "alleen de hash van het token");
  eq(row.claim_email_hash, await emailHash("nieuw@example.invalid"));
  eq(claimHash, row.claim_email_hash, "koppelen op het e-mailadres geprobeerd");
  eq(row.claim_expires_at, new Date(D + 30 * DAY).toISOString(), "30 dagen");
  ok(!JSON.stringify(row).includes("@") && !JSON.stringify(row).includes(TOKEN), "geen adres of token in de rij");
  eq((await grantGuest(db, ev.purchase, D)).inserted, false, "tweede keer");
  eq(db.tab("billing_purchases").length, 1);
  row.user_id = UID;
  eq((await grantGuest(db, ev.purchase, D)).claimed, true, "al geclaimd blijft geclaimd");
  eq(db.tab("billing_purchases")[0].user_id, UID);
  row.status = "refunded";
  eq((await grantGuest(db, ev.purchase, D)).revoked, true, "terugbetaald wordt niet opnieuw actief");
});
Deno.test("gast: claimen via de database-functies", async () => {
  let got: Record<string, unknown> = {};
  const db = fakeDb({}, {
    bingr_billing_claim: (a) => { got = a; return { result: "claimed" }; },
    bingr_billing_claim_email: () => ({ claimed: 2 }),
  });
  eq(await claimToken(db, UID, TOKEN), { ok: true, result: "claimed" });
  eq(got, { p_user: UID, p_token_hash: await sha256Hex(TOKEN) }, "alleen de hash gaat naar de database");
  eq(await claimByEmail(db, UID), 2);
  const db2 = fakeDb({}, { bingr_billing_claim: () => ({ result: "owned_by_other_account" }) });
  eq(await claimToken(db2, UID, TOKEN), { ok: false, result: "owned_by_other_account" });
});

// ---------------- mails ----------------
Deno.test("mail Bingr wordt Lifetime: onderwerp, code groot, geldig t/m de dag vóór de overgang, knop, geen Apple", () => {
  for (const lang of ["nl", "en"] as const) {
    const m = renderLifetimeMail({ kind: "notice", lang, code: "BINGR-ABCD-EFGH", validUntil: CUT, cutoverAt: CUT, discountPct: 30, firstName: "Alex", year: 2026 });
    eq(m.subject, lang === "nl" ? "Bingr wordt Lifetime – met 30% korting voor jou" : "Bingr is going Lifetime – 30% off for you");
    for (const part of [m.html, m.text]) {
      ok(part.includes("BINGR-ABCD-EFGH"), "code");
      ok(part.includes("https://bingr.online/upgrade/?code=BINGR-ABCD-EFGH"), "knop met code");
      ok(part.includes(lang === "nl" ? "30 november 2026" : "30 November 2026"), "geldig t/m 30 november");
      ok(part.includes(lang === "nl" ? "1 december 2026" : "1 December 2026"), "overgang 1 december 2026");
      ok(part.includes("support.bingr.online"), "support");
      ok(!/(?<!-)apple(?!-system)|app store/i.test(part), "geen Apple of App Store (het lettertype -apple-system telt niet)");
      ok(!/unsubscribe|afmelden/i.test(part), "dienstmelding: geen afmeldlink");
    }
    ok(m.html.includes(lang === "nl" ? "€ 3,49" : "€3.49") && m.html.includes(lang === "nl" ? "€ 4,99" : "€4.99"), "prijs na korting");
    ok(m.html.includes(lang === "nl" ? "Hoi Alex," : "Hi Alex,"), "aanhef");
    ok(m.html.includes(lang === "nl" ? "één ontwikkelaar" : "single developer") && /reclame|ads/.test(m.html), "waarom");
    ok(m.html.includes(lang === "nl" ? "gegevens blijven bewaard" : "data is kept"), "gegevens bewaard");
  }
  const r = renderLifetimeMail({ kind: "remind", lang: "nl", code: "BINGR-ABCD-EFGH", validUntil: CUT, cutoverAt: CUT, discountPct: 30 });
  ok(r.subject.startsWith("Nog 7 dagen") && !r.html.includes("Hoi "), "herinnering zonder naam");
  const x = renderLifetimeMail({ kind: "notice", lang: "en", code: "<b>", validUntil: CUT, cutoverAt: CUT, discountPct: 30, firstName: "<script>" });
  ok(!x.html.includes("<script>") && !x.html.includes("<b>"), "escapen");
  const t = renderLifetimeMail({ kind: "notice", lang: "nl", code: SAMPLE_CODE, validUntil: CUT, cutoverAt: CUT, discountPct: 30, test: true });
  ok(t.subject.startsWith("[Test] ") && t.html.includes("voorbeeld"), "testmail");
  eq(lastValidDay(DEFAULT_CUTOVER, "nl"), "30 november 2026"); eq(lastValidDay(DEFAULT_CUTOVER, "en"), "30 November 2026");
  eq(upgradeUrl("BINGR-ABCD-EFGH"), "https://bingr.online/upgrade/?code=BINGR-ABCD-EFGH");
});
Deno.test("claimmail na een gastaankoop: link met token, NL en EN, geen Apple", () => {
  for (const lang of ["nl", "en"] as const) {
    const m = renderClaimMail(lang, TOKEN, 2026);
    ok(m.html.includes(claimUrl(TOKEN)) && m.text.includes(claimUrl(TOKEN)), "claimlink");
    ok(m.html.includes("30"), "30 dagen");
    ok(!/(?<!-)apple(?!-system)|app store/i.test(m.html), "geen Apple");
  }
  eq(claimUrl(TOKEN), `https://bingr.online/upgrade/klaar/?claim=${TOKEN}`);
  ok(renderClaimMail("nl", TOKEN).subject.includes("account"));
});
Deno.test("verzenden: herinnering alleen in de 7 dagen vóór de overgang; batchgrootte", () => {
  const cut = Date.parse(CUT);
  eq(remindWindow(CUT, cut - 7 * DAY - 1), false); eq(remindWindow(CUT, cut - 7 * DAY), true);
  eq(remindWindow(CUT, cut - 1), true); eq(remindWindow(CUT, cut), false); eq(remindWindow("kapot", cut), false);
  eq(batchSize(25, 50), 25); eq(batchSize(0, 50), 50); eq(batchSize(500, 50), 50); eq(batchSize("10", 50), 50);
});
