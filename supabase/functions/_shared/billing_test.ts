// deno test supabase/functions/_shared/billing_test.ts
// Betalen (build 133): handtekening van Stripe, Checkout-opbouw, events -> beslissing, en de databasestappen (grant,
// pending, revoke, idempotentie) tegen een kleine nep-database in het geheugen.
import {
  billingConfig, CANCEL_URL, checkoutParams, decide, detailsFromCharge, detailsFromPaymentIntent, disputeRow, formatAmount, formEncode,
  grantRow, idempotencyKey, parseSignature, purchaseFromSession, purchaseView, refundFallback, refundRows, revokeAction, signHeader,
  SUCCESS_URL, verifySignature, WEBHOOK_EVENTS,
} from "./billing.ts";
import { eventDone, eventSeen, failed, grant, needsDetails, pending, recordRefunds, revoke, saveDetails } from "./billing_store.ts";
import { PRICE_CENTS } from "./plans.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
const UID = "0b6f3c1e-2a4d-4e5f-8a9b-1c2d3e4f5a6b";
const NOW = Date.parse("2026-10-19T12:00:00Z");

// ---------------- handtekening ----------------
Deno.test("handtekening: geldig, verlopen, fout secret, gewijzigde body", async () => {
  const body = '{"id":"evt_1","object":"event"}', secret = "whsec_test_123";
  const t = Math.floor(NOW / 1000);
  const h = await signHeader(body, secret, t);
  eq(await verifySignature(body, h, secret, NOW), "ok");
  eq(await verifySignature(body, h, secret, NOW + 299_000), "ok", "net binnen 5 min");
  eq(await verifySignature(body, h, secret, NOW + 301_000), "too_old", "te oud");
  eq(await verifySignature(body, h, secret, NOW - 301_000), "too_old", "uit de toekomst");
  eq(await verifySignature(body, h, "whsec_ander", NOW), "mismatch");
  eq(await verifySignature(body + " ", h, secret, NOW), "mismatch", "body gewijzigd");
  eq(await verifySignature(body, h, "", NOW), "no_secret");
  eq(await verifySignature(body, null, secret, NOW), "bad_header");
  eq(await verifySignature(body, "t=abc,v1=00", secret, NOW), "bad_header");
});
Deno.test("handtekening: meerdere v1 (secret wisselen) en v0 genegeerd", async () => {
  const body = "{}", t = Math.floor(NOW / 1000);
  const good = (await signHeader(body, "whsec_nieuw", t)).split("v1=")[1];
  const h = `t=${t},v0=${"a".repeat(64)},v1=${"0".repeat(64)},v1=${good}`;
  eq(await verifySignature(body, h, "whsec_nieuw", NOW), "ok");
  eq(parseSignature(h)?.v1.length, 2);
});
Deno.test("handtekening: bekende testvector (HMAC-SHA256)", async () => {
  // RFC 4231, testgeval 2: key "Jefe", data "what do ya want for nothing?"
  const { hmacHex } = await import("./billing.ts");
  eq(await hmacHex("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
});

// ---------------- configuratie ----------------
Deno.test("configuratie: sleutel, testmodus, automatic tax", () => {
  const c = (o: Record<string, string>) => billingConfig((k) => o[k]);
  eq(c({}).secretKey, "");
  eq(c({}).mode, null);
  eq(c({ STRIPE_SECRET_KEY: "sk_test_abc123" }).mode, "test");
  eq(c({ STRIPE_SECRET_KEY: "sk_live_abc123" }).mode, "live");
  eq(c({ STRIPE_SECRET_KEY: "rk_live_abc123" }).mode, "live", "restricted key");
  eq(c({ STRIPE_SECRET_KEY: "pk_test_abc" }).secretKey, "", "publishable key telt niet");
  eq(c({ STRIPE_SECRET_KEY: " sk_test_abc \n" }).secretKey, "sk_test_abc");
  eq(c({ STRIPE_AUTOMATIC_TAX: "true" }).automaticTax, true);
  eq(c({ STRIPE_AUTOMATIC_TAX: "false" }).automaticTax, false);
  eq(c({}).automaticTax, false);
});

// ---------------- checkout ----------------
Deno.test("checkout: betaling, prijs uit plans.ts, account, urls, kwitantie", () => {
  const p = Object.fromEntries(checkoutParams({ userId: UID, email: "a@b.nl", lang: "nl", automaticTax: false, waiverAt: "2026-10-19T12:00:00.000Z" }));
  eq(p["mode"], "payment");
  eq(p["line_items[0][price_data][currency]"], "eur");
  eq(p["line_items[0][price_data][unit_amount]"], String(PRICE_CENTS));
  eq(PRICE_CENTS, 499);
  eq(p["line_items[0][price_data][product_data][name]"], "Bingr Lifetime");
  eq(p["line_items[0][quantity]"], "1");
  eq(p["client_reference_id"], UID);
  eq(p["metadata[user_id]"], UID);
  eq(p["metadata[plan]"], "lifetime");
  eq(p["metadata[withdrawal_waiver_at]"], "2026-10-19T12:00:00.000Z");
  eq(p["payment_intent_data[metadata][user_id]"], UID);
  eq(p["payment_intent_data[statement_descriptor_suffix]"], "BINGR");
  eq(p["customer_email"], "a@b.nl");
  eq(p["locale"], "nl");
  eq(p["success_url"], "https://bingr.online/upgrade/?status=success&session_id={CHECKOUT_SESSION_ID}");
  eq(SUCCESS_URL, p["success_url"]);
  eq(p["cancel_url"], "https://bingr.online/upgrade/?status=cancel");
  eq(CANCEL_URL, p["cancel_url"]);
  eq(p["invoice_creation[enabled]"], "true");
  ok(p["invoice_creation[invoice_data][footer]"].includes("PixelForges") && p["invoice_creation[invoice_data][footer]"].includes("70031576"), "verkoper op de factuur");
  ok(p["custom_text[submit][message]"].includes("herroepingsrecht"), "afstand herroepingsrecht");
  ok(p["custom_text[submit][message]"].length <= 1200, "custom_text max 1200");
  eq(p["automatic_tax[enabled]"], undefined, "geen automatic tax");
  eq("payment_method_types[0]" in p, false, "betaalmethoden uit het dashboard");
  eq(p["line_items[0][price_data][product_data][description]"].length <= 300, true);
});
Deno.test("checkout: Engels, zonder e-mail, met automatic tax (prijs incl. btw)", () => {
  const p = Object.fromEntries(checkoutParams({ userId: UID, email: null, lang: "en", automaticTax: true, waiverAt: "x" }));
  eq(p["locale"], "en");
  eq("customer_email" in p, false);
  eq(p["automatic_tax[enabled]"], "true");
  eq(p["line_items[0][price_data][tax_behavior]"], "inclusive");
  eq(p["line_items[0][price_data][product_data][tax_code]"], "txcd_10000000");
  ok(p["custom_text[submit][message]"].includes("withdrawal"));
});
Deno.test("checkout: form-encoding en idempotency-key", () => {
  eq(formEncode([["a[b]", "x y"], ["c", "{CHECKOUT_SESSION_ID}&"]]), "a%5Bb%5D=x%20y&c=%7BCHECKOUT_SESSION_ID%7D%26");
  const k1 = idempotencyKey(UID.toUpperCase(), "nl", false, NOW), k2 = idempotencyKey(UID, "nl", false, NOW + 30_000);
  eq(k1, k2, "binnen dezelfde minuut");
  ok(k1 !== idempotencyKey(UID, "nl", false, NOW + 60_000), "volgende minuut nieuw");
  ok(k1 !== idempotencyKey(UID, "en", false, NOW), "andere taal nieuw (andere parameters)");
  ok(k1.length <= 255);
});

// ---------------- events ----------------
const session = (o: Record<string, unknown> = {}) => ({
  id: "cs_test_a1", object: "checkout.session", mode: "payment", client_reference_id: UID, metadata: { user_id: UID, plan: "lifetime" },
  payment_intent: "pi_123", amount_total: 499, currency: "eur", payment_status: "paid", status: "complete", ...o,
});
const ev = (type: string, object: unknown, id = "evt_1") => ({ id, object: "event", type, data: { object } });
Deno.test("events: betaald -> grant, onbetaald -> pending, mislukt -> failed", () => {
  const g = decide(ev("checkout.session.completed", session()));
  eq(g.kind, "grant");
  if (g.kind === "grant") eq(g.purchase, { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur", taxAmount: null });
  eq(decide(ev("checkout.session.completed", session({ payment_status: "unpaid" }))).kind, "pending");
  eq(decide(ev("checkout.session.async_payment_succeeded", session())).kind, "grant");
  eq(decide(ev("checkout.session.async_payment_succeeded", session({ payment_status: "unpaid" }))).kind, "ignore");
  eq(decide(ev("checkout.session.async_payment_failed", session({ payment_status: "unpaid" }))), { kind: "failed", sessionId: "cs_test_a1" });
});
Deno.test("events: niet van ons, kapot of ander type -> negeren", () => {
  eq(decide(ev("checkout.session.completed", session({ client_reference_id: null, metadata: {} }))), { kind: "ignore", reason: "not_ours" });
  eq(decide(ev("checkout.session.completed", session({ metadata: { user_id: UID, plan: "pro" } }))).kind, "ignore");
  eq(decide(ev("checkout.session.completed", session({ mode: "subscription" }))).kind, "ignore");
  eq(decide(ev("checkout.session.completed", session({ client_reference_id: "geen-uuid", metadata: {} }))).kind, "ignore");
  eq(decide(ev("customer.created", {})), { kind: "ignore", reason: "other_event" });
  eq(decide(null).kind, "ignore");
  eq(decide({ id: "x", object: "event" }), { kind: "ignore", reason: "bad_event" });
  // id uit metadata als client_reference_id ontbreekt; payment_intent als object
  const p = purchaseFromSession(session({ client_reference_id: null, payment_intent: { id: "pi_9" } }));
  eq(p?.userId, UID); eq(p?.paymentIntent, "pi_9");
});
Deno.test("events: terugbetaling (volledig en gedeeltelijk), chargeback met kosten, charge.updated", () => {
  eq(decide(ev("charge.refunded", { object: "charge", id: "ch_1", refunded: true, amount: 499, amount_refunded: 499, payment_intent: "pi_123" })),
    { kind: "refund", paymentIntent: "pi_123", chargeId: "ch_1", amountRefunded: 499, full: true });
  const f = decide(ev("charge.refunded", { object: "charge", id: "ch_1", refunded: false, amount: 499, amount_refunded: 499, payment_intent: "pi_123" }));
  eq(f.kind === "refund" && f.full, true, "bedrag volledig");
  eq(decide(ev("charge.refunded", { object: "charge", id: "ch_1", refunded: false, amount: 499, amount_refunded: 200, payment_intent: { id: "pi_123" } })),
    { kind: "refund", paymentIntent: "pi_123", chargeId: "ch_1", amountRefunded: 200, full: false });
  eq(decide(ev("charge.refunded", { object: "charge", amount: 499, amount_refunded: 499 })), { kind: "ignore", reason: "no_payment_intent" });
  eq(decide(ev("charge.dispute.created", { object: "dispute", id: "dp_1", amount: 499, created: 1760000000, payment_intent: "pi_123",
    balance_transactions: [{ fee: 1500 }, { fee: 0 }] })),
    { kind: "revoke", paymentIntent: "pi_123", status: "disputed", dispute: { id: "dp_1", kind: "dispute", amount: 499, fee: 1500, at: new Date(1760000000 * 1000).toISOString() } });
  eq(decide(ev("charge.dispute.created", { object: "dispute", payment_intent: "pi_123" })), { kind: "revoke", paymentIntent: "pi_123", status: "disputed" }, "zonder id/bedrag");
  eq(decide(ev("charge.dispute.created", { object: "dispute", payment_intent: null })).kind, "ignore");
  eq(decide(ev("charge.updated", { object: "charge", balance_transaction: "txn_1", payment_intent: "pi_123" })), { kind: "details", paymentIntent: "pi_123" });
  eq(decide(ev("charge.updated", { object: "charge", balance_transaction: null, payment_intent: "pi_123" })), { kind: "ignore", reason: "no_balance" });
  eq(WEBHOOK_EVENTS.length, 6);
  ok((WEBHOOK_EVENTS as readonly string[]).includes("charge.updated"));
});
Deno.test("omzet: btw van Stripe Tax alleen met automatic_tax", () => {
  eq(purchaseFromSession(session({ automatic_tax: { enabled: true }, total_details: { amount_tax: 87 } }))?.taxAmount, 87);
  eq(purchaseFromSession(session({ automatic_tax: { enabled: true }, total_details: { amount_tax: 0 } }))?.taxAmount, 0, "verlegd/buiten de EU");
  eq(purchaseFromSession(session({ automatic_tax: { enabled: false }, total_details: { amount_tax: 0 } }))?.taxAmount, null);
  eq(purchaseFromSession(session())?.taxAmount, null);
});
Deno.test("omzet: kosten, netto, betaalmethode en land uit de charge", () => {
  const card = { object: "charge", id: "ch_1", balance_transaction: { fee: 40, net: 459 }, billing_details: { address: { country: "nl" } },
    payment_method_details: { type: "card", card: { country: "DE", wallet: null } } };
  eq(detailsFromCharge(card), { chargeId: "ch_1", fee: 40, net: 459, method: "card", country: "NL" }, "factuuradres voor kaartland");
  eq(detailsFromCharge({ ...card, billing_details: {}, payment_method_details: { type: "card", card: { country: "BE", wallet: { type: "apple_pay" } } } }),
    { chargeId: "ch_1", fee: 40, net: 459, method: "apple_pay", country: "BE" }, "Apple Pay");
  eq(detailsFromCharge({ object: "charge", id: "py_2", balance_transaction: "txn_1", payment_method_details: { type: "ideal", ideal: { bank: "ing" } } }),
    { chargeId: "py_2", fee: null, net: null, method: "ideal", country: null }, "balance transaction nog niet uitgeklapt");
  eq(detailsFromCharge({ object: "charge", payment_method_details: { type: "Bad Type!" }, billing_details: { address: { country: "Nederland" } } }),
    { chargeId: null, fee: null, net: null, method: null, country: null });
  eq(detailsFromCharge(null), null);
  eq(detailsFromPaymentIntent({ object: "payment_intent", latest_charge: card })?.fee, 40);
  eq(detailsFromPaymentIntent({ object: "payment_intent", latest_charge: "ch_1" }), null, "niet uitgeklapt");
});
Deno.test("omzet: terugbetalingen uit de Stripe-lijst, zonder sleutel per charge", () => {
  const rows = refundRows({ data: [
    { object: "refund", id: "re_1", amount: 200, status: "succeeded", created: 1760000000 },
    { object: "refund", id: "re_2", amount: 100, status: "failed", created: 1760000001 },
    { object: "refund", id: "re_3", amount: 50, status: "pending" },
    { object: "refund", id: "xx_4", amount: 50, status: "succeeded" },
  ] }, "NU");
  eq(rows, [{ id: "re_1", kind: "refund", amount: 200, fee: 0, at: new Date(1760000000 * 1000).toISOString() }, { id: "re_3", kind: "refund", amount: 50, fee: 0, at: "NU" }]);
  eq(refundRows(null, "NU"), []);
  eq(refundFallback("ch_1", 499, "NU"), { id: "ch_1", kind: "refund", amount: 499, fee: 0, at: "NU" });
  eq(disputeRow({ object: "dispute", id: "du_1", amount: 499 }, undefined, "NU"), { id: "du_1", kind: "dispute", amount: 499, fee: 0, at: "NU" });
  eq(disputeRow({ object: "dispute", id: "dp_1" }), null, "geen bedrag");
});

// ---------------- account_plans ----------------
Deno.test("grant: Lifetime, bron purchase, eigen limieten blijven, geen persoonsgegevens in de notitie", () => {
  const p = { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur", taxAmount: null };
  const r = grantRow({ plan: "free", max_streams: 4, max_devices: null }, p, "T");
  eq(r, { user_id: UID, plan: "lifetime", source: "purchase", granted_by: "stripe", updated_at: "T", max_streams: 4, max_devices: null, note: "Stripe cs_test_a1 / pi_123" });
  eq(grantRow(null, { ...p, paymentIntent: null }, "T").note, "Stripe cs_test_a1 / -");
});
Deno.test("revoke: alleen gekochte Lifetime terug naar Gratis", () => {
  eq(revokeAction(null, "refunded", "pi_1", "T"), { kind: "keep", reason: "not_lifetime" });
  eq(revokeAction({ plan: "lifetime", source: "admin" }, "refunded", "pi_1", "T"), { kind: "keep", reason: "not_purchase" });
  eq(revokeAction({ plan: "lifetime", source: "legacy" }, "disputed", "pi_1", "T"), { kind: "keep", reason: "not_purchase" });
  eq(revokeAction({ plan: "lifetime", source: "purchase" }, "refunded", "pi_1", "T"), { kind: "delete" });
  eq(revokeAction({ plan: "lifetime", source: "purchase" }, "refunded", "pi_1", "T", true), { kind: "keep", reason: "other_purchase" });
  eq(revokeAction({ plan: "lifetime", source: "purchase", max_devices: 30 }, "disputed", "pi_1", "T"),
    { kind: "update", row: { plan: "free", source: null, granted_by: "stripe", updated_at: "T", note: "Chargeback: pi_1" } });
});
Deno.test("weergave: alleen Stripe-links en bedragen", () => {
  const v = purchaseView({ created_at: "c", amount: 499, currency: "eur", status: "paid" },
    { receipt_url: "https://pay.stripe.com/receipts/x", invoice_url: "javascript:alert(1)", invoice_pdf: "https://evil.example/stripe.com/" });
  eq(v.receipt_url, "https://pay.stripe.com/receipts/x"); eq(v.invoice_url, null); eq(v.invoice_pdf, null);
  eq(formatAmount(499, "eur", "nl"), "€ 4,99"); eq(formatAmount(499, "eur", "en"), "€4.99"); eq(formatAmount(1000, "usd", "en"), "USD 10.00");
});

// ---------------- databasestappen (nep-database) ----------------
type Row = Record<string, unknown>;
function fakeDb(users?: Set<string>) {
  // users: bestaande accounts (foreign key naar auth.users); zonder = alles bestaat
  const fk = (o: Row) => !!users && o.user_id !== null && o.user_id !== undefined && !users.has(String(o.user_id));
  const t: Record<string, Row[]> = { billing_purchases: [], account_plans: [], billing_events: [], billing_refunds: [] };
  const keyOf: Record<string, string> = { billing_purchases: "stripe_session_id", account_plans: "user_id", billing_events: "id", billing_refunds: "id" };
  let seq = 1;
  function q(table: string) {
    const f: [string, string, unknown][] = [];
    let op: "select" | "update" | "delete" = "select", patch: Row = {}, lim = 1e9;
    const like = (p: string) => new RegExp("^" + p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*").replace(/_/g, ".") + "$");
    const rows = () => t[table].filter((r) => f.every(([k, how, v]) => how === "in" ? (v as unknown[]).includes(r[k])
      : how === "like" ? like(String(v)).test(String(r[k])) : r[k] === v));
    const run = () => {
      if (op === "update") { for (const r of rows()) Object.assign(r, Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined))); return { data: null, error: null }; }
      if (op === "delete") { const del = new Set(rows()); t[table] = t[table].filter((r) => !del.has(r)); return { data: null, error: null }; }
      return { data: rows().slice(0, lim).map((r) => ({ ...r })), error: null };
    };
    const b = {
      select: () => b, order: () => b,
      eq: (k: string, v: unknown) => { f.push([k, "eq", v]); return b; },
      in: (k: string, v: unknown[]) => { f.push([k, "in", v]); return b; },
      like: (k: string, v: string) => { f.push([k, "like", v]); return b; },
      limit: (n: number) => { lim = n; return b; },
      update: (p: Row) => { op = "update"; patch = p; return b; },
      delete: () => { op = "delete"; return b; },
      maybeSingle: () => Promise.resolve({ data: (run().data as Row[])[0] ?? null, error: null }),
      then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => Promise.resolve(run()).then(res, rej),
      upsert: (o: Row, opts?: { ignoreDuplicates?: boolean }) => {
        if (table === "billing_purchases" && fk(o)) return Promise.resolve({ data: null, error: { code: "23503" } });
        const k = keyOf[table], cur = t[table].find((r) => r[k] === o[k]);
        const clean = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
        if (cur) { if (!opts?.ignoreDuplicates) Object.assign(cur, clean); } else t[table].push({ id: seq++, ...clean });
        return Promise.resolve({ data: null, error: null });
      },
      insert: (o: Row) => {
        if (table === "billing_purchases" && fk(o)) return Promise.resolve({ data: null, error: { code: "23503" } });
        const k = keyOf[table];
        if (t[table].some((r) => r[k] === o[k])) return Promise.resolve({ data: null, error: { code: "23505" } });
        t[table].push({ id: seq++, ...o }); return Promise.resolve({ data: null, error: null });
      },
    };
    return b;
  }
  return { t, from: q };
}
const purchase = { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur", taxAmount: null };
Deno.test("database: grant twee keer = één aankoop, Lifetime, eigen limieten blijven", async () => {
  const db = fakeDb();
  db.t.account_plans.push({ user_id: UID, plan: "free", max_streams: 4, max_devices: null, source: "admin" });
  eq(await grant(db, purchase, "T1"), { granted: true, already: false });
  eq(await grant(db, purchase, "T2"), { granted: false, already: true }, "tweede keer (webhook + vangnet)");
  eq(db.t.billing_purchases.length, 1);
  eq(db.t.billing_purchases[0].status, "paid");
  eq(db.t.billing_purchases[0].paid_at, "T1", "betaaldatum van de eerste keer");
  const plan = db.t.account_plans[0];
  eq([plan.plan, plan.source, plan.max_streams], ["lifetime", "purchase", 4]);
});
Deno.test("database: pending -> paid; failed alleen vanaf pending", async () => {
  const db = fakeDb();
  await pending(db, purchase, "T0");
  await pending(db, purchase, "T0");
  eq(db.t.billing_purchases.length, 1); eq(db.t.billing_purchases[0].status, "pending");
  eq(db.t.account_plans.length, 0, "nog geen Lifetime");
  await grant(db, purchase, "T1");
  eq(db.t.billing_purchases[0].status, "paid");
  await failed(db, purchase.sessionId);
  eq(db.t.billing_purchases[0].status, "paid", "betaald blijft betaald");
  await pending(db, purchase, "T2");
  eq(db.t.billing_purchases[0].status, "paid", "laat completed-event verandert niets");
});
Deno.test("database: terugbetaling -> Gratis; daarna geen nieuwe Lifetime door een herhaald event", async () => {
  const db = fakeDb();
  await grant(db, purchase, "T1");
  eq(await revoke(db, "pi_123", "refunded", "T2"), { found: true, downgraded: true });
  eq(db.t.account_plans.length, 0, "rij weg (geen eigen limieten)");
  eq(db.t.billing_purchases[0].status, "refunded");
  eq(await grant(db, purchase, "T3"), { granted: false, already: false });
  eq(db.t.account_plans.length, 0, "blijft Gratis");
  eq(await revoke(db, "pi_onbekend", "disputed"), { found: false, downgraded: false });
});
Deno.test("database: chargeback met eigen limieten -> rij Gratis; Lifetime uit het beheer blijft", async () => {
  const db = fakeDb();
  db.t.account_plans.push({ user_id: UID, plan: "free", max_streams: null, max_devices: 30, source: null });
  await grant(db, purchase, "T1");
  eq((await revoke(db, "pi_123", "disputed", "T2")).downgraded, true);
  eq([db.t.account_plans[0].plan, db.t.account_plans[0].max_devices, db.t.account_plans[0].source], ["free", 30, null]);
  const db2 = fakeDb();
  db2.t.billing_purchases.push({ id: 1, user_id: UID, stripe_session_id: "cs_x", payment_intent: "pi_7", status: "paid" });
  db2.t.account_plans.push({ user_id: UID, plan: "lifetime", source: "admin" });
  eq(await revoke(db2, "pi_7", "refunded"), { found: true, downgraded: false, reason: "not_purchase" });
  eq(db2.t.account_plans[0].plan, "lifetime");
});
Deno.test("database: account verwijderd - aankoop blijft zonder account, late events geven of nemen geen Lifetime", async () => {
  // aankoop bestond al; account daarna verwijderd (user_id null via de trigger)
  const db = fakeDb(new Set());
  db.t.billing_purchases.push({ id: 1, user_id: null, user_deleted_at: "T0", stripe_session_id: "cs_test_a1", payment_intent: "pi_123", amount: 499, status: "pending" });
  eq(await grant(db, purchase, "T1"), { granted: false, already: false, deleted: true });
  eq([db.t.billing_purchases[0].status, db.t.billing_purchases[0].paid_at, db.t.billing_purchases[0].user_id], ["paid", "T1", null]);
  eq(db.t.account_plans.length, 0, "geen Lifetime voor een verwijderd account");
  eq(await revoke(db, "pi_123", "refunded", "T2"), { found: true, downgraded: false, reason: "account_deleted" });
  eq(db.t.billing_purchases[0].status, "refunded");
  // nieuwe aankoop van een account dat al weg is (foreign key): vastgelegd zonder account
  const db2 = fakeDb(new Set());
  await pending(db2, purchase, "T0");
  eq([db2.t.billing_purchases.length, db2.t.billing_purchases[0].user_id, db2.t.billing_purchases[0].user_deleted_at], [1, null, "T0"]);
  const db3 = fakeDb(new Set());
  eq(await grant(db3, purchase, "T1"), { granted: false, already: false, deleted: true });
  eq([db3.t.billing_purchases[0].status, db3.t.billing_purchases[0].user_id, db3.t.billing_purchases[0].paid_at], ["paid", null, "T1"]);
  eq(db3.t.account_plans.length, 0);
  // bestaand account: gewoon Lifetime
  const db4 = fakeDb(new Set([UID]));
  eq(await grant(db4, purchase, "T1"), { granted: true, already: false });
});
Deno.test("database: event één keer", async () => {
  const db = fakeDb();
  eq(await eventSeen(db, "evt_1"), false);
  await eventDone(db, "evt_1", "checkout.session.completed", "granted");
  await eventDone(db, "evt_1", "checkout.session.completed", "already");
  eq(await eventSeen(db, "evt_1"), true);
  eq(db.t.billing_events.length, 1); eq(db.t.billing_events[0].result, "granted");
});

Deno.test("database: omzet - btw van Stripe Tax, kosten later aanvullen", async () => {
  const db = fakeDb();
  await grant(db, { ...purchase, taxAmount: 87 }, "T1");
  eq(db.t.billing_purchases[0].tax_amount, 87);
  await grant(db, purchase, "T2");
  eq(db.t.billing_purchases[0].tax_amount, 87, "onbekend overschrijft niets");
  eq(await needsDetails(db, "pi_123"), true);
  eq(await needsDetails(db, "pi_x"), null);
  eq(await saveDetails(db, "pi_123", { chargeId: "ch_1", fee: null, net: null, method: "ideal", country: null }, "T3"), false);
  eq([db.t.billing_purchases[0].payment_method, db.t.billing_purchases[0].fee], ["ideal", undefined]);
  eq(await saveDetails(db, "pi_123", { chargeId: "ch_1", fee: 39, net: 460, method: null, country: "NL" }, "T4"), true);
  const b = db.t.billing_purchases[0];
  eq([b.charge_id, b.fee, b.net_amount, b.payment_method, b.country, b.details_at], ["ch_1", 39, 460, "ideal", "NL", "T4"]);
  eq(await needsDetails(db, "pi_123"), false);
});
Deno.test("database: omzet - terugbetalingen idempotent, rij per charge vervalt bij echte refund-id's", async () => {
  const db = fakeDb();
  await grant(db, purchase, "T1");
  eq(await recordRefunds(db, "pi_x", [refundFallback("ch_1", 100, "T2")]), { found: false, rows: 0 });
  await recordRefunds(db, "pi_123", [refundFallback("ch_1", 100, "T2")]);
  await recordRefunds(db, "pi_123", [refundFallback("ch_1", 200, "T3")]);
  eq(db.t.billing_refunds.map((r) => [r.id, r.amount]), [["ch_1", 200]], "bijgewerkt, niet dubbel");
  await recordRefunds(db, "pi_123", [{ id: "re_1", kind: "refund", amount: 200, fee: 0, at: "T2" }, { id: "re_2", kind: "refund", amount: 299, fee: 0, at: "T4" }]);
  await recordRefunds(db, "pi_123", [{ id: "re_1", kind: "refund", amount: 200, fee: 0, at: "T2" }, { id: "re_2", kind: "refund", amount: 299, fee: 0, at: "T4" }]);
  eq(db.t.billing_refunds.map((r) => [r.id, r.amount, r.purchase_id]), [["re_1", 200, 1], ["re_2", 299, 1]]);
  await recordRefunds(db, "pi_123", [{ id: "dp_1", kind: "dispute", amount: 499, fee: 1500, at: "T5" }]);
  eq(db.t.billing_refunds.length, 3, "chargeback blijft naast de refunds staan");
  eq((await revoke(db, "pi_123", "refunded", "T6")).downgraded, true);
});
