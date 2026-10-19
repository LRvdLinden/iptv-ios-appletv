// Edge Function auth-mail (build 137): Send Email Hook van Supabase Auth. Auth roept deze functie aan in plaats van zelf via
// SMTP te mailen (bevestigen, wachtwoord vergeten, uitnodiging, inloglink, e-mailadres wijzigen, verificatiecode). Zie
// logic.ts waarom. Ingesteld door de workflow Backend: hook_send_email_* in de Auth-config en het geheim AUTH_MAIL_HOOK_SECRET
// ("v1,whsec_<base64>", zelfde waarde). Zonder JWT (verify_jwt = false): alleen een geldige Standard-Webhooks-handtekening.
// Antwoord: 200 {} = verstuurd; fout: {error:{http_code, message}} (Auth geeft dan een foutmelding aan de app; nooit stil).
// In de logs nooit adressen, tokens of links: alleen het soort mail en de foutsoort.
import { smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import { buildMails, type EmailData, type HookUser, verifyHook } from "./logic.ts";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const fail = (status: number, message: string) => json(status, { error: { http_code: status, message } });
const errKind = (e: unknown) => {
  const s = e instanceof Error ? `${(e as { code?: string }).code ?? e.name} ${(e as { responseCode?: number }).responseCode ?? ""}` : "onbekend";
  return s.replace(/[^\w .:-]/g, "").slice(0, 80);
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return fail(405, "Method not allowed");
  const body = await req.text();
  const secret = Deno.env.get("AUTH_MAIL_HOOK_SECRET") ?? "";
  if (!secret) { console.error("auth-mail: AUTH_MAIL_HOOK_SECRET ontbreekt"); return fail(500, "Email is not configured."); }
  if (!(await verifyHook(secret, req.headers, body))) return fail(401, "Invalid signature");
  let p: { user?: HookUser; email_data?: EmailData };
  try { p = JSON.parse(body); } catch { return fail(400, "Invalid payload"); }
  const action = p.email_data?.email_action_type ?? "?";
  const mails = buildMails(p.user ?? {}, p.email_data ?? {});
  if (!mails.length) {
    // soort zonder eigen template (bv. een melding): niet versturen, wel doorgaan
    console.warn("auth-mail: geen template voor", action.replace(/[^\w-]/g, "").slice(0, 40));
    return json(200, {});
  }
  if (!smtpConfigured()) { console.error("auth-mail: BINGR_SMTP_* ontbreken"); return fail(500, "Email is not configured."); }
  const tx = transport();
  try {
    for (const m of mails) {
      await tx.sendMail({
        from: smtpFrom(), to: m.to, subject: m.subject, html: m.html, text: m.text,
        headers: { "Auto-Submitted": "auto-generated", "X-Bingr-Mail": `auth-${m.template}` },
      });
    }
    console.log("auth-mail: verstuurd", action, mails.length);
    return json(200, {});
  } catch (e) {
    console.error("auth-mail: versturen mislukt", action, errKind(e));
    return fail(500, "Error sending email. Please try again later.");
  } finally {
    tx.close();
  }
});
