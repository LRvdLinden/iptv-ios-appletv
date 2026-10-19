// Bingr: webhook van Stripe (build 133), POST /functions/v1/stripe-webhook (verify_jwt uit; Stripe stuurt geen JWT).
// Contract in docs/ACCOUNT.md, "Betalen (Stripe, build 133)". De workflow Backend maakt het endpoint in Stripe aan en zet
// het signing secret als function-secret STRIPE_WEBHOOK_SECRET.
//   Handtekening (Stripe-Signature, HMAC-SHA256 over "t.body", tolerantie 5 minuten) fout of ontbreekt -> 400.
//   checkout.session.completed / async_payment_succeeded (payment_status paid) -> Lifetime (account_plans, bron purchase)
//   checkout.session.completed (unpaid) -> aankoop 'pending'; async_payment_failed -> 'failed' (abonnement blijft)
//   charge.refunded (volledig) / charge.dispute.created -> aankoop 'refunded' / 'disputed' en een gekochte Lifetime terug naar Gratis
//   Omzet (tab Omzet in het beheer): bij betaald ook Stripe-kosten, netto, betaalmethode en land (PaymentIntent met
//   latest_charge.balance_transaction, via STRIPE_SECRET_KEY); ontbreken de kosten nog, dan bij charge.updated. Elke
//   terugbetaling (ook gedeeltelijk, alleen bedrag en datum) en chargeback (bedrag en kosten) in billing_refunds.
//   Elk event één keer (billing_events); alle stappen zijn ook zelf idempotent. Antwoord 200 {received:true, result}.
// Logs: alleen eventtype, resultaat en tellingen; nooit e-mailadressen, namen, bedragen per klant of het secret.
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  billingConfig, DETAILS_EXPAND, decide, detailsFromPaymentIntent, refundFallback, refundRows, type RefundRow, verifySignature,
} from "../_shared/billing.ts";
import { eventDone, eventSeen, failed, grant, needsDetails, pending, recordRefunds, revoke, saveDetails } from "../_shared/billing_store.ts";
import { stripe, stripeError } from "../_shared/stripe.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Stripe-kosten, betaalmethode en land ophalen en opslaan. Best effort: een fout hier laat de webhook slagen (de kosten
// komen dan bij charge.updated of via revenue_backfill in het beheer).
async function fetchDetails(key: string, pi: string): Promise<string> {
  if (!key) return "no_key";
  try {
    const r = await stripe(key, "GET", `payment_intents/${pi}`, DETAILS_EXPAND, { timeoutMs: 8000 });
    if (!r.ok) { console.error("stripe-webhook details", stripeError(r)); return "details_error"; }
    const d = detailsFromPaymentIntent(r.body);
    if (!d) return "details_none";
    return await saveDetails(admin, pi, d) ? "details" : "details_nofee";
  } catch (e) {
    console.error("stripe-webhook details", e instanceof Error ? e.name : "fout");
    return "details_error";
  }
}
async function refundsOf(key: string, chargeId: string | null, amountRefunded: number): Promise<RefundRow[]> {
  const now = new Date().toISOString();
  if (!chargeId) return [];
  if (key) {
    try {
      const r = await stripe(key, "GET", "refunds", [["charge", chargeId], ["limit", "100"]], { timeoutMs: 8000 });
      if (r.ok) { const rows = refundRows(r.body, now); if (rows.length) return rows; }
      else console.error("stripe-webhook refunds", stripeError(r));
    } catch (e) { console.error("stripe-webhook refunds", e instanceof Error ? e.name : "fout"); }
  }
  return amountRefunded > 0 ? [refundFallback(chargeId, amountRefunded, now)] : [];
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const raw = await req.text().catch(() => "");
  if (raw.length > 512 * 1024) return json({ error: "too_large" }, 413);
  const cfg = billingConfig((k) => Deno.env.get(k));
  const sig = await verifySignature(raw, req.headers.get("Stripe-Signature"), cfg.webhookSecret);
  if (sig !== "ok") {
    console.log("stripe-webhook: handtekening", sig);
    return json({ error: "bad_signature" }, 400);
  }
  // deno-lint-ignore no-explicit-any
  let event: any;
  try { event = JSON.parse(raw); } catch { return json({ error: "bad_json" }, 400); }
  const d = decide(event);
  const type = String(event?.type ?? "?").slice(0, 80);
  try {
    if (d.kind !== "ignore" && await eventSeen(admin, event.id)) {
      console.log("stripe-webhook", type, "al verwerkt");
      return json({ received: true, result: "duplicate" });
    }
    let result: string = d.kind;
    switch (d.kind) {
      case "grant": {
        const g = await grant(admin, d.purchase); result = g.granted ? "granted" : g.already ? "already" : g.deleted ? "account_deleted" : "skipped";
        if (d.purchase.paymentIntent) result += `+${await fetchDetails(cfg.secretKey, d.purchase.paymentIntent)}`;
        break;
      }
      case "refund": {
        const rec = await recordRefunds(admin, d.paymentIntent, await refundsOf(cfg.secretKey, d.chargeId, d.amountRefunded));
        if (!rec.found) { result = "unknown_payment"; break; }
        if (!d.full) { result = "partial_refund"; break; }
        const r = await revoke(admin, d.paymentIntent, "refunded");
        result = r.downgraded ? "refunded_free" : `refunded_${r.reason ?? "kept"}`;
        break;
      }
      case "details": {
        const need = await needsDetails(admin, d.paymentIntent);
        result = need === null ? "unknown_payment" : need ? await fetchDetails(cfg.secretKey, d.paymentIntent) : "details_known";
        break;
      }
      case "pending": await pending(admin, d.purchase); break;
      case "failed": await failed(admin, d.sessionId); break;
      case "revoke": {
        if (d.dispute) await recordRefunds(admin, d.paymentIntent, [d.dispute]);
        const r = await revoke(admin, d.paymentIntent, d.status); result = !r.found ? "unknown_payment" : r.downgraded ? `${d.status}_free` : `${d.status}_${r.reason ?? "kept"}`; break; }
      case "ignore": result = `ignore_${d.reason}`; break;
    }
    if (d.kind !== "ignore") await eventDone(admin, event.id, type, result);
    console.log("stripe-webhook", type, result);
    return json({ received: true, result });
  } catch (e) {
    // 500: Stripe probeert het later opnieuw (alle stappen zijn idempotent)
    console.error("stripe-webhook", type, e instanceof Error ? e.message.slice(0, 80) : "fout");
    return json({ error: "server_error" }, 500);
  }
});
