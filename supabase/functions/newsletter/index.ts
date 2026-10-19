// Bingr nieuwsbrief (contract docs/NEWSLETTER.md): "wat is nieuw aan films en series", zondag 09:00 en woensdag 18:00
// Europe/Amsterdam, naar ingeschreven leden. POST /functions/v1/newsletter met JSON {action, …}.
//
// Planning (header x-newsletter-secret = NEWSLETTER_CRON_SECRET, pg_cron elk uur op minuut 0):
//   cron        {} -> {ok, enabled, due, created?, edition?, sent, failed, retry, left}
//   welcome_cron {} -> {ok, smtp, sent, failed, retry}   (welkomstmail, pg_cron elke 5 minuten; zie welcome.ts)
// Beheer (header x-newsletter-secret = NEWSLETTER_ADMIN_SECRET; functie admin in bingr-beheer):
//   status      {} -> {enabled, next:{key, at}, recipients:{nl, en, total}, editions:[{key, created_at, recipients, sent, failed, done}]}
//   set_enabled {enabled} -> {ok, enabled}
//   preview     {to, lang?} -> {ok}   (huidige editie naar één adres, onderwerp met "[Voorbeeld]", max. 10 per uur)
//   render      {lang} -> {subject, html}
//   welcome_preview {to, lang?} -> {ok}   (welkomstmail naar één adres, "[Voorbeeld]", aanhef met een voorbeeldnaam;
//                                          limiet gedeeld met preview)
//   welcome_render  {lang} -> {subject, html}
//   Eigen mailing (docs/NEWSLETTER.md, "Eigen mailing vanuit het beheer"; mailing.ts):
//   mailing_status {} -> {active, mailings:[…], audiences:{newsletter:{nl,en,total}, service:{…}}, per_hour, batch, sent_last_hour}
//   mailing_render {content, audience, lang} -> {subject, html}
//   mailing_test   {to, content, audience, lang: nl|en|both} -> {ok, sent}   (onderwerp "[Test] …"; limiet gedeeld met preview)
//   mailing_send   {request_id, content, audience, service_ack?} -> {ok, id, duplicate, recipients:{nl,en,total}}
//   mailing_cancel {id} -> {ok, cancelled}
//   mailing_cron   {} -> {ok, smtp, mailing, sent, failed, retry, done, budget}   (x-newsletter-secret = NEWSLETTER_CRON_SECRET;
//                  pg_cron bingr-mailing elke 5 minuten; max. MAILING_PER_HOUR per uur, MAILING_BATCH per ronde)
//   preview, welcome_preview en mailing_test ook met header x-bingr-mailtest (mailtest van de workflow Diagnose,
//   _shared/mail.ts), dan alleen naar een testadres support+ci-…@bingr.online
// Openbaar (afmeldpagina bingr.online/unsubscribe/?k=news; CORS alleen https://bingr.online):
//   unsubscribe {t} -> {ok} | 400 {error:"invalid_token"}
//   POST ?unsubscribe=t (List-Unsubscribe=One-Click, RFC 8058) -> 200 "unsubscribed"; GET ?unsubscribe=t -> 303 naar de afmeldpagina
// Logs bevatten nooit e-mailadressen, tokens of geheimen: alleen tellingen en foutcodes.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { isMailtestAddress, MAILTEST_HEADER, mailtestOk, smtpConfigured, transport } from "../_shared/mail.ts";
import { clientIp } from "../_shared/ip.ts";
import {
  type Content, dueEdition, type Edition, editionRefs, langOf, type Lang, nextEdition, oneClickUrl, sameSecret, SITE, smtpCode,
  smtpTemporary, unsubPageUrl, unsubToken, unsubUser, validEmail,
} from "./logic.ts";
import { renderNewsletter } from "./render.ts";
import { renderWelcome, SAMPLE_NAME, showNewsletter, WELCOME_BATCH } from "./welcome.ts";
import { buildContent } from "./tmdb.ts";
import {
  type Audience, budgetOf, cleanContent, isAudience, type MailingContent, type MailingRow, mailingView, type Recipient, renderMailing,
  runMailing,
} from "./mailing.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { autoRefreshToken: false, persistSession: false } });
const FN_URL = `${env("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/newsletter`;
const BATCH = Math.max(10, Math.min(500, Number(env("NEWSLETTER_BATCH") || 150) || 150));
const PAUSE_MS = Math.max(0, Math.min(5000, Number(env("NEWSLETTER_PAUSE_MS") || 300) || 0));
const BUDGET_MS = 110_000;
// eigen mailing: max. per uur (alle mailings samen) en per ronde (pg_cron elke 5 minuten)
const MAILING_PER_HOUR = Math.max(10, Math.min(2000, Number(env("MAILING_PER_HOUR") || 200) || 200));
const MAILING_BATCH = Math.max(5, Math.min(200, Number(env("MAILING_BATCH") || 50) || 50));
const MAILING_BUDGET_MS = 100_000;
const FROM = () => env("BINGR_NEWSLETTER_FROM") || "Bingr <noreply@bingr.online>";
// afmeldsleutel: BINGR_SOURCES_KEY wordt nooit vervangen (zoals de berichten in admin), met een eigen voorvoegsel
const unsubSecret = () => env("BINGR_SOURCES_KEY") || env("SUPABASE_SERVICE_ROLE_KEY");

