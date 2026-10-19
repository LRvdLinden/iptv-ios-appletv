// Bingr: webhook van Stripe (build 133), POST /functions/v1/stripe-webhook (verify_jwt uit; Stripe stuurt geen JWT).
// Contract in docs/ACCOUNT.md, "Betalen (Stripe, build 133)". De workflow Backend maakt het endpoint in Stripe aan en zet
// het signing secret als function-secret STRIPE_WEBHOOK_SECRET.
//   Handtekening (Stripe-Signature, HMAC-SHA256 over "t.body", tolerantie 5 minuten) fout of ontbreekt -> 400.
//   checkout.session.completed / async_payment_succeeded (payment_status paid) -> Lifetime (account_plans, bron purchase)
//   checkout.session.completed (unpaid) -> aankoop 'pending'; async_payment_failed -> 'failed' (abonnement blijft)
//   charge.refunded (volledig) / charge.dispute.created -> aankoop 'refunded' / 'disputed' en een gekochte Lifetime terug naar Gratis
//   Elk event één keer (billing_events); alle stappen zijn ook zelf idempotent. Antwoord 200 {received:true, result}.
// Logs: alleen eventtype, resultaat en tellingen; nooit e-mailadressen, namen, bedragen per klant of het secret.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { billingConfig, decide, verifySignature } from "../_shared/billing.ts";
import { eventDone, eventSeen, failed, grant, pending, revoke } from "../_shared/billing_store.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

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
      case "grant": { const g = await grant(admin, d.purchase); result = g.granted ? "granted" : g.already ? "already" : "skipped"; break; }
      case "pending": await pending(admin, d.purchase); break;
      case "failed": await failed(admin, d.sessionId); break;
      case "revoke": { const r = await revoke(admin, d.paymentIntent, d.status); result = !r.found ? "unknown_payment" : r.downgraded ? `${d.status}_free` : `${d.status}_${r.reason ?? "kept"}`; break; }
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
