// deno test supabase/functions/_shared/apple_test.ts
// Build 167: JWS van Apple (x5c-keten tot de vertrouwde root, ES256), de controle van een StoreKit 2-transactie, de
// notificaties V2 en de databasestappen (grantApple / revokeApple). Met een zelfgemaakte test-CA (apple_testdata.ts);
// nooit echte transacties. De echte Apple-certificaten (openbaar) worden alleen als keten gecontroleerd.
import { APPLE_ROOT_CA_G3_B64, APPLE_ROOT_CA_G3_SHA256 } from "./apple_root.ts";
import { b64decode, b64urlEncode, derSigToRaw, OID_APPLE_INTERMEDIATE, OID_APPLE_LEAF, parseCert, signedBy, verifyAppleJws } from "./apple_jws.ts";
import { APPLE_BUNDLE_ID, APPLE_PRODUCT_ID, appleEnvironment, checkTransaction, decideNotification, notificationId, priceOf } from "./apple.ts";
import { grantApple, notifyDone, notifySeen, revokeApple } from "./apple_store.ts";
import { fakeDb } from "./testdb.ts";
import {
  APPLE_APPSTORE_LEAF, APPLE_WWDR_G6, TEST_INTER, TEST_INTER_NOOID, TEST_INTER_ROGUE, TEST_LEAF, TEST_LEAF_KEY_PKCS8, TEST_LEAF_NOOID,
  TEST_ROGUE, TEST_ROOT,
} from "./apple_testdata.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
const NOW = Date.parse("2027-03-01T12:00:00Z");
const ROOTS = [b64decode(TEST_ROOT)];
const UID = "0b6f3c1e-2a4d-4e5f-8a9b-1c2d3e4f5a6b", UID2 = "1c7a4d2f-3b5e-4f60-9bac-2d3e4f5a6b7c";