const CORS_SITE = {
  "Access-Control-Allow-Origin": SITE,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200, cors = false) =>
  new Response(JSON.stringify(body), { status, headers: { ...(cors ? CORS_SITE : {}), "Content-Type": "application/json", "Cache-Control": "no-store" } });
const plain = (s: string, status: number) => new Response(s, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });

const secretOk = (req: Request, name: string) => sameSecret(req.headers.get("x-newsletter-secret"), env(name));
async function rateOk(key: string, max: number, windowS: number): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: key, p_max: max, p_window: windowS });
  if (error) { console.error("newsletter rate_hit", error.code ?? "fout"); return true; }
  return data !== false;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------- inhoud ----------

type EditionRow = { id: number; edition_key: string; created_at: string; content: Content; recipients: number; sent: number; failed: number; finished_at: string | null };

async function recent(excludeKey?: string) {
  let q = admin.from("newsletter_editions").select("edition_key,content").order("created_at", { ascending: false }).limit(3);
  if (excludeKey) q = q.neq("edition_key", excludeKey);
  const { data } = await q;
  const featured = new Set<string>(), shown = new Set<string>();
  for (const r of ((data ?? []) as { content: Content }[]).slice(0, 2)) {
    const x = editionRefs(r.content?.nl);
    x.featured.forEach((k) => featured.add(k));
    x.shown.forEach((k) => shown.add(k));
  }
  return { featured, shown };
}
async function makeContent(ms: number, excludeKey?: string): Promise<Content> {
  const key = env("BINGR_TMDB_API_KEY");
  if (!key) throw new Error("tmdb_not_configured");
  const r = await recent(excludeKey);
  return await buildContent(ms, key, r.featured, r.shown);
}
// voorbeeld/render: de editie die nu verstuurd wordt, anders een concept (10 minuten in het geheugen)
let draft: { at: number; content: Content } | null = null;
async function currentContent(): Promise<Content> {
  const { data } = await admin.from("newsletter_editions").select("content").is("finished_at", null).order("created_at", { ascending: false }).limit(1);
  if (data?.length) return (data[0] as { content: Content }).content;
  if (draft && Date.now() - draft.at < 600_000) return draft.content;
  const content = await makeContent(Date.now(), nextEdition(Date.now()).key);
  draft = { at: Date.now(), content };
  return content;
}
const editionFor = (c: Content, lang: Lang): Edition => c?.[lang] ?? c?.nl ?? { featured: null, fresh: [], soon: [], popular: [] };

// ---------- versturen ----------

