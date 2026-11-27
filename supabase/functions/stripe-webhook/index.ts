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
// Build 181 (Bingr Premium, docs/ACCOUNT.md "Build 181" §7): checkout.session.completed met mode=subscription (abonnement
//   ophalen en vastleggen; gast: claimmail), customer.subscription.created/updated/deleted (premium_subscriptions en de
//   spiegel in account_plans), invoice.paid (premium_payments + kosten), invoice.payment_failed (past_due, vangnet),
//   charge.refunded van een abonnementsbetaling (premium_payments.refunded_amount). Lifetime € 49,99 (metadata.plan
//   lifetime49) gaat als Lifetime; een lopend Stripe-abonnement van dat account wordt dan opgezegd aan het eind van de periode.
// Logs: alleen eventtype, resultaat en tellingen; nooit e-mailadressen, namen, bedragen per klant of het secret.
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  billingConfig, DETAILS_EXPAND, decide, emailHash, detailsFromPaymentIntent, refundFallback, refundRows, type RefundRow, verifySignature,
} from "../_shared/billing.ts";
import { eventDone, eventSeen, failed, grant, needsDetails, pending, recordRefunds, revoke, saveDetails } from "../_shared/billing_store.ts";
import { stripe, stripeError } from "../_shared/stripe.ts";
import { promotionCodeOf } from "../_shared/lifetime.ts";
import { loadSettings, markRedeemed } from "../_shared/lifetime_store.ts";
import { claimMailed, grantGuest } from "../_shared/guest_store.ts";
import { renderClaimMail } from "../_shared/claim_mail.ts";
import { mailErrorCode, smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import { decidePremium, paymentFromInvoice, type PremiumDecision, subFromStripe } from "../_shared/premium.ts";
import { claimMailedSub, markPastDue, refundPayment, savePayment, savePaymentDetails, saveStripeSub, setClaimEmail } from "../_shared/premium_store.ts";


// Claimmail na een gastaankoop (best effort: een fout laat de webhook slagen; het claimen kan ook via /upgrade/klaar/
// of automatisch via het e-mailadres). Nooit het adres of het token loggen.
async function sendClaimMail(to: string, lang: "nl" | "en", token: string, sessionId: string, premiumSub?: string): Promise<string> {
  if (!smtpConfigured()) return "no_smtp";
  const mailer = transport("stripe");
  try {
    const m = renderClaimMail(lang, token, undefined, premiumSub ? "premium" : "lifetime");
    await mailer.sendMail({ from: smtpFrom(), replyTo: "Bingr Support <support@bingr.online>", to, subject: m.subject, html: m.html, text: m.text,
      headers: { "X-Bingr-Mail": "lifetime-claim" } });
    if (premiumSub) await claimMailedSub(admin, premiumSub); else await claimMailed(admin, sessionId);
    return "mailed";
  } catch (e) {
    console.error("stripe-webhook claimmail", mailErrorCode(e));
    return "mail_error";
  } finally { try { mailer.close(); } catch { /* stil */ } }
}

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
  const type = String(event?.type ?? "?").slice(0, 80);
  // build 181: Premium-events eerst
  const pd = typeof event?.id === "string" && event.id.startsWith("evt_") ? decidePremium(event) : null;
  if (pd) {
    try {
      if (await eventSeen(admin, event.id)) { console.log("stripe-webhook", type, "al verwerkt"); return json({ received: true, result: "duplicate" }); }
      const result = await handlePremium(pd, cfg.secretKey);
      await eventDone(admin, event.id, type, result);
      console.log("stripe-webhook", type, result);
      return json({ received: true, result });
    } catch (e) {
      console.error("stripe-webhook", type, e instanceof Error ? e.message.slice(0, 80) : "fout");
      return json({ error: "server_error" }, 500);
    }
  }
  const d = decide(event);
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
        // build 167: kortingscode gebruikt
        const promo = promotionCodeOf(event.data?.object);
        if (promo) result += `+code_${await markRedeemed(admin, d.purchase.userId, promo, d.purchase.sessionId)}`;
        // build 181: Lifetime € 49,99 gekocht met een lopend Stripe-abonnement: dat abonnement aan het eind van de periode opzeggen
        if (d.purchase.plan === "lifetime49" && !g.deleted) result += `+${await cancelSubsOf(cfg.secretKey, d.purchase.userId)}`;
        break;
      }
      case "guest": {
        const g = await grantGuest(admin, d.purchase);
        result = g.revoked ? "guest_revoked" : g.claimed ? "guest_claimed" : "guest_unclaimed";
        if (!g.revoked && !g.claimed && !g.mailed && d.purchase.email) {
          const o = event.data?.object ?? {};
          result += `+${await sendClaimMail(d.purchase.email, String(o.locale ?? "").startsWith("en") ? "en" : "nl", d.purchase.claimToken, d.purchase.sessionId)}`;
        }
        if (d.purchase.paymentIntent) result += `+${await fetchDetails(cfg.secretKey, d.purchase.paymentIntent)}`;
        break;
      }
      case "refund": {
        const rec = await recordRefunds(admin, d.paymentIntent, await refundsOf(cfg.secretKey, d.chargeId, d.amountRefunded));
        // build 181: terugbetaling van een abonnementsbetaling (het abonnement zelf loopt door tot Stripe het opzegt)
        if (!rec.found) { result = await refundPayment(admin, d.paymentIntent, d.amountRefunded) ? "premium_refund" : "unknown_payment"; break; }
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

// ---------------- build 181: Premium ----------------
async function handlePremium(pd: PremiumDecision, key: string): Promise<string> {
  const s = await loadSettings(admin);
  switch (pd.kind) {
    case "sub_checkout": {
      if (!key) return "no_key";
      const r = await stripe(key, "GET", `subscriptions/${pd.subscriptionId}`, [], { timeoutMs: 8000 });
      if (!r.ok) { console.error("stripe-webhook subscription", stripeError(r)); throw new Error("subscription_fetch"); }
      const sub = subFromStripe(r.body, s.premium);
      if (!sub) return "not_ours";
      if (!sub.userId && pd.userId) sub.userId = pd.userId;
      if (!sub.claimToken && pd.claimToken) sub.claimToken = pd.claimToken;
      const saved = await saveStripeSub(admin, s.premium, sub);
      if (!saved.ok) return saved.error;
      let result = `sub_${sub.status}_${saved.mirror}`;
      if (!saved.userId && pd.claimToken && pd.email) {
        await setClaimEmail(admin, sub.stripe_subscription_id, pd.email);
        // meteen koppelen als er precies één bevestigd account met dit adres is (anders de claimmail)
        const { data } = await admin.rpc("bingr_premium_claim_hash", { p_email_hash: await emailHash(pd.email) });
        if (Number((data as { claimed?: number } | null)?.claimed ?? 0) > 0) result += "+guest_claimed";
        else result += `+${await sendClaimMail(pd.email, pd.lang, pd.claimToken, pd.sessionId, sub.stripe_subscription_id)}`;
      }
      return result;
    }
    case "sub_update": {
      const sub = subFromStripe(pd.sub, s.premium);
      if (!sub) return "not_ours";
      const saved = await saveStripeSub(admin, s.premium, sub);
      return saved.ok ? `sub_${sub.status}_${saved.mirror}` : saved.error;
    }
    case "invoice_paid": {
      const p = paymentFromInvoice(pd.invoice);
      if (!p) return "invoice_zero";
      if (!p.paymentIntent && key) p.paymentIntent = await paymentIntentOf(key, p.id);
      await savePayment(admin, p);
      if (p.paymentIntent && key) {
        try {
          const r = await stripe(key, "GET", `payment_intents/${p.paymentIntent}`, DETAILS_EXPAND, { timeoutMs: 8000 });
          const det = r.ok ? detailsFromPaymentIntent(r.body) : null;
          if (det) await savePaymentDetails(admin, p.paymentIntent, det);
        } catch { /* kosten later */ }
      }
      return "payment";
    }
    case "invoice_failed": return `past_due_${await markPastDue(admin, s.premium, pd.subscriptionId)}`;
  }
}
/** API-versie basil: de PaymentIntent van een factuur staat in invoice_payments. */
async function paymentIntentOf(key: string, invoiceId: string): Promise<string | null> {
  try {
    const r = await stripe(key, "GET", "invoice_payments", [["invoice", invoiceId], ["limit", "3"]], { timeoutMs: 8000 });
    // deno-lint-ignore no-explicit-any
    const pi = ((r.body?.data ?? []) as any[]).map((x) => x?.payment?.payment_intent).find((x) => typeof x === "string" && x.startsWith("pi_"));
    return pi ?? null;
  } catch { return null; }
}
/** Lopende Stripe-abonnementen van een account opzeggen aan het eind van de periode (na Lifetime € 49,99). Best effort. */
async function cancelSubsOf(key: string, userId: string): Promise<string> {
  if (!key) return "no_key";
  const { data } = await admin.from("premium_subscriptions").select("stripe_subscription_id").eq("user_id", userId).eq("provider", "stripe")
    .in("status", ["trialing", "active", "past_due"]);
  let n = 0;
  for (const r of (data ?? []) as { stripe_subscription_id: string }[]) {
    const x = await stripe(key, "POST", `subscriptions/${r.stripe_subscription_id}`, [["cancel_at_period_end", "true"]]).catch(() => null);
    if (x?.ok) n++;
  }
  return `subs_canceled_${n}`;
}
