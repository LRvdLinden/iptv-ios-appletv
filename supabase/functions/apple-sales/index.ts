// Omzet: Apple-aankopen uit App Store Connect (Sales and Trends) naar apple_sales_daily. POST /functions/v1/apple-sales,
// verify_jwt uit; alleen met de header x-apple-sales-secret = function-secret APPLE_SALES_SECRET (pg_cron en de functie
// admin in bingr-beheer) of Authorization: Bearer <service role>. Contract in docs/ACCOUNT.md, "Omzet: Apple (App Store
// Connect)".
//   {action: "run"}                 -> de laatste 7 dagen t/m gisteren (dagelijks via pg_cron bingr-apple-sales)
//   {action: "backfill", from, to}  -> een bereik (YYYY-MM-DD, inclusief, max. 365 dagen; beheer "Apple-omzet bijwerken")
//   {action: "status"}              -> {configured, through, last_run}
// Antwoord {configured, days, ok, empty, not_ready, failed, rows, through, error?: "asc_unauthorized"}. Zonder de secrets ASC_* {configured:false} (200).
// Een rapport dat (nog) niet bestaat geeft 404 bij Apple: geen fout. Een dag met een rapport wordt helemaal overschreven
// (idempotent). Logs: alleen datum, aantal regels en status; nooit de sleutel, de JWT, het vendornummer of de URL.
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  ascConfig, ascJwt, dailyDays, type DayResult, fetchDay, importAscKey, rangeDays, type SalesRow, summarizeRun, syncDays, throughDate,
} from "../_shared/asc.ts";
import { sameSecret } from "../newsletter/logic.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { autoRefreshToken: false, persistSession: false } });
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function allowed(req: Request): boolean {
  if (sameSecret(req.headers.get("x-apple-sales-secret"), env("APPLE_SALES_SECRET"))) return true;
  const auth = req.headers.get("authorization") ?? "";
  return auth.startsWith("Bearer ") && sameSecret(auth.slice(7).trim(), env("SUPABASE_SERVICE_ROLE_KEY"));
}

async function status() {
  const { data, error } = await admin.from("app_settings").select("value").eq("key", "apple_sales_status").maybeSingle();
  if (error) throw new Error("status");
  return (data?.value ?? {}) as Record<string, unknown>;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!allowed(req)) return json({ error: "forbidden" }, 403);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* leeg = run */ }
  const action = String(body?.action ?? "run");
  const cfg = ascConfig((k) => Deno.env.get(k));
  try {
    if (action === "status") {
      const s = await status();
      return json({ configured: !!cfg, through: s.through ?? null, last_run: s.last_run ?? null });
    }
    if (action !== "run" && action !== "backfill") return json({ error: "bad_action" }, 400);
    if (!cfg) { console.log("apple-sales", action, "niet ingesteld"); return json({ configured: false }); }
    const days = action === "run" ? dailyDays() : rangeDays(body.from, body.to);
    if (!Array.isArray(days)) return json({ error: days.error }, 400);
    const key = await importAscKey(cfg.privateKey);
    const jwt = await ascJwt(key, cfg.keyId, cfg.issuerId);
    const store = async (date: string, rows: SalesRow[]) => {
      const { error } = await admin.rpc("bingr_apple_sales_put", { p_date: date, p_rows: rows });
      if (error) throw new Error("store");
    };
    const results: DayResult[] = await syncDays(days, (d) => fetchDay(fetch, cfg, jwt, d), store);
    for (const r of results) console.log("apple-sales", r.date, r.rows, r.status, r.http ?? "");
    const prev = await status().catch(() => ({} as Record<string, unknown>));
    const through = throughDate(results, typeof prev.through === "string" ? prev.through : null);
    const sum = summarizeRun(results);
    const run = { at: new Date().toISOString(), action, days: days.length, ...sum };
    const { error } = await admin.rpc("bingr_apple_sales_status_set", { p_through: through, p_run: run });
    if (error) console.error("apple-sales", "status niet opgeslagen");
    // 401 van Apple = sleutel, rol of issuer klopt niet: dat moet het beheer zien
    const auth = results.some((r) => r.http === 401 || r.http === 403);
    return json({ configured: true, days: days.length, ...sum, through, ...(auth ? { error: "asc_unauthorized" } : {}) });
  } catch (e) {
    const m = e instanceof Error && /^(asc_key_invalid|store|status)$/.test(e.message) ? e.message : "server_error";
    console.error("apple-sales", action, m);
    return json({ error: m === "asc_key_invalid" ? "asc_key_invalid" : "server_error" }, m === "asc_key_invalid" ? 503 : 500);
  }
});