type Totals = { sent: number; failed: number; retry: number; errors: Record<string, number> };
async function sendEdition(e: EditionRow, until: number, t: Totals): Promise<boolean> {
  const mailer = transport();
  const year = new Date(e.created_at).getFullYear();
  try {
    while (Date.now() < until) {
      const { data, error } = await admin.rpc("bingr_news_take", { p_edition: e.id, p_batch: Math.min(50, BATCH) });
      if (error) throw new Error(`take: ${error.code ?? "fout"}`);
      const r = data as { items: { id: string; email: string; lang: string | null; first_name: string | null }[]; done: boolean; busy: boolean };
      if (r.done) return true;
      if (!r.items.length) { if (r.busy) return false; continue; }
      const sent: string[] = [], failed: string[] = [], retry: string[] = [], release: string[] = [];
      let stop = false;
      for (const u of r.items) {
        // niet aan toegekomen (tijd/batch op of een tijdelijke fout): terug in de wachtrij, telt niet als poging
        if (stop || Date.now() >= until || t.sent + t.failed >= BATCH) { release.push(u.id); stop = true; continue; }
        const lang = langOf(u.lang);
        try {
          const token = await unsubToken(u.id, unsubSecret());
          const m = renderNewsletter({ lang, edition: editionFor(e.content, lang), firstName: u.first_name ?? undefined, unsubscribeUrl: unsubPageUrl(token), year });
          await mailer.sendMail({
            from: FROM(), to: u.email, subject: m.subject, html: m.html, text: m.text,
            headers: { "List-Unsubscribe": `<${oneClickUrl(FN_URL, token)}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click", "X-Bingr-Edition": e.edition_key, "X-Bingr-Mail": "newsletter" },
          });
          sent.push(u.id); t.sent++;
        } catch (err) {
          const code = smtpCode(err);
          t.errors[code] = (t.errors[code] ?? 0) + 1;
          if (smtpTemporary(err)) { retry.push(u.id); t.retry++; stop = true; } // limiet of storing: de rest bij de volgende ronde
          else { failed.push(u.id); t.failed++; }
        }
        if (PAUSE_MS) await sleep(PAUSE_MS);
      }
      const { error: me } = await admin.rpc("bingr_news_mark", { p_edition: e.id, p_sent: sent, p_failed: failed, p_retry: retry, p_release: release });
      if (me) throw new Error(`mark: ${me.code ?? "fout"}`);
      if (stop) return false;
    }
    return false;
  } finally {
    try { mailer.close(); } catch { /* stil */ }
  }
}

async function cron() {
  const started = Date.now();
  const { data: st } = await admin.from("newsletter_settings").select("enabled").eq("id", 1).maybeSingle();
  if (!st?.enabled) return { ok: true, enabled: false, due: null, sent: 0, failed: 0, retry: 0, left: 0 };
  await admin.rpc("bingr_news_cleanup");
  const due = dueEdition(started);
  let created = false;
  if (due) {
    const { data: have } = await admin.from("newsletter_editions").select("id").eq("edition_key", due.key).maybeSingle();
    if (!have) {
      const content = await makeContent(started, due.key);
      const { data: rc } = await admin.rpc("bingr_news_recipients");
      const { data: ins, error } = await admin.from("newsletter_editions")
        .upsert({ edition_key: due.key, content, recipients: Number((rc as { total?: number })?.total ?? 0) }, { onConflict: "edition_key", ignoreDuplicates: true })
        .select("id");
      if (error) throw new Error(`edition: ${error.code ?? "fout"}`);
      created = !!ins?.length;
    }
  }
  // oude, onafgemaakte edities (> 36 uur) niet meer versturen: afsluiten
  await admin.from("newsletter_editions").update({ finished_at: new Date().toISOString() }).is("finished_at", null).lt("created_at", new Date(started - 36 * 3600_000).toISOString());
  const t: Totals = { sent: 0, failed: 0, retry: 0, errors: {} };
  const { data: open } = await admin.from("newsletter_editions").select("id,edition_key,created_at,content,recipients,sent,failed,finished_at")
    .is("finished_at", null).order("created_at", { ascending: true }).limit(2);
  let last: string | null = null;
  if (open?.length && !smtpConfigured()) {
    console.error("newsletter cron: smtp_not_configured");
  } else {
    for (const e of (open ?? []) as EditionRow[]) {
      last = e.edition_key;
      const done = await sendEdition(e, started + BUDGET_MS, t);
      if (!done) break;
    }
  }
  const { count } = await admin.from("newsletter_deliveries").select("user_id", { count: "exact", head: true }).in("state", ["queued", "sending"]);
  console.log("newsletter cron", JSON.stringify({ due: due?.key ?? null, created, sent: t.sent, failed: t.failed, retry: t.retry, errors: t.errors }));
  return { ok: true, enabled: true, due: due?.key ?? null, created, edition: last, sent: t.sent, failed: t.failed, retry: t.retry, errors: t.errors, left: count ?? 0 };
}

// ---------- welkomstmail ----------
// Naar accounts die hun adres de laatste 7 dagen bevestigden en nog geen rij in account_welcome hebben (bingr_welcome_take
// claimt ze met een rij). Transactioneel: ook bij email_opt_out (het is de bevestiging van hun account), maar dan zonder
// de alinea over de nieuwsbrief; die staat er alleen in als de nieuwsbrief aan staat en het lid ingeschreven is.
const WELCOME_BUDGET_MS = 100_000;
async function welcomeCron() {
  const started = Date.now();
  if (!smtpConfigured()) { console.error("newsletter welcome: smtp_not_configured"); return { ok: true, smtp: false, sent: 0, failed: 0, retry: 0 }; }
  const { data: st } = await admin.from("newsletter_settings").select("enabled").eq("id", 1).maybeSingle();
  const newsOn = !!st?.enabled;
  const { data, error } = await admin.rpc("bingr_welcome_take", { p_batch: WELCOME_BATCH });
  if (error) throw new Error(`welcome_take: ${error.code ?? "fout"}`);
  const items = (Array.isArray(data) ? data : []) as { id: string; email: string; lang: string | null; first_name: string | null; newsletter: boolean }[];
  const t = { sent: 0, failed: 0, retry: 0, errors: {} as Record<string, number> };
  if (!items.length) return { ok: true, smtp: true, ...t };
  const sent: string[] = [], failed: string[] = [], codes: string[] = [], retry: string[] = [];
  const mailer = transport();
  const year = new Date().getFullYear();
  let stop = false;
  try {
    for (const u of items) {
      // niet aan toegekomen (tijd op of tijdelijke fout): de rij gaat weg, de volgende ronde opnieuw
      if (stop || Date.now() - started > WELCOME_BUDGET_MS) { retry.push(u.id); stop = true; continue; }
      const lang = langOf(u.lang), news = showNewsletter(newsOn, u.newsletter === true);
      try {
        const token = await unsubToken(u.id, unsubSecret());
        const m = renderWelcome({ lang, firstName: u.first_name ?? undefined, unsubscribeUrl: unsubPageUrl(token), newsletter: news, year });
        await mailer.sendMail({
          from: FROM(), to: u.email, subject: m.subject, html: m.html, text: m.text,
          headers: {
            "X-Bingr-Mail": "welcome",
            ...(news ? { "List-Unsubscribe": `<${oneClickUrl(FN_URL, token)}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } : {}),
          },
        });
        sent.push(u.id); t.sent++;
      } catch (err) {
        const code = smtpCode(err);
        t.errors[code] = (t.errors[code] ?? 0) + 1;
        if (smtpTemporary(err)) { retry.push(u.id); t.retry++; stop = true; }
        else { failed.push(u.id); codes.push(code); t.failed++; }
      }
      if (PAUSE_MS) await sleep(PAUSE_MS);
    }
  } finally {
    try { mailer.close(); } catch { /* stil */ }
    const { error: me } = await admin.rpc("bingr_welcome_mark", { p_sent: sent, p_failed: failed, p_codes: codes, p_retry: retry });
    if (me) console.error("newsletter welcome_mark", me.code ?? "fout");
  }
  console.log("newsletter welcome", JSON.stringify(t));
  return { ok: true, smtp: true, ...t };
}
async function welcomeCounts(): Promise<{ sent_7d: number; pending: number } | null> {
  const { data, error } = await admin.rpc("bingr_welcome_counts");
  if (error) { console.error("newsletter welcome_counts", error.code ?? "fout"); return null; }
  const r = (data ?? {}) as Record<string, number>;
  return { sent_7d: Number(r.sent_7d ?? 0), pending: Number(r.pending ?? 0) };
}

