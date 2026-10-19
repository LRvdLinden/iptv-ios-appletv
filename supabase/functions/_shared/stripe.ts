// Kleine Stripe-client (REST-API met fetch, geen SDK) voor de functies billing en stripe-webhook (build 133).
// De sleutel komt alleen uit het function-secret STRIPE_SECRET_KEY en staat nooit in een log of foutmelding.
import { formEncode } from "./billing.ts";

export type StripeResult = { ok: boolean; status: number; body: Record<string, unknown> };
export class StripeUnavailable extends Error {}

export async function stripe(key: string, method: "GET" | "POST", path: string, params: [string, string][] = [],
  opts: { idempotencyKey?: string; fetch?: typeof fetch; timeoutMs?: number } = {}): Promise<StripeResult> {
  const f = opts.fetch ?? fetch;
  const qs = params.length ? formEncode(params) : "";
  const url = `https://api.stripe.com/v1/${path}${method === "GET" && qs ? `?${qs}` : ""}`;
  const headers: Record<string, string> = { Authorization: `Bearer ${key}`, "Stripe-Version": "2025-03-31.basil" };
  if (method === "POST") headers["Content-Type"] = "application/x-www-form-urlencoded";
  if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
  const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), opts.timeoutMs ?? 15_000);
  try {
    const r = await f(url, { method, headers, body: method === "POST" ? qs : undefined, signal: ctl.signal });
    const body = await r.json().catch(() => ({})) as Record<string, unknown>;
    return { ok: r.ok, status: r.status, body };
  } catch (e) {
    // nooit de URL of headers in de fout (de URL kan een sessie-id bevatten, de headers de sleutel)
    throw new StripeUnavailable(e instanceof Error ? e.name : "network");
  } finally { clearTimeout(timer); }
}
/** Foutcode van Stripe (type/code), zonder bericht (dat kan gegevens van de klant bevatten). */
export function stripeError(r: StripeResult): string {
  const e = (r.body?.error ?? {}) as { type?: string; code?: string };
  return `${r.status} ${String(e.type ?? "")}${e.code ? "/" + e.code : ""}`.trim().slice(0, 80);
}
