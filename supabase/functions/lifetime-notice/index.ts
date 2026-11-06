// Bingr build 167: de mail "Bingr wordt Lifetime" en de herinnering 7 dagen vóór de overgang (contract in docs/ACCOUNT.md,
// "Build 167: alleen Lifetime" → "Mail"). Alleen voor het beheer: header x-lifetime-secret = function-secret
// LIFETIME_ADMIN_SECRET (maakt de workflow Backend één keer zelf aan; de functie admin in bingr-beheer stuurt hem mee, zoals
// NEWSLETTER_ADMIN_SECRET bij newsletter). verify_jwt uit. Niets gebeurt vanzelf: geen planning, alles start in het beheer.
// De codes zelf maakt de functie billing (acties admin_codes_generate / admin_codes_stats, zelfde geheim).
//
// POST /functions/v1/lifetime-notice met JSON {action, …}:
//   admin_send {mode: "dry_run"|"test"|"send"|"remind", kind?: "notice"|"remind" (bij test), to? (bij test), lang? (bij test),
//               batch?: 1-200}
//     dry_run -> {ok, notice_pending, remind_pending, remind_window, enabled, smtp}   (alleen aantallen)
//     test    -> {ok, sent}   naar `to` (het beheeradres), onderwerp "[Test] …", voorbeeldcode; NL en EN tenzij lang
//     send    -> {ok, sent, failed, retry, errors, remaining}   "Bingr wordt Lifetime" (één batch, idempotent via mailed_at;
//                herhalen tot remaining 0)
//     remind  -> idem, de herinnering (reminded_at); alleen in de 7 dagen vóór cutover_at (anders 409 not_remind_window)
//     Alleen Gratis-accounts met een bevestigd e-mailadres, niet geblokkeerd, met een ongebruikte, geldige code. Ook zonder
//     nieuwsbrief-opt-in (dienstmelding). send/remind: 409 not_enabled (Lifetime-only uit), 409 after_cutover;
//     503 smtp_not_configured. test: 400 bad_email, 409 settings_incomplete.
//   admin_preview {kind?, lang?} -> {subject, html}   (voorbeeld met de voorbeeldcode)
//   admin_stats {} -> totalen (bingr_admin_lifetime_stats)
// Logs: alleen tellingen en foutcodes; nooit e-mailadressen, codes, account-id's of het geheim.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { codeValidUntil } from "../_shared/lifetime.ts";
import { loadSettings } from "../_shared/lifetime_store.ts";
import { mailErrorCode, smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import { type Lang, type MailKind, renderLifetimeMail, SAMPLE_CODE } from "./mail.ts";
import { batchSize, isEmail, langOf, remindWindow, sameSecret, smtpTemporary } from "./logic.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { autoRefreshToken: false, persistSession: false } });
const BUDGET_MS = 100_000;
const PAUSE_MS = Math.max(0, Math.min(5000, Number(env("LIFETIME_MAIL_PAUSE_MS") || 300) || 0));
const REPLY_TO = "Bingr Support <support@bingr.online>";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const randomId = () => Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, "0")).join("");