async function unsubscribe(t: unknown): Promise<boolean> {
  const id = await unsubUser(t, unsubSecret());
  if (!id) return false;
  const { error } = await admin.from("account_email_prefs").upsert({ user_id: id, newsletter_opt_out: true, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
  // account bestaat niet meer (foreign key): er gaat toch al niets meer heen
  if (error && error.code !== "23503") throw new Error(`unsubscribe: ${error.code ?? "fout"}`);
  return true;
}

// ---------- eigen mailing (beheer) ----------
// Inhoud en doelgroep komen uit het beheer (functie admin). De ontvangers worden bij mailing_send één keer vastgelegd
// (bingr_mailing_create); mailing_cron verstuurt ze in batches met een limiet per uur. Logs: alleen tellingen en codes.

const NIL_USER = "00000000-0000-0000-0000-000000000000";
const randomId = () => Array.from(crypto.getRandomValues(new Uint8Array(9)), (b) => b.toString(16).padStart(2, "0")).join("");

/** Kopregels per doelgroep: abonnees krijgen List-Unsubscribe (1 klik), een servicebericht niet. */
async function mailingHeaders(audience: Audience, userId: string, kind: string, id: number | string) {
  const h: Record<string, string> = { "X-Bingr-Mail": kind, "X-Bingr-Mailing": String(id) };
  if (audience === "newsletter") {
    const token = await unsubToken(userId, unsubSecret());
    h["List-Unsubscribe"] = `<${oneClickUrl(FN_URL, token)}>`;
    h["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
    return { headers: h, unsubscribeUrl: unsubPageUrl(token) };
  }
  return { headers: h, unsubscribeUrl: undefined };
}

async function audienceCounts(a: Audience) {
  const { data, error } = await admin.rpc("bingr_mailing_count", { p_audience: a });
  if (error) throw new Error(`mailing_count: ${error.code ?? "fout"}`);
  const r = (data ?? {}) as Record<string, number>;
  return { nl: Number(r.nl ?? 0), en: Number(r.en ?? 0), total: Number(r.total ?? 0) };
}

async function mailingStatus() {
  const cols = "id,created_at,finished_at,audience,status,content,recipients,recipients_nl,recipients_en,sent,failed,skipped,cancelled";
  const [list, news, service, hour] = await Promise.all([
    admin.from("mailings").select(cols).order("created_at", { ascending: false }).limit(20),
    audienceCounts("newsletter"), audienceCounts("service"), admin.rpc("bingr_mailing_sent_last_hour"),
  ]);
  if (list.error) throw new Error(`mailings: ${list.error.code ?? "fout"}`);
  const rows = (list.data ?? []) as MailingRow[];
  const act = rows.find((m) => m.status === "sending");
  let open: number | undefined;
  if (act) {
    const { data } = await admin.rpc("bingr_mailing_open", { p_mailing: act.id });
    open = typeof data === "number" ? data : undefined;
  }
  return {
    active: act ? mailingView(act, open) : null,
    mailings: rows.map((m) => mailingView(m, m === act ? open : undefined)),
    audiences: { newsletter: news, service },
    per_hour: MAILING_PER_HOUR, batch: MAILING_BATCH, sent_last_hour: typeof hour.data === "number" ? hour.data : 0,
  };
}

async function mailingCron() {
  const started = Date.now();
  if (!smtpConfigured()) return { ok: true, smtp: false, mailing: null, sent: 0, failed: 0, retry: 0, done: false, budget: 0 };
  await admin.rpc("bingr_mailing_cleanup");
  const { data: rows, error } = await admin.from("mailings").select("id,audience,content").eq("status", "sending")
    .order("created_at", { ascending: true }).limit(1);
  if (error) throw new Error(`mailings: ${error.code ?? "fout"}`);
  const m = (rows ?? [])[0] as { id: number; audience: string; content: MailingContent } | undefined;
  if (!m) return { ok: true, smtp: true, mailing: null, sent: 0, failed: 0, retry: 0, done: false, budget: 0 };
  const audience: Audience = isAudience(m.audience) ? m.audience : "newsletter";
  const { data: used } = await admin.rpc("bingr_mailing_sent_last_hour");
  const budget = budgetOf(MAILING_PER_HOUR, typeof used === "number" ? used : MAILING_PER_HOUR, MAILING_BATCH);
  if (!budget) return { ok: true, smtp: true, mailing: m.id, sent: 0, failed: 0, retry: 0, done: false, budget, waiting: "hour_limit" };
  const mailer = transport();
  const year = new Date().getFullYear();
  try {
    const r = await runMailing({
      take: async (batch) => {
        const { data, error } = await admin.rpc("bingr_mailing_take", { p_mailing: m.id, p_batch: batch });
        if (error) throw new Error(`mailing_take: ${error.code ?? "fout"}`);
        return data as { items: Recipient[]; done: boolean; busy: boolean };
      },
      mark: async (x) => {
        const { error } = await admin.rpc("bingr_mailing_mark", { p_mailing: m.id, p_sent: x.sent, p_failed: x.failed, p_retry: x.retry, p_release: x.release });
        if (error) throw new Error(`mailing_mark: ${error.code ?? "fout"}`);
      },
      send: async (u, lang) => {
        const { headers, unsubscribeUrl } = await mailingHeaders(audience, u.id, audience === "service" ? "mailing-service" : "mailing", m.id);
        const mail = renderMailing({ lang, content: m.content, audience, firstName: u.first_name ?? undefined, unsubscribeUrl, year });
        await mailer.sendMail({
          from: FROM(), to: u.email, subject: mail.subject, html: mail.html, text: mail.text, headers,
          messageId: `<bingr-mailing-${m.id}.${randomId()}@bingr.online>`, date: new Date(),
        });
      },
      now: Date.now, temporary: smtpTemporary, code: smtpCode, pause: PAUSE_MS ? () => sleep(PAUSE_MS) : undefined,
    }, { budget, until: started + MAILING_BUDGET_MS, batch: Math.min(50, budget) });
    console.log("newsletter mailing", JSON.stringify({ mailing: m.id, sent: r.sent, failed: r.failed, retry: r.retry, done: r.done, errors: r.errors }));
    return { ok: true, smtp: true, mailing: m.id, sent: r.sent, failed: r.failed, retry: r.retry, done: r.done, budget, errors: r.errors };
  } finally {
    try { mailer.close(); } catch { /* stil */ }
  }
}

/** Testmail naar één adres (nooit gelogd): "[Test] …", voorbeeldnaam, zelfde kopregels als de echte verzending. */
async function mailingTest(to: string, content: MailingContent, audience: Audience, langs: Lang[]) {
  const mailer = transport();
  try {
    for (const lang of langs) {
      const { headers, unsubscribeUrl } = await mailingHeaders(audience, NIL_USER, "mailing-test", "test");
      const m = renderMailing({ lang, content, audience, firstName: SAMPLE_NAME, unsubscribeUrl, test: true });
      await mailer.sendMail({
        from: FROM(), to, subject: m.subject, html: m.html, text: m.text, headers,
        messageId: `<bingr-mailing-test.${randomId()}@bingr.online>`, date: new Date(),
      });
    }
  } finally { try { mailer.close(); } catch { /* stil */ } }
}

async function mailingAction(action: string, body: Record<string, unknown>): Promise<Response> {
  const audience = body.audience === undefined ? "newsletter" : body.audience;
  switch (action) {
    case "mailing_status":
      return json(await mailingStatus());
    case "mailing_render": {
      if (!isAudience(audience)) return json({ error: "bad_audience" }, 400);
      const lang: Lang = body.lang === "en" ? "en" : "nl";
      const c = cleanContent(body.content, [lang]);
      if (!c.ok) return json({ error: c.error }, 400);
      const unsubscribeUrl = audience === "newsletter" ? `${SITE}/unsubscribe/?k=news` : undefined;
      const m = renderMailing({ lang, content: c.content, audience, firstName: SAMPLE_NAME, unsubscribeUrl });
      return json({ subject: m.subject, html: m.html });
    }
    case "mailing_test": {
      const to = typeof body.to === "string" ? body.to.trim() : "";
      if (!validEmail(to)) return json({ error: "bad_email" }, 400);
      if (!isAudience(audience)) return json({ error: "bad_audience" }, 400);
      const langs: Lang[] = body.lang === "both" ? ["nl", "en"] : body.lang === "en" ? ["en"] : ["nl"];
      const c = cleanContent(body.content, langs);
      if (!c.ok) return json({ error: c.error }, 400);
      if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
      // zelfde teller als de voorbeelden van nieuwsbrief en welkomstmail (samen max. 10 per uur)
      if (!(await rateOk("news-preview", 10, 3600))) return json({ error: "rate_limited", retry_after: 3600 }, 429);
      try { await mailingTest(to, c.content, audience, langs); } catch (e) {
        console.error("newsletter mailing_test", smtpCode(e));
        return json({ error: "send_failed", code: smtpCode(e) }, 502);
      }
      return json({ ok: true, sent: langs.length });
    }
    case "mailing_send": {
      if (!isAudience(audience)) return json({ error: "bad_audience" }, 400);
      if (audience === "service" && body.service_ack !== true) return json({ error: "service_ack_required" }, 400);
      const rid = typeof body.request_id === "string" ? body.request_id.toLowerCase() : "";
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(rid)) return json({ error: "bad_request_id" }, 400);
      const c = cleanContent(body.content, ["nl", "en"]);
      if (!c.ok) return json({ error: c.error }, 400);
      if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
      const { data, error } = await admin.rpc("bingr_mailing_create", { p_request: rid, p_audience: audience, p_content: c.content });
      if (error) throw new Error(`mailing_create: ${error.code ?? "fout"}`);
      const r = (data ?? {}) as Record<string, unknown>;
      if (typeof r.error === "string") return json({ error: r.error }, r.error === "mailing_busy" || r.error === "no_recipients" ? 409 : 400);
      console.log("newsletter mailing_send", JSON.stringify({ mailing: r.id, audience, duplicate: r.duplicate === true }));
      return json({ ok: true, id: r.id, duplicate: r.duplicate === true, recipients: r.recipients });
    }
    case "mailing_cancel": {
      const id = Number(body.id);
      if (!Number.isSafeInteger(id) || id <= 0) return json({ error: "bad_id" }, 400);
      const { data, error } = await admin.rpc("bingr_mailing_cancel", { p_mailing: id });
      if (error) throw new Error(`mailing_cancel: ${error.code ?? "fout"}`);
      const r = (data ?? {}) as Record<string, unknown>;
      if (r.ok !== true) return json({ error: typeof r.error === "string" ? r.error : "not_active" }, 409);
      return json({ ok: true, cancelled: Number(r.cancelled ?? 0) });
    }
  }
  return json({ error: "unknown_action" }, 400);
}

// ---------- verzoeken ----------

async function handle(req: Request, body: Record<string, unknown>): Promise<Response> {
  const action = String(body.action ?? "");
  if (action === "unsubscribe") {
    if (!(await rateOk(`news-unsub:${clientIp(req)}`, 20, 600))) return json({ error: "rate_limited", retry_after: 600 }, 429, true);
    return (await unsubscribe(body.t)) ? json({ ok: true }, 200, true) : json({ error: "invalid_token" }, 400, true);
  }
  if (action === "cron") {
    if (!secretOk(req, "NEWSLETTER_CRON_SECRET")) return json({ error: "forbidden" }, 403);
    return json(await cron());
  }
  if (action === "welcome_cron") {
    if (!secretOk(req, "NEWSLETTER_CRON_SECRET")) return json({ error: "forbidden" }, 403);
    return json(await welcomeCron());
  }
  if (action === "mailing_cron") {
    if (!secretOk(req, "NEWSLETTER_CRON_SECRET")) return json({ error: "forbidden" }, 403);
    return json(await mailingCron());
  }
  const MAILING = ["mailing_status", "mailing_render", "mailing_test", "mailing_send", "mailing_cancel"];
  if (![...MAILING, "status", "set_enabled", "preview", "render", "welcome_preview", "welcome_render"].includes(action)) return json({ error: "unknown_action" }, 400);
  const mailtest = (action === "preview" || action === "welcome_preview" || action === "mailing_test") && isMailtestAddress(body.to) &&
    await mailtestOk(req.headers.get(MAILTEST_HEADER), async () => (await admin.from("app_settings").select("value").eq("key", "mailtest").maybeSingle()).data?.value);
  if (!mailtest && !secretOk(req, "NEWSLETTER_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
  if (MAILING.includes(action)) return await mailingAction(action, body);
  switch (action) {
    case "status": {
      const [st, rc, ed, welcome] = await Promise.all([
        admin.from("newsletter_settings").select("enabled").eq("id", 1).maybeSingle(),
        admin.rpc("bingr_news_recipients"),
        admin.from("newsletter_editions").select("edition_key,created_at,recipients,sent,failed,finished_at").order("created_at", { ascending: false }).limit(10),
        welcomeCounts(),
      ]);
      if (rc.error) throw new Error(`recipients: ${rc.error.code ?? "fout"}`);
      const r = (rc.data ?? {}) as Record<string, number>;
      return json({
        enabled: !!st.data?.enabled, next: nextEdition(Date.now()),
        recipients: { nl: Number(r.nl ?? 0), en: Number(r.en ?? 0), total: Number(r.total ?? 0) },
        editions: ((ed.data ?? []) as EditionRow[]).map((e) => ({
          key: e.edition_key, created_at: e.created_at, recipients: e.recipients, sent: e.sent, failed: e.failed, done: !!e.finished_at,
        })),
        welcome,
      });
    }
    case "set_enabled": {
      if (typeof body.enabled !== "boolean") return json({ error: "bad_enabled" }, 400);
      const { error } = await admin.from("newsletter_settings").upsert({ id: 1, enabled: body.enabled, updated_at: new Date().toISOString() });
      if (error) throw new Error(`settings: ${error.code ?? "fout"}`);
      return json({ ok: true, enabled: body.enabled });
    }
    case "render": {
      const lang: Lang = body.lang === "en" ? "en" : "nl";
      const m = renderNewsletter({ lang, edition: editionFor(await currentContent(), lang), unsubscribeUrl: `${SITE}/unsubscribe/?k=news` });
      return json({ subject: m.subject, html: m.html });
    }
    case "preview": {
      const to = typeof body.to === "string" ? body.to.trim() : "";
      if (!validEmail(to)) return json({ error: "bad_email" }, 400);
      if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
      if (!(await rateOk("news-preview", 10, 3600))) return json({ error: "rate_limited", retry_after: 3600 }, 429);
      const lang: Lang = body.lang === "en" ? "en" : "nl";
      const m = renderNewsletter({ lang, edition: editionFor(await currentContent(), lang), unsubscribeUrl: `${SITE}/unsubscribe/?k=news`, preview: true });
      const mailer = transport();
      try {
        // zelfde kopregels als de echte verzending; het token hoort bij een niet-bestaand account, dus afmelden doet niets
        const token = await unsubToken("00000000-0000-0000-0000-000000000000", unsubSecret());
        await mailer.sendMail({
          from: FROM(), to, subject: m.subject, html: m.html, text: m.text,
          headers: { "List-Unsubscribe": `<${oneClickUrl(FN_URL, token)}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click", "X-Bingr-Mail": "newsletter-preview" },
        });
      } catch (e) {
        console.error("newsletter preview", smtpCode(e));
        return json({ error: "send_failed", code: smtpCode(e) }, 502);
      } finally { try { mailer.close(); } catch { /* stil */ } }
      return json({ ok: true });
    }
    case "welcome_render": {
      const lang: Lang = body.lang === "en" ? "en" : "nl";
      const m = renderWelcome({ lang, firstName: SAMPLE_NAME, unsubscribeUrl: `${SITE}/unsubscribe/?k=news`, newsletter: true, preview: true });
      return json({ subject: m.subject, html: m.html });
    }
    case "welcome_preview": {
      const to = typeof body.to === "string" ? body.to.trim() : "";
      if (!validEmail(to)) return json({ error: "bad_email" }, 400);
      if (!smtpConfigured()) return json({ error: "smtp_not_configured" }, 503);
      // zelfde limiet als het voorbeeld van de nieuwsbrief (samen max. 10 per uur)
      if (!(await rateOk("news-preview", 10, 3600))) return json({ error: "rate_limited", retry_after: 3600 }, 429);
      const lang: Lang = body.lang === "en" ? "en" : "nl";
      const m = renderWelcome({ lang, firstName: SAMPLE_NAME, unsubscribeUrl: `${SITE}/unsubscribe/?k=news`, newsletter: true, preview: true });
      const mailer = transport();
      try {
        // zelfde kopregels als de echte welkomstmail (met de alinea over de nieuwsbrief); token van een niet-bestaand account
        const token = await unsubToken("00000000-0000-0000-0000-000000000000", unsubSecret());
        await mailer.sendMail({
          from: FROM(), to, subject: m.subject, html: m.html, text: m.text,
          headers: { "X-Bingr-Mail": "welcome-preview", "List-Unsubscribe": `<${oneClickUrl(FN_URL, token)}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" },
        });
      } catch (e) {
        console.error("newsletter welcome_preview", smtpCode(e));
        return json({ error: "send_failed", code: smtpCode(e) }, 502);
      } finally { try { mailer.close(); } catch { /* stil */ } }
      return json({ ok: true });
    }
  }
  return json({ error: "unknown_action" }, 400);
}

// eigen mailing: onderwerp + tekst in twee talen (max. 2 × 8000 tekens)
const MAX_BODY = 64 * 1024;
Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_SITE });
  // afmelden met één klik uit de mail (RFC 8058); GET (link geopend in een browser) gaat naar de afmeldpagina, die eerst vraagt
  const oneClick = url.searchParams.get("unsubscribe");
  if (oneClick !== null) {
    if (req.method === "GET") {
      return new Response(null, { status: 303, headers: { Location: unsubPageUrl(oneClick.slice(0, 120)), "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" } });
    }
    if (req.method !== "POST") return plain("method not allowed", 405);
    try {
      if (!(await rateOk(`news-unsub1:${clientIp(req)}`, 200, 600))) return plain("too many requests", 429);
      return (await unsubscribe(oneClick)) ? plain("unsubscribed", 200) : plain("invalid link", 400);
    } catch (e) {
      console.error("newsletter one-click", e instanceof Error ? e.message.slice(0, 60) : "fout");
      return plain("error", 500);
    }
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "too_large" }, 413);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return json({ error: "too_large" }, 413);
    body = JSON.parse(text);
  } catch { return json({ error: "bad_json" }, 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "bad_json" }, 400);
  try {
    return await handle(req, body);
  } catch (e) {
    const msg = e instanceof Error ? e.message : "fout";
    console.error("newsletter", String(body.action ?? "").slice(0, 20), /^[a-z0-9_]+(: [A-Za-z0-9_]+)?$/.test(msg) ? msg : "server_error");
    return json({ error: msg === "tmdb_not_configured" ? msg : "server_error" }, msg === "tmdb_not_configured" ? 503 : 500, body.action === "unsubscribe");
  }
});
