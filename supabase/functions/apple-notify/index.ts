// Bingr build 167: App Store Server Notifications V2 (POST /functions/v1/apple-notify, verify_jwt uit: Apple stuurt geen
// JWT). Deze URL vult Léon in App Store Connect in (App → App-informatie → App Store Server Notifications, Productie en
// Sandbox, versie 2). Contract in docs/ACCOUNT.md, "Build 167: alleen Lifetime" → "Apple-aankoop verwerken".
//   Body {signedPayload}: JWS van Apple, gecontroleerd zoals bij billing apple_verify (_shared/apple_jws.ts: x5c-keten tot
//   Apple Root CA - G3, ES256), daarna de transactie erin (signedTransactionInfo) op dezelfde manier.
//   REFUND / REVOKE (bundle nl.lrvdlinden.bingr, product nl.lrvdlinden.bingr.lifetime) -> aankoop 'refunded' en een gekochte
//   Lifetime terug naar Gratis (zoals een terugbetaling via Stripe). Andere types (o.a. TEST, CONSUMPTION_REQUEST) -> 200.
//   Elke notificatie één keer (notificationUUID in billing_apple_events). Antwoord 200 {received:true, result}; ongeldige
//   handtekening 400 (Apple probeert dan niet opnieuw, terecht); fout bij ons 500 (Apple probeert het later opnieuw).
// Logs: alleen het type en het resultaat; nooit transactie-id's, account-id's of bedragen.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { checkTransaction, decideNotification, notificationId } from "../_shared/apple.ts";
import { verifyAppleJws } from "../_shared/apple_jws.ts";
import { notifyDone, notifySeen, revokeApple } from "../_shared/apple_store.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const raw = await req.text().catch(() => "");
  if (raw.length > 128 * 1024) return json({ error: "too_large" }, 413);
  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json({ error: "bad_json" }, 400); }
  const v = await verifyAppleJws(body?.signedPayload);
  if (!v.ok) { console.log("apple-notify: handtekening", v.error); return json({ error: "bad_signature" }, 400); }
  const d = decideNotification(v.payload);
  const id = notificationId(v.payload);
  try {
    if (id && await notifySeen(admin, id)) { console.log("apple-notify", d.type, "al verwerkt"); return json({ received: true, result: "duplicate" }); }
    let result: string;
    if (d.kind === "test") result = "test";
    else if (d.kind === "ignore") result = `ignore_${d.reason}`;
    else {
      const t = await verifyAppleJws(d.signedTransaction);
      const c = t.ok ? checkTransaction(t.payload) : null;
      // een ingetrokken transactie heeft revocationDate: dat is hier juist de bedoeling, dus alleen app en product tellen
      if (!t.ok) result = `bad_transaction_${t.error}`;
      else if (!c || (!c.ok && c.error !== "revoked")) result = `ignore_${c && !c.ok ? c.error : "bad_transaction"}`;
      else {
        const p = t.payload;
        const r = await revokeApple(admin, { originalTransactionId: String(p.originalTransactionId ?? p.transactionId), transactionId: String(p.transactionId) });
        result = !r.found ? "unknown_purchase" : r.downgraded ? "refunded_free" : `refunded_${r.reason ?? "kept"}`;
      }
    }
    if (id) await notifyDone(admin, id, d.type, result);
    console.log("apple-notify", d.type, result);
    return json({ received: true, result });
  } catch (e) {
    console.error("apple-notify", d.type, e instanceof Error ? e.message.slice(0, 80) : "fout");
    return json({ error: "server_error" }, 500);
  }
});