async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "fout"}`);
  return data as T;
}

// ---------------- mail ----------------
type Recipient = { id: string; email: string; lang: string | null; first_name: string | null; code: string; expires_at: string };

async function sendBatch(kind: MailKind, body: Record<string, unknown>) {
  const started = Date.now();
  const s = (await loadSettings(admin)).lifetime;
  if (!s.enabled || !s.cutover_at) return json({ error: "not_enabled" }, 409);
  if (Date.now() >= Date.parse(s.cutover_at)) return json({ error: "after_cutover" }, 409);
  if (kind === "remind" && !remindWindow(s.cutover_at, Date.now())) return json({ error: "not_remind_window" }, 409);
  if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
  const items = await rpc<Recipient[]>("bingr_lifetime_mail_take", { p_kind: kind, p_batch: batchSize(body.batch, 50) });
  const t = { sent: 0, failed: 0, retry: 0, errors: {} as Record<string, number> };
  const sent: string[] = [], failed: string[] = [], codes: string[] = [], retry: string[] = [];
  if ((items ?? []).length) {
    const mailer = transport(), year = new Date().getFullYear();
    let stop = false;
    try {
      for (const u of items) {
        if (stop || Date.now() - started > BUDGET_MS) { retry.push(u.id); stop = true; continue; }
        try {
          const m = renderLifetimeMail({
            kind, lang: langOf(u.lang), code: u.code, validUntil: u.expires_at, cutoverAt: s.cutover_at, discountPct: s.discount_pct,
            firstName: u.first_name ?? undefined, year,
          });
          await mailer.sendMail({
            from: smtpFrom(), replyTo: REPLY_TO, to: u.email, subject: m.subject, html: m.html, text: m.text,
            headers: { "X-Bingr-Mail": `lifetime-${kind}` }, messageId: `<bingr-lifetime-${kind}.${randomId()}@bingr.online>`, date: new Date(),
          });
          sent.push(u.id); t.sent++;
        } catch (err) {
          const code = mailErrorCode(err);
          t.errors[code] = (t.errors[code] ?? 0) + 1;
          if (smtpTemporary(err)) { retry.push(u.id); t.retry++; stop = true; } else { failed.push(u.id); codes.push(code); t.failed++; }
        }
        if (PAUSE_MS) await sleep(PAUSE_MS);
      }
    } finally {
      try { mailer.close(); } catch { /* stil */ }
      const { error } = await admin.rpc("bingr_lifetime_mail_mark", { p_kind: kind, p_sent: sent, p_failed: failed, p_codes: codes, p_retry: retry });
      if (error) console.error("lifetime-notice mail_mark", error.code ?? "fout");
    }
  }
  const st = await rpc<Record<string, number>>("bingr_admin_lifetime_stats");
  const remaining = Number(kind === "remind" ? st.remind_pending ?? 0 : st.mail_pending ?? 0);
  console.log("lifetime-notice mail", kind, JSON.stringify({ ...t, remaining }));
  return json({ ok: true, sent: t.sent, failed: t.failed, retry: t.retry, errors: t.errors, remaining });
}

async function mailAction(body: Record<string, unknown>): Promise<Response> {
  const mode = String(body.mode ?? "");
  if (mode === "dry_run") {
    const s = (await loadSettings(admin)).lifetime;
    const st = await rpc<Record<string, number>>("bingr_admin_lifetime_stats");
    return json({
      ok: true, notice_pending: Number(st.mail_pending ?? 0), remind_pending: Number(st.remind_pending ?? 0),
      remind_window: !!s.cutover_at && remindWindow(s.cutover_at, Date.now()), enabled: s.enabled, smtp: smtpConfigured(),
    });
  }
  if (mode === "send") return await sendBatch("notice", body);
  if (mode === "remind") return await sendBatch("remind", body);
  if (mode !== "test") return json({ error: "bad_mode" }, 400);
  const to = typeof body.to === "string" ? body.to.trim() : "";
  if (!isEmail(to)) return json({ error: "bad_email" }, 400);
  const s = (await loadSettings(admin)).lifetime;
  const validUntil = codeValidUntil(s);
  if (!s.cutover_at || !validUntil) return json({ error: "settings_incomplete" }, 409);
  if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
  const kind: MailKind = body.kind === "remind" ? "remind" : "notice";
  const langs: Lang[] = body.lang === "nl" || body.lang === "en" ? [body.lang] : ["nl", "en"];
  const mailer = transport();
  try {
    for (const lang of langs) {
      const m = renderLifetimeMail({ kind, lang, code: SAMPLE_CODE, validUntil, cutoverAt: s.cutover_at, discountPct: s.discount_pct, firstName: "Alex", test: true });
      await mailer.sendMail({
        from: smtpFrom(), replyTo: REPLY_TO, to, subject: m.subject, html: m.html, text: m.text,
        headers: { "X-Bingr-Mail": `lifetime-${kind}-test` }, messageId: `<bingr-lifetime-test.${randomId()}@bingr.online>`, date: new Date(),
      });
    }
  } catch (e) {
    console.error("lifetime-notice mail test", mailErrorCode(e));
    return json({ error: "smtp_error", code: mailErrorCode(e) }, 502);
  } finally { try { mailer.close(); } catch { /* stil */ } }
  console.log("lifetime-notice test", kind, langs.length);
  return json({ ok: true, sent: langs.length });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!sameSecret(req.headers.get("x-lifetime-secret"), env("LIFETIME_ADMIN_SECRET"))) return json({ error: "forbidden" }, 403);
  const text = await req.text().catch(() => "");
  if (text.length > 10_000) return json({ error: "too_large" }, 413);
  let body: Record<string, unknown> = {};
  try { const b = text.trim() ? JSON.parse(text) : {}; if (b && typeof b === "object" && !Array.isArray(b)) body = b; else return json({ error: "bad_json" }, 400); }
  catch { return json({ error: "bad_json" }, 400); }
  const action = String(body.action ?? "");
  try {
    switch (action) {
      case "ping": return json({ ok: true });
      case "admin_stats": return json({ ok: true, ...(await rpc<Record<string, unknown>>("bingr_admin_lifetime_stats")) });
      case "admin_send": return await mailAction(body);
      case "admin_preview": {
        const s = (await loadSettings(admin)).lifetime;
        const cut = s.cutover_at ?? new Date(Date.now() + 30 * 86_400_000).toISOString();
        const m = renderLifetimeMail({
          kind: body.kind === "remind" ? "remind" : "notice", lang: body.lang === "en" ? "en" : "nl", code: SAMPLE_CODE,
          validUntil: codeValidUntil(s) ?? cut, cutoverAt: cut, discountPct: s.discount_pct, firstName: "Alex", test: true,
        });
        return json({ subject: m.subject, html: m.html });
      }
      default: return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error("lifetime-notice", action, e instanceof Error ? e.message.slice(0, 80) : "fout");
    return json({ error: "server_error" }, 500);
  }
});
