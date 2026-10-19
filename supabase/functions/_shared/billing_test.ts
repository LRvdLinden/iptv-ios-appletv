// deno test supabase/functions/_shared/billing_test.ts
// Betalen (build 133): handtekening van Stripe, Checkout-opbouw, events -> beslissing, en de databasestappen (grant,
// pending, revoke, idempotentie) tegen een kleine nep-database in het geheugen.
import {
  billingConfig, CANCEL_URL, checkoutParams, decide, formatAmount, formEncode, grantRow, idempotencyKey, parseSignature,
  purchaseFromSession, purchaseView, revokeAction, signHeader, SUCCESS_URL, verifySignature, WEBHOOK_EVENTS,
} from "./billing.ts";
import { eventDone, eventSeen, failed, grant, pending, revoke } from "./billing_store.ts";
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
  if (g.kind === "grant") eq(g.purchase, { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur" });
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
Deno.test("events: volledige terugbetaling en chargeback -> revoke; gedeeltelijk -> negeren", () => {
  eq(decide(ev("charge.refunded", { object: "charge", refunded: true, amount: 499, amount_refunded: 499, payment_intent: "pi_123" })),
    { kind: "revoke", paymentIntent: "pi_123", status: "refunded" });
  eq(decide(ev("charge.refunded", { object: "charge", refunded: false, amount: 499, amount_refunded: 499, payment_intent: "pi_123" })).kind, "revoke", "bedrag volledig");
  eq(decide(ev("charge.refunded", { object: "charge", refunded: false, amount: 499, amount_refunded: 200, payment_intent: "pi_123" })),
    { kind: "ignore", reason: "partial_refund" });
  eq(decide(ev("charge.dispute.created", { object: "dispute", payment_intent: "pi_123" })), { kind: "revoke", paymentIntent: "pi_123", status: "disputed" });
  eq(decide(ev("charge.dispute.created", { object: "dispute", payment_intent: null })).kind, "ignore");
  eq(WEBHOOK_EVENTS.length, 5);
});

// ---------------- account_plans ----------------
Deno.test("grant: Lifetime, bron purchase, eigen limieten blijven, geen persoonsgegevens in de notitie", () => {
  const p = { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur" };
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
function fakeDb() {
  const t: Record<string, Row[]> = { billing_purchases: [], account_plans: [], billing_events: [] };
  const keyOf: Record<string, string> = { billing_purchases: "stripe_session_id", account_plans: "user_id", billing_events: "id" };
  let seq = 1;
  function q(table: string) {
    const f: [string, string, unknown][] = [];
    let op: "select" | "update" | "delete" = "select", patch: Row = {}, lim = 1e9;
    const rows = () => t[table].filter((r) => f.every(([k, how, v]) => how === "in" ? (v as unknown[]).includes(r[k]) : r[k] === v));
    const run = () => {
      if (op === "update") { for (const r of rows()) Object.assign(r, Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined))); return { data: null, error: null }; }
      if (op === "delete") { const del = new Set(rows()); t[table] = t[table].filter((r) => !del.has(r)); return { data: null, error: null }; }
      return { data: rows().slice(0, lim).map((r) => ({ ...r })), error: null };
    };
    const b = {
      select: () => b, order: () => b,
      eq: (k: string, v: unknown) => { f.push([k, "eq", v]); return b; },
      in: (k: string, v: unknown[]) => { f.push([k, "in", v]); return b; },
      limit: (n: number) => { lim = n; return b; },
      update: (p: Row) => { op = "update"; patch = p; return b; },
      delete: () => { op = "delete"; return b; },
      maybeSingle: () => Promise.resolve({ data: (run().data as Row[])[0] ?? null, error: null }),
      then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => Promise.resolve(run()).then(res, rej),
      upsert: (o: Row, opts?: { ignoreDuplicates?: boolean }) => {
        const k = keyOf[table], cur = t[table].find((r) => r[k] === o[k]);
        const clean = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
        if (cur) { if (!opts?.ignoreDuplicates) Object.assign(cur, clean); } else t[table].push({ id: seq++, ...clean });
        return Promise.resolve({ data: null, error: null });
      },
      insert: (o: Row) => {
        const k = keyOf[table];
        if (t[table].some((r) => r[k] === o[k])) return Promise.resolve({ data: null, error: { code: "23505" } });
        t[table].push({ id: seq++, ...o }); return Promise.resolve({ data: null, error: null });
      },
    };
    return b;
  }
  return { t, from: q };
}
const purchase = { userId: UID, sessionId: "cs_test_a1", paymentIntent: "pi_123", amount: 499, currency: "eur" };
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
Deno.test("database: event één keer", async () => {
  const db = fakeDb();
  eq(await eventSeen(db, "evt_1"), false);
  await eventDone(db, "evt_1", "checkout.session.completed", "granted");
  await eventDone(db, "evt_1", "checkout.session.completed", "already");
  eq(await eventSeen(db, "evt_1"), true);
  eq(db.t.billing_events.length, 1); eq(db.t.billing_events[0].result, "granted");
});