let key: CryptoKey | null = null;
async function sign(payload: unknown, x5c = [TEST_LEAF, TEST_INTER, TEST_ROOT], header: Record<string, unknown> = {}): Promise<string> {
  key ??= await crypto.subtle.importKey("pkcs8", b64decode(TEST_LEAF_KEY_PKCS8) as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const h = b64urlEncode(JSON.stringify({ alg: "ES256", x5c, ...header })), p = b64urlEncode(JSON.stringify(payload));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${h}.${p}`) as BufferSource));
  return `${h}.${p}.${b64urlEncode(sig)}`;
}
const tx = (o: Record<string, unknown> = {}) => ({
  transactionId: "2000000123456789", originalTransactionId: "2000000123456789", bundleId: APPLE_BUNDLE_ID, productId: APPLE_PRODUCT_ID,
  purchaseDate: NOW - 60_000, signedDate: NOW - 30_000, environment: "Sandbox", type: "Non-Consumable", appAccountToken: UID,
  price: 4990, currency: "EUR", ...o,
});

// ---------------- certificaten ----------------
Deno.test("Apple Root CA - G3: vingerafdruk, zelf ondertekend, P-384", async () => {
  const der = b64decode(APPLE_ROOT_CA_G3_B64);
  const fp = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", der as BufferSource)), (b) => b.toString(16).padStart(2, "0")).join("");
  eq(fp, APPLE_ROOT_CA_G3_SHA256);
  eq(fp, "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179", "openbare vingerafdruk van Apple");
  const root = parseCert(der);
  eq(root.curve, "P-384"); ok(root.isCA, "CA");
  ok(await signedBy(root, root), "zelf ondertekend");
  ok(root.notAfter > Date.parse("2039-04-01T00:00:00Z"), "geldig tot 2039");
});
Deno.test("echte Apple-keten (openbare certificaten): WWDR G6 door de root, App Store-leaf door G6, markeringen", async () => {
  const root = parseCert(b64decode(APPLE_ROOT_CA_G3_B64)), g6 = parseCert(b64decode(APPLE_WWDR_G6)), leaf = parseCert(b64decode(APPLE_APPSTORE_LEAF));
  ok(await signedBy(g6, root), "G6 door root");
  ok(await signedBy(leaf, g6), "leaf door G6");
  ok(!(await signedBy(leaf, root)), "leaf niet door root");
  ok(g6.extensions.has(OID_APPLE_INTERMEDIATE) && g6.isCA, "tussencertificaat");
  ok(leaf.extensions.has(OID_APPLE_LEAF) && !leaf.isCA && leaf.curve === "P-256", "leaf");
  ok(!leaf.unknownCritical && !g6.unknownCritical, "geen onbekende kritieke extensies");
});
Deno.test("DER-handtekening naar r||s", () => {
  // SEQUENCE { INTEGER 0x00ff (met voorloopnul), INTEGER 0x01 }
  eq(Array.from(derSigToRaw(new Uint8Array([0x30, 0x07, 0x02, 0x02, 0x00, 0xff, 0x02, 0x01, 0x01]), 2)), [0, 0xff, 0, 1]);
  let threw = false;
  try { derSigToRaw(new Uint8Array([0x30, 0x03, 0x02, 0x01]), 32); } catch { threw = true; }
  ok(threw, "kapotte DER");
});

// ---------------- JWS ----------------
Deno.test("JWS: geldige keten en handtekening", async () => {
  const r = await verifyAppleJws(await sign(tx()), { roots: ROOTS, now: NOW });
  ok(r.ok, JSON.stringify(r));
  if (r.ok) eq(r.payload.transactionId, "2000000123456789");
});
Deno.test("JWS: standaard alleen Apple Root CA - G3 (test-CA niet vertrouwd)", async () => {
  eq(await verifyAppleJws(await sign(tx()), { now: NOW }), { ok: false, error: "untrusted_root" });
});
Deno.test("JWS: vervalste of kapotte invoer", async () => {
  const good = await sign(tx());
  const [h, p, s] = good.split(".");
  const other = b64urlEncode(JSON.stringify(tx({ productId: "iets.anders" })));
  eq((await verifyAppleJws(`${h}.${other}.${s}`, { roots: ROOTS, now: NOW })), { ok: false, error: "bad_signature" }, "payload gewijzigd");
  const flipped = s.slice(0, 10) + (s[10] === "A" ? "B" : "A") + s.slice(11);
  eq((await verifyAppleJws(`${h}.${p}.${flipped}`, { roots: ROOTS, now: NOW })).ok, false, "handtekening gewijzigd");
  eq(await verifyAppleJws("a.b", { roots: ROOTS, now: NOW }), { ok: false, error: "bad_format" });
  eq(await verifyAppleJws(123, { roots: ROOTS, now: NOW }), { ok: false, error: "bad_format" });
  eq(await verifyAppleJws("x".repeat(70_000), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_format" });
  eq(await verifyAppleJws(await sign(tx(), undefined, { alg: "HS256" }), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_alg" });
  eq(await verifyAppleJws(await sign(tx(), undefined, { alg: "none" }), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_alg" });
  eq(await verifyAppleJws(await sign(tx(), [TEST_LEAF, TEST_INTER]), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_header" }, "2 certificaten");
  eq(await verifyAppleJws(await sign(tx(), ["AAAA", TEST_INTER, TEST_ROOT]), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_chain" });
});
Deno.test("JWS: keten - andere root, verkeerde volgorde, zonder Apple-markering", async () => {
  // rogue root met dezelfde naam: niet vertrouwd; en het tussencertificaat van de rogue root onder onze root: handtekening fout
  eq(await verifyAppleJws(await sign(tx(), [TEST_LEAF, TEST_INTER_ROGUE, TEST_ROGUE]), { roots: ROOTS, now: NOW }), { ok: false, error: "untrusted_root" });
  eq(await verifyAppleJws(await sign(tx(), [TEST_LEAF, TEST_INTER_ROGUE, TEST_ROOT]), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_chain" });
  // tegenproef: vertrouw je de rogue root zelf, dan klopt die keten wel (zelfde tussensleutel) - het pinnen doet het werk
  ok((await verifyAppleJws(await sign(tx(), [TEST_LEAF, TEST_INTER_ROGUE, TEST_ROGUE]), { roots: [b64decode(TEST_ROGUE)], now: NOW })).ok, "tegenproef");
  eq(await verifyAppleJws(await sign(tx(), [TEST_INTER, TEST_LEAF, TEST_ROOT]), { roots: ROOTS, now: NOW }), { ok: false, error: "bad_chain" }, "omgedraaid");
  eq(await verifyAppleJws(await sign(tx(), [TEST_LEAF_NOOID, TEST_INTER, TEST_ROOT]), { roots: ROOTS, now: NOW }), { ok: false, error: "not_apple" }, "leaf zonder OID");
  eq(await verifyAppleJws(await sign(tx(), [TEST_LEAF, TEST_INTER_NOOID, TEST_ROOT]), { roots: ROOTS, now: NOW }), { ok: false, error: "not_apple" }, "tussen zonder OID");
});
Deno.test("JWS: tijd - signedDate binnen de geldigheid, niet in de toekomst", async () => {
  eq(await verifyAppleJws(await sign(tx({ signedDate: NOW + 10 * 60_000 })), { roots: ROOTS, now: NOW }), { ok: false, error: "future_date" });
  ok((await verifyAppleJws(await sign(tx({ signedDate: NOW + 60_000 })), { roots: ROOTS, now: NOW })).ok, "klein klokverschil mag");
  eq(await verifyAppleJws(await sign(tx({ signedDate: Date.parse("2020-01-01T00:00:00Z") })), { roots: ROOTS, now: NOW }), { ok: false, error: "cert_expired" }, "vóór de keten");
  // een oude aankoop (herstellen) met een certificaat dat nu verlopen is: telt op het moment van ondertekenen
  ok((await verifyAppleJws(await sign(tx({ signedDate: NOW })), { roots: ROOTS, now: Date.parse("2060-01-01T00:00:00Z") })).ok, "oude JWS, geldig toen ondertekend");
  eq(await verifyAppleJws(await sign(tx({ signedDate: undefined })), { roots: ROOTS, now: Date.parse("2060-01-01T00:00:00Z") }), { ok: false, error: "cert_expired" }, "zonder signedDate: nu");
});

// ---------------- transactie ----------------
Deno.test("transactie: app, product, ingetrokken, prijs, omgeving", () => {
  const c = checkTransaction(tx());
  ok(c.ok);
  if (c.ok) eq(c.tx, { transactionId: "2000000123456789", originalTransactionId: "2000000123456789", environment: "test", amount: 499, currency: "eur",
    purchasedAt: new Date(NOW - 60_000).toISOString(), appAccountToken: UID });
  eq(checkTransaction(tx({ bundleId: "nl.anders" })), { ok: false, error: "wrong_app" });
  eq(checkTransaction(tx({ productId: "nl.lrvdlinden.bingr.iets" })), { ok: false, error: "wrong_product" });
  eq(checkTransaction(tx({ revocationDate: NOW })), { ok: false, error: "revoked" });
  eq(checkTransaction(tx({ transactionId: "abc" })), { ok: false, error: "bad_transaction" });
  eq(checkTransaction(null), { ok: false, error: "bad_transaction" });
  eq(appleEnvironment("Production"), "live"); eq(appleEnvironment("Sandbox"), "test"); eq(appleEnvironment("Xcode"), "test");
  eq(priceOf({ price: 3490, currency: "usd" }), { amount: 349, currency: "usd" });
  eq(priceOf({ currency: "EUR" }), { amount: null, currency: null }, "geen prijs");
});
Deno.test("aanvulling 1: appAccountToken hoeft niet de account-id te zijn (kopen vóór het account)", () => {
  const c = checkTransaction(tx({ appAccountToken: UID2 }));
  ok(c.ok && c.tx.appAccountToken === UID2);
  const n = checkTransaction(tx({ appAccountToken: undefined }));
  ok(n.ok && n.tx.appAccountToken === null, "zonder token mag ook");
});

// ---------------- notificaties ----------------
Deno.test("notificaties: REFUND/REVOKE intrekken, TEST, andere app of type negeren", () => {
  const n = (type: string, data: Record<string, unknown> | null = { bundleId: APPLE_BUNDLE_ID, signedTransactionInfo: "x.y.z" }) =>
    ({ notificationType: type, notificationUUID: "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d", data });
  eq(decideNotification(n("REFUND")), { kind: "revoke", type: "REFUND", signedTransaction: "x.y.z" });
  eq(decideNotification(n("REVOKE")).kind, "revoke");
  eq(decideNotification(n("TEST", null)), { kind: "test", type: "TEST" });
  eq(decideNotification(n("CONSUMPTION_REQUEST")), { kind: "ignore", type: "CONSUMPTION_REQUEST", reason: "other_type" });
  eq(decideNotification(n("REFUND", { bundleId: "nl.anders", signedTransactionInfo: "x" })).kind, "ignore");
  eq(decideNotification(n("REFUND", { bundleId: APPLE_BUNDLE_ID })), { kind: "ignore", type: "REFUND", reason: "no_transaction" });
  eq(notificationId(n("REFUND")), "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d");
  eq(notificationId({ notificationUUID: "kapot" }), null);
});
Deno.test("notificatie end-to-end: buitenste en binnenste JWS met de test-CA", async () => {
  const inner = await sign(tx({ revocationDate: NOW, revocationReason: 0 }));
  const outer = await sign({ notificationType: "REFUND", notificationUUID: "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d", signedDate: NOW - 1000,
    data: { bundleId: APPLE_BUNDLE_ID, environment: "Sandbox", signedTransactionInfo: inner } });
  const v = await verifyAppleJws(outer, { roots: ROOTS, now: NOW });
  ok(v.ok);
  const d = v.ok ? decideNotification(v.payload) : null;
  ok(d?.kind === "revoke");
  const t = d?.kind === "revoke" ? await verifyAppleJws(d.signedTransaction, { roots: ROOTS, now: NOW }) : null;
  ok(t?.ok);
  eq(t?.ok ? checkTransaction(t.payload) : null, { ok: false, error: "revoked" }, "ingetrokken = de bedoeling bij REFUND");
});

// ---------------- database ----------------
const UNIQUE = { billing_purchases: ["apple_original_transaction_id", "stripe_session_id"] };
const appleTx = (o: Record<string, unknown> = {}) => {
  const c = checkTransaction(tx(o));
  if (!c.ok) throw new Error("testtransactie");
  return c.tx;
};
Deno.test("database: Apple-aankoop -> Lifetime (apple), idempotent, eigen limieten blijven", async () => {
  const db = fakeDb(UNIQUE);
  db.tab("account_plans").push({ user_id: UID, plan: "free", max_streams: 4, max_devices: null, source: null });
  eq(await grantApple(db, UID, appleTx()), { ok: true, granted: true, already: false });
  eq(await grantApple(db, UID, appleTx()), { ok: true, granted: false, already: true }, "tweede keer");
  eq(db.tab("billing_purchases").length, 1);
  const p = db.tab("billing_purchases")[0];
  eq([p.provider, p.environment, p.amount, p.currency, p.status, p.user_id], ["apple", "test", 499, "eur", "paid", UID]);
  const plan = db.tab("account_plans")[0];
  eq([plan.plan, plan.source, plan.granted_by, plan.max_streams], ["lifetime", "purchase", "apple", 4]);
});
Deno.test("database: transactie van een ander account -> owned_by_other_account (wie het eerst claimt)", async () => {
  const db = fakeDb(UNIQUE);
  // aanvulling 1: gekocht met een willekeurige UUID vóór het account bestond; het eerste account dat claimt krijgt hem
  eq((await grantApple(db, UID2, appleTx({ appAccountToken: "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a" }))).ok, true);
  eq(await grantApple(db, UID, appleTx()), { ok: false, error: "owned_by_other_account" });
  eq(db.tab("billing_purchases")[0].user_id, UID2, "nooit overschreven");
  // account verwijderd (user_id null): niet opnieuw te claimen
  db.tab("billing_purchases")[0].user_id = null;
  eq(await grantApple(db, UID, appleTx()), { ok: false, error: "owned_by_other_account" });
});
Deno.test("database: tegelijk geclaimd (unieke sleutel) -> de tweede krijgt owned_by_other_account", async () => {
  const db = fakeDb(UNIQUE);
  // de rij verschijnt tussen het lezen en het invoegen: insert geeft 23505, daarna opnieuw lezen
  const realFrom = db.from;
  let first = true;
  (db as { from: typeof realFrom }).from = (table: string) => {
    const b = realFrom(table);
    if (table === "billing_purchases" && first) {
      first = false;
      db.tab("billing_purchases").push({ id: 99, user_id: UID2, apple_original_transaction_id: "2000000123456789", status: "paid", amount: 499 });
      return realFrom(table);
    }
    return b;
  };
  eq(await grantApple(db, UID, appleTx()), { ok: false, error: "owned_by_other_account" });
});
Deno.test("database: Lifetime uit het beheer blijft; terugbetaald = niet opnieuw actief", async () => {
  const db = fakeDb(UNIQUE);
  db.tab("account_plans").push({ user_id: UID, plan: "lifetime", source: "admin" });
  eq(await grantApple(db, UID, appleTx()), { ok: true, granted: false, already: true });
  eq(db.tab("account_plans")[0].source, "admin");
  eq(await revokeApple(db, { originalTransactionId: "2000000123456789", transactionId: "2000000123456789" }), { found: true, downgraded: false, reason: "not_purchase" });
  eq(db.tab("billing_purchases")[0].status, "refunded");
  eq(await grantApple(db, UID, appleTx()), { ok: false, error: "revoked" });
});
Deno.test("database: REFUND -> Gratis, rij in billing_refunds (apl_), idempotent; onbekende aankoop", async () => {
  const db = fakeDb(UNIQUE);
  await grantApple(db, UID, appleTx());
  const t = { originalTransactionId: "2000000123456789", transactionId: "2000000123456789" };
  eq(await revokeApple(db, t), { found: true, downgraded: true });
  eq(db.tab("account_plans").length, 0, "zonder eigen limieten: rij weg = Gratis");
  eq(await revokeApple(db, t), { found: true, downgraded: false, reason: "not_lifetime" }, "tweede keer");
  eq(db.tab("billing_refunds").map((r) => [r.id, r.amount, r.kind]), [["apl_2000000123456789", 499, "refund"]]);
  eq(await revokeApple(db, { originalTransactionId: "1", transactionId: "1" }), { found: false, downgraded: false });
  eq(await notifySeen(db, "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d"), false);
  await notifyDone(db, "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d", "REFUND", "refunded_free");
  eq(await notifySeen(db, "7b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d"), true);
});
