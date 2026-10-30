// Bingr: supporttickets voor https://support.bingr.online, en het beheer (tab Support op beheer.bingr.online).
// POST /functions/v1/support met JSON {action, ...}; header `apikey`; `Authorization: Bearer <access_token>` optioneel
// (ingelogd met een Bingr-account: ticket gekoppeld aan het account, en "Mijn tickets").
//   ping    {}                                   -> {ok:true}  (statuscontrole)
//   challenge {}                                 -> {algorithm:"SHA-256", salt, difficulty, expires, signature}  (build 95: captcha
//                                                   zonder derde partij, zie pow.ts; 10 minuten geldig, salt maar één keer bruikbaar)
//   create  {name, email, category, platform?, app_version?, device_id?, subject, message, lang, website (lokveld), elapsed_ms?,
//            pow: {salt, difficulty, expires, signature, nonce}}
//                                                -> {ok, number, token, url, email_sent}
//           build 95: zonder geldige pow (of met het lokveld ingevuld) een schijnbaar "gelukt" zonder iets op te slaan.
//           Limieten (build 95, echt per uur): 5 pogingen en 5 tickets per IP, 3 tickets per e-mailadres. Boven 500 tickets
//           per uur in totaal worden de tickets wel opgeslagen en aan support gemeld, maar gaat er geen bevestiging naar de klant.
//           Bevestiging aan een gast (niet ingelogd) of bij een ticket uit een mail: zonder onderwerp en bericht (geen spam-relay).
//           device_id (ingelogd): een apparaat uit my_devices; naam, platform en systeemversie komen dan uit account_devices.
//           Is het niet van de ingelogde gebruiker (of niet ingelogd), dan wordt device_id genegeerd.
//   my_devices {} (ingelogd)                     -> {devices:[{id, name, platform, kind, label, app_version, os_version, last_seen_at}],
//                                                    versions:["1.0.0 (74)", …], known:[{version, build, platforms}]}
//                                                (alleen eigen apparaten; laatst gebruikt eerst; known = nieuwste build per platform
//                                                uit bingr.online/assets/changelog.json, terugval als de apparaten geen versie hebben)
//   versions {}                                  -> {known:[{version:"1.0.0 (81)", build, platforms:["ios","tvos",…]}]}  (zonder inloggen)
//   mine    {} (ingelogd)                        -> {items:[{number, subject, status, created_at, last_reply_at, unread, token}]}
//           mine en my_devices met een geblokkeerd account: 401 {error:"user_banned", banned:true} (create kan dan als gast)
//   get     {n, t} of {n} (ingelogd, eigen ticket) -> {ticket:{…, linked, can_link}, messages:[{author, body, created_at}]}
//   link    {n, t} (ingelogd)                    -> {ok, already?}  (ticket met de geheime link aan het eigen account koppelen;
//           al aan een ander account gekoppeld: 409 linked_elsewhere)
//   Eigenaar van een ticket (security H1) is alleen het account met user_id: ingelogd aangemaakt, of gekoppeld met "link".
//   Nooit op e-mailadres (met autoconfirm bewijst email_confirmed_at niets). mine toont alleen tickets met user_id.
//   reply   {n, t?, message}                     -> {ok, status}   (gesloten ticket: 409 closed)
//   close   {n, t?}                              -> {ok, status:"closed"}
// Build 146, apps (altijd ingelogd, eigenaar alleen via user_id; contract docs/ACCOUNT.md "Build 146" → "Support vanuit de app"):
//   app_list      {status?: all|open|in_progress|closed} -> {items:[{number, subject, status, group, category, platform, …,
//                 last_reply_at, unread_count, unread}], counts:{open, in_progress, closed, unread}}
//   app_get       {number, mark_read?=true}      -> {ticket:{…, can_reply}, messages:[{author, body, created_at, diagnostics?:{kind, createdAt}}]}
//   app_mark_read {number}                       -> {ok}
//   app_reply     {number, message, diagnostics?} -> {ok, status, group, diagnostics: accepted|stripped|null}  (gesloten: 409 closed)
//   app_create    {subject, message, category, diagnostics?, device_id?, platform?, app_version?, lang?}
//                 -> {ok, number, status, group, email_sent, diagnostics}  (geen captcha; 5/uur en 15/dag per account, 10/uur per IP)
//   app_close     {number}                       -> {ok, status:"closed", group:"closed"}
//   Fouten: 401 not_signed_in / user_banned, 404 not_found (ook een ticket van een ander account), 400 bad_diagnostics /
//   validatiefouten zoals create, 413 diagnostics_too_large, 429 rate_limited.
// Build 146: berichttekst, diagnose-bijlage en het inbox-logboek (afzender, onderwerp, detail) staan versleuteld in de
//   database (_shared/sealed.ts, `enc1:…`). Een antwoord van support (beheer of per mail) op een ticket met account geeft
//   een pushmelding (kind support_reply, functie push) naast de mail.
// Beheer (alleen met header x-support-secret = SUPPORT_ADMIN_SECRET; de functie admin in bingr-beheer stuurt dit door):
//   admin_counts {}                               -> {new, open, pending, resolved, closed, active, unread, total, last_7d}
//   admin_list   {status?: active|all|<status>, q?, page?, page_size?} -> {total, page, page_size, items:[…], counts}
//   admin_get    {number}                         -> {ticket, messages (ook notities), account}  (zet admin_seen_at)
//   admin_reply  {number, message, status?}       -> {ok, status, email_sent}  (mailt de klant)
//   admin_status {number, status?, priority?, notify?} -> {ok, status, email_sent}  (opgelost/gesloten: mail aan de klant)
//   admin_note   {number, message}                -> {ok}   (interne notitie, nooit zichtbaar voor de klant)
//   admin_inbox  {}                               -> {configured, agents, state, log}  (status van de inbox-import)
//   admin_poll   {}                               -> zoals poll_inbox  (knop "Nu ophalen" in het beheer)
//   admin_reply en admin_status ook met header x-bingr-mailtest (workflow Diagnose, _shared/mail.ts), dan alleen voor
//   testtickets van een testadres support+ci-…@bingr.online
// Inbox-import (alleen met header x-support-cron = SUPPORT_CRON_SECRET; pg_cron roept dit elke 5 minuten aan, build 95):
//   poll_inbox   {ci_tag?}  -> {ok, fetched, imported, new_tickets, …, reasons, inbox, pending, keywords} of {skipped:"imap not configured"} of {ok:false, error}
//   Build 140: elke ronde alle mails in INBOX zonder het trefwoord $BingrDone (ook gelezen en oude), max. 25 per ronde, oudste
//   eerst; idempotent op Message-ID. ci_tag (alleen met een geldige x-bingr-mailtest-sleutel): ook de plusmap INBOX.ci-… van
//   de rooktest in Backend (supabase/tests/inbox_e2e.py), daar alleen mails van het testadres.
//   Haalt nieuwe mails uit de INBOX van support@ (IMAP over TLS: BINGR_IMAP_HOST, BINGR_IMAP_PORT (993), BINGR_IMAP_USER,
//   BINGR_IMAP_PASSWORD) en zet ze in het ticket (zie inbox.ts): reacties van klanten, antwoorden van support@ of een adres
//   uit BINGR_SUPPORT_AGENTS (die gaan als gebrande mail naar de klant; build 95: alleen met DKIM van het afzenderdomein
//   volgens de bovenste Authentication-Results van onze server, BINGR_SUPPORT_AUTHSERV of afgeleid van BINGR_IMAP_HOST),
//   en nieuwe tickets voor mails zonder ticket.
//   Staat IMAP aan, dan is de Reply-To van de meldingen aan support@ het supportadres zelf (antwoorden komen in het ticket);
//   anders het adres van de klant (zoals vroeger).
// E-mail via _shared/mail.ts (BINGR_SMTP_*). Afzender BINGR_SUPPORT_FROM (standaard "Bingr Support <support@bingr.online>"),
// meldingen naar BINGR_SUPPORT_EMAIL (standaard support@bingr.online). Weigert de SMTP-server die afzender, dan gaat de
// mail met BINGR_SMTP_FROM als afzender en het supportadres als Reply-To. Mislukt mailen: het ticket blijft bestaan.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { isMailtestAddress, MAILTEST_HEADER, mailtestOk, mailErrorCode, smtpConfigured, smtpFrom, transport, withName } from "../_shared/mail.ts";
import {
  addressOf, beheerUrl, type DeviceRow, deviceKind, emailProven, isStatus, ownsTicket, type KnownVersion, knownVersions, myDevices, parseNumber, PRIORITIES, randomToken, safeSearch, sameText, type Status, statusAfter,
  ticketUrl, validateCreate, validateMessage, validToken,
} from "./logic.ts";
import { type MailData, renderMail } from "./templates.ts";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { Imap } from "./imap.ts";
import { parseMessage, type ParsedMail } from "./mime.ts";
import {
  agentList, authservNames, candidateNumbers, CI_TAG, cleanSubject, decide, type Decision, DONE_KEYWORD, findCiFolder, findFolder, FOLLOW_UP, guessLang,
  isFinal, keywordAllowed, MAX_FETCH_BYTES, messageBody, OTHER_SENDER, pickQueue, referencedIds, RELATED, senderName, type TicketLite,
} from "./inbox.ts";
import { clientIp } from "../_shared/ip.ts";
import { firstNameOf } from "../_shared/layout.ts";
import { makeChallenge, powKey, verifyPow } from "./pow.ts";
import { openField, openJsonField, sealField, sealJsonField } from "../_shared/sealed.ts";
import { cleanDiagnostics, ticketPlatform } from "../_shared/diagnostics.ts";
import { supportKey } from "../push/logic.ts";
import { accountName, osFromDiag, STATUS_GROUPS, statusGroup, type StatusGroup, unreadCounts, versionFromDiag } from "./logic.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const SUPPORT_SITE = env("BINGR_SUPPORT_SITE") || "https://support.bingr.online";
const BEHEER = "https://beheer.bingr.online";
const SUPPORT_EMAIL = () => env("BINGR_SUPPORT_EMAIL") || "support@bingr.online";
// altijd met weergavenaam: een kaal adres in BINGR_SUPPORT_FROM wordt "Bingr Support <adres>"
const SUPPORT_FROM = () => withName(env("BINGR_SUPPORT_FROM") || "support@bingr.online", "Bingr Support");
const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { autoRefreshToken: false, persistSession: false } });

const MAIN_SITE = env("BINGR_SITE") || "https://bingr.online";

// Nieuwste build per platform (uit de changelog van bingr.online), 10 minuten in het geheugen; bij een fout de vorige lijst.
let knownCache: { at: number; list: KnownVersion[] } | null = null;
async function knownBuilds(): Promise<KnownVersion[]> {
  if (knownCache && Date.now() - knownCache.at < 600_000) return knownCache.list;
  try {
    const r = await fetch(`${MAIN_SITE}/assets/changelog.json`, { signal: AbortSignal.timeout(4000), headers: { "Cache-Control": "no-cache" } });
    if (!r.ok) throw new Error(`changelog ${r.status}`);
    const list = knownVersions(await r.json());
    knownCache = { at: Date.now(), list };
    return list;
  } catch (e) {
    console.error("support known", e instanceof Error ? e.message : e);
    if (knownCache) { knownCache.at = Date.now() - 540_000; return knownCache.list; } // over een minuut opnieuw proberen
    return [];
  }
}

// build 146: ook de webspeler (bingr.online/web, ook in de Windows-app) en de Samsung TV-app (Tizen-webview: Origin
// "file://" of "null") voor de acties app_* met de sessie van het account. Native apps sturen geen Origin.
const ORIGIN = /^https:\/\/(support\.)?bingr\.online$|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$|^file:\/\/$|^null$/;
function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    ...(ORIGIN.test(origin) ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

// ---- hulpjes ----
type Json = (b: unknown, s?: number) => Response;
type Ticket = {
  id: string; number: number; user_id: string | null; email: string; name: string; subject: string; category: string;
  platform: string | null; app_version: string | null; device_id: string | null; device_name: string | null; os_version: string | null; status: Status; priority: string; lang: "nl" | "en";
  device_type?: string | null; device_model?: string | null; source?: string | null;
  access_token: string; created_at: string; updated_at: string; last_reply_at: string; last_customer_at: string;
  last_support_at: string | null; admin_seen_at: string | null; customer_seen_at: string | null; closed_at: string | null;
};
const PUBLIC_FIELDS = "number,subject,category,platform,app_version,device_name,os_version,status,lang,name,email,created_at,updated_at,last_reply_at,last_support_at,closed_at";
async function sha256hex(s: string) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}
const ipHash = (ip: string) => sha256hex(`bingr-support|${ip}|${env("SUPABASE_SERVICE_ROLE_KEY")}`).then((h) => h.slice(0, 32));
const nowIso = () => new Date().toISOString();
const hourAgo = () => new Date(Date.now() - 3600e3).toISOString();

type User = { id: string; email?: string; email_confirmed_at?: string | null; created_at?: string | null };
/** Ingelogde gebruiker, null zonder (geldig) token. Een verlopen token telt als niet ingelogd. */
async function userFrom(req: Request): Promise<User | null> {
  const u = await userOrBanned(req);
  return u === "banned" ? null : u;
}
/** Zoals userFrom, maar een geblokkeerd account geeft "banned" (mine/my_devices: 401 user_banned; de site toont de melding).
 *  Een nieuw ticket maken kan een geblokkeerde klant wel, als gast (userFrom geeft dan null). */
async function userOrBanned(req: Request): Promise<User | null | "banned"> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return null;
  const { data, error } = await db.auth.getUser(token);
  if (isBanError(error)) return "banned";
  if (error || !data?.user) return null;
  return bannedUntilActive((data.user as { banned_until?: string }).banned_until) ? "banned" : data.user as User;
}
// bevestigen per e-mail verplicht? (app_settings.require_email_confirm, 60 s in het geheugen; bij een fout: nee)
let confirmCache: { at: number; v: boolean } | null = null;
async function requireConfirm(): Promise<boolean> {
  if (confirmCache && Date.now() - confirmCache.at < 60_000) return confirmCache.v;
  const { data, error } = await db.from("app_settings").select("value").eq("key", "require_email_confirm").maybeSingle();
  const v = !error && data?.value === true;
  confirmCache = { at: Date.now(), v };
  return v;
}

async function ticketByNumber(n: number): Promise<Ticket | null> {
  const { data, error } = await db.from("support_tickets").select("*").eq("number", n).maybeSingle();
  if (error) throw new Error(error.message);
  return data as Ticket | null;
}
/** Ticket voor de klant: met nummer + geheime link, of als eigenaar (user_id) ingelogd. Altijd hetzelfde antwoord als het
 *  niet mag. viaLink = geopend met de geheime link (alleen dan kan een ingelogde klant het ticket aan zich koppelen). */
async function customerTicket(req: Request, body: Record<string, unknown>): Promise<{ t: Ticket; user: User | null; viaLink: boolean } | null> {
  const n = parseNumber(body.n ?? body.number);
  if (!n) return null;
  const t = await ticketByNumber(n);
  if (!t) return null;
  const user = await userFrom(req);
  if (validToken(body.t) && sameText(body.t, t.access_token)) return { t, user, viaLink: true };
  return ownsTicket(user?.id, t.user_id) ? { t, user, viaLink: false } : null;
}
// build 146: berichttekst en diagnose-bijlage staan versleuteld (`enc1:…`); oude berichten zijn nog leesbaar (openField).
// includeNotes = beheer: ook notities en de volledige bijlage. Klant (site/app): zonder notities, bijlage als samenvatting.
async function messagesOf(ticketId: string, includeNotes: boolean) {
  let q = db.from("support_messages").select("id,author,body,created_at,email_sent,email_error,source,diagnostics").eq("ticket_id", ticketId).order("created_at").order("id");
  if (!includeNotes) q = q.neq("author", "note");
  const { data, error } = await q.limit(500);
  if (error) throw new Error(error.message);
  return await Promise.all((data ?? []).map(async (m) => {
    const body = await openField(m.body) ?? "";
    const diag = m.diagnostics ? await openJsonField(m.diagnostics) : null;
    if (includeNotes) { const { diagnostics: _d, ...rest } = m; return { ...rest, body, diagnostics: diag }; }
    return { author: m.author, body, created_at: m.created_at, ...(diag ? { diagnostics: { kind: diag.kind ?? null, createdAt: diag.createdAt ?? null } } : {}) };
  }));
}
type Source = "web" | "email" | "admin" | "app";
async function addMessage(ticketId: string, author: string, body: string, source: Source | null = null, mail?: { messageId: string; inReplyTo: string | null }, diagnostics?: unknown) {
  // statuswijzigingen (event) zijn geen inhoud: leesbaar; al het andere versleuteld
  const row: Record<string, unknown> = { ticket_id: ticketId, author, body: author === "event" ? body : await sealField(body) ?? "" };
  if (diagnostics) row.diagnostics = await sealJsonField(diagnostics);
  if (source) row.source = source;
  if (mail) { row.message_id = mail.messageId; row.in_reply_to = mail.inReplyTo; }
  const { data, error } = await db.from("support_messages").insert(row).select("id").single();
  if (error) throw Object.assign(new Error(error.message), { code: error.code });
  return data.id as number;
}

// ---- e-mail ----
type Sent = { ok: boolean; error?: string; messageId?: string };
const imapConfigured = () => !!(env("BINGR_IMAP_HOST") && env("BINGR_IMAP_USER") && env("BINGR_IMAP_PASSWORD"));
async function send(to: string, mail: { subject: string; html: string; text: string }, opts: { replyTo?: string; number: number; first?: boolean; auto?: boolean; kind?: string }): Promise<Sent> {
  if (!smtpConfigured()) return { ok: false, error: "smtp_not_configured" };
  // alle mails van één ticket in één gesprek (Message-ID / In-Reply-To / References). Elke mail een eigen Message-ID met het
  // ticketnummer erin (<bingr-ticket-1007.…@bingr.online>), zodat een antwoord erop altijd bij het ticket komt.
  const root = `<bingr-ticket-${opts.number}@bingr.online>`;
  const messageId = opts.first && to.toLowerCase() !== SUPPORT_EMAIL().toLowerCase() ? root : `<bingr-ticket-${opts.number}.${randomToken(9)}@bingr.online>`;
  // X-Bingr-Ticket: zo herkent de inbox-import onze eigen mails (geen lussen); Auto-Submitted voor systeemmails (RFC 3834),
  // zodat afwezigheidsmelders er niet op antwoorden
  const headers: Record<string, string> = {
    "X-Bingr-Ticket": String(opts.number), ...(opts.kind ? { "X-Bingr-Mail": `support-${opts.kind}` } : {}), ...(opts.auto ? { "Auto-Submitted": "auto-generated" } : {}),
  };
  if (messageId !== root) { headers["In-Reply-To"] = root; headers["References"] = root; }
  const base = { to, subject: mail.subject, html: mail.html, text: mail.text, headers, messageId };
  const tx = transport();
  try {
    try {
      await tx.sendMail({ ...base, from: SUPPORT_FROM(), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
      return { ok: true, messageId };
    } catch (e) {
      // afzender geweigerd (het SMTP-account mag niet als support@ versturen): opnieuw met de standaardafzender
      if (smtpFrom() && addressOf(smtpFrom()).toLowerCase() !== addressOf(SUPPORT_FROM()).toLowerCase()) {
        console.error("support mail (support-afzender)", mailErrorCode(e));
        await tx.sendMail({ ...base, from: withName(addressOf(smtpFrom()), "Bingr Support"), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
        return { ok: true, messageId };
      }
      throw e;
    }
  } catch (e) {
    // alleen de code (smtp_550, eauth, …): de servertekst kan het adres van de klant bevatten
    const code = mailErrorCode(e);
    console.error("support mail", code);
    return { ok: false, error: code };
  } finally { tx.close(); }
}
function mailData(t: Ticket, kind: MailData["kind"], extra: Partial<MailData> = {}): MailData {
  const customer = ticketUrl(SUPPORT_SITE, t.number, t.access_token);
  return {
    kind, lang: t.lang, number: t.number, subject: t.subject, status: t.status, url: kind.startsWith("support_") ? beheerUrl(BEHEER, t.number) : customer,
    customerUrl: customer, name: t.name, email: t.email, category: t.category, platform: t.platform, appVersion: t.app_version,
    deviceName: t.device_name, osVersion: t.os_version,
    hasAccount: !!t.user_id, createdAt: t.created_at, replyByMail: imapConfigured(), ...extra,
  };
}
/** Voornaam voor de aanhef ("Hoi <voornaam>,"): alleen als het ticket bij een account hoort en naar het aantoonbaar
 *  bevestigde adres van dat account gaat (user_metadata.first_name, zie emailProven); anders, of als het opzoeken mislukt,
 *  "" (mail zonder aanhef). */
async function firstNameFor(t: Ticket): Promise<string> {
  if (!t.user_id) return "";
  try {
    const { data, error } = await db.auth.admin.getUserById(t.user_id);
    const u = data?.user;
    if (error || !u?.email || !emailProven(u, await requireConfirm()) || u.email.toLowerCase() !== t.email.toLowerCase()) return "";
    return firstNameOf(u);
  } catch { return ""; }
}
// build 146: testaccounts van de workflow Backend (adres @example.com/.net/.org, RFC 2606: nooit een echte klant) krijgen
// geen mails, en support@ krijgt er geen melding van
const testAddress = (e: string | null | undefined) => /@example\.(com|net|org)$/i.test(String(e ?? ""));
const toCustomer = async (t: Ticket, d: MailData) => testAddress(t.email) ? notSent("test_address") :
  send(t.email, renderMail({ ...d, firstName: d.firstName ?? await firstNameFor(t) }), { number: t.number, first: d.kind === "customer_created", auto: d.kind !== "customer_reply", kind: d.kind });
// build 95: boven dit aantal nieuwe tickets per uur (alle samen) geen bevestigingsmails meer aan klanten (tickets worden wel
// opgeslagen en support krijgt de melding): een veiligheidsgrens tegen misbruik als mailkanon, die niemand buitensluit
const GLOBAL_CONFIRM_CAP = 500;
const confirmAllowed = async () => (await countSince((q) => q)) < GLOBAL_CONFIRM_CAP;
const notSent = (error: string): Sent => ({ ok: false, error });
// Reply-To van een melding: met de inbox-import het supportadres zelf (het antwoord van de eigenaar komt dan via de import in
// het ticket en gaat als gebrande mail naar de klant); zonder import het adres van de klant (antwoord gaat direct naar de klant)
const toSupport = (t: Ticket, d: MailData) => testAddress(t.email) ? Promise.resolve(notSent("test_address")) :
  send(SUPPORT_EMAIL(), renderMail(d), { number: t.number, replyTo: imapConfigured() ? addressOf(SUPPORT_FROM()) : t.email, first: d.kind === "support_created", auto: true, kind: d.kind });
async function markMail(messageId: number, r: Sent) {
  await db.from("support_messages").update({ email_sent: r.ok, email_error: r.ok ? null : r.error ?? null, ...(r.messageId && r.ok ? { mail_message_id: r.messageId } : {}) }).eq("id", messageId);
}

// ---- build 146: pushmelding aan de eigenaar bij een antwoord van support ----
// Alleen voor tickets met een account (user_id). Eén melding per supportbericht (dedup_key support:<bericht-id>), naar alle
// push-apparaten van het account (functie push, docs/PUSH.md). Payload versleuteld: alleen nummer en onderwerp, nooit de
// tekst van het antwoord. Daarna wordt de functie push direct aangezet (admin_progress); lukt dat niet, dan verstuurt de
// cron van push hem binnen een minuut. Een fout hier houdt het antwoord (en de mail) nooit tegen.
function background(p: Promise<unknown>) {
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  const safe = p.catch((e) => console.error("support push achtergrond", e instanceof Error ? e.message.slice(0, 80) : "fout"));
  if (rt?.waitUntil) rt.waitUntil(safe);
}
async function notifyOwner(t: Ticket, messageId: number): Promise<number> {
  if (!t.user_id || isMailtestAddress(t.email)) return 0;
  try {
    const { data: m, error } = await db.from("push_messages").upsert({
      kind: "support_reply", dedup_key: supportKey(messageId), target: { accounts: [t.user_id] }, created_by: "support",
      payload: { sealed: await sealJsonField({ number: t.number, subject: t.subject }) },
    }, { onConflict: "dedup_key", ignoreDuplicates: true }).select("id");
    if (error) throw new Error(error.message);
    const id = m?.[0]?.id;
    if (!id) return 0;
    const { data: n, error: e2 } = await db.rpc("bingr_push_enqueue", { p_message: id, p_all: false, p_accounts: [t.user_id], p_platforms: null, p_below_build: null });
    if (e2) throw new Error(e2.message);
    await db.rpc("bingr_push_refresh", { p_ids: [id] });
    const devices = Number(n ?? 0);
    const secret = env("PUSH_ADMIN_SECRET");
    if (devices > 0 && secret) {
      background(fetch(`${env("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/push`, {
        method: "POST", signal: AbortSignal.timeout(30_000),
        headers: { "Content-Type": "application/json", "x-push-secret": secret, ...(env("SUPABASE_ANON_KEY") ? { apikey: env("SUPABASE_ANON_KEY") } : {}) },
        body: JSON.stringify({ action: "admin_progress", message_id: id }),
      }).then((r) => r.body?.cancel()));
    }
    return devices;
  } catch (e) {
    console.error("support push", e instanceof Error ? e.message.slice(0, 120) : "fout");
    return 0;
  }
}

// ---- server ----
Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json: Json = (body, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    // build 147: 80 KB (een bericht van max. 5000 tekens plus een diagnose-bijlage van max. 48 KB; build 146: 64 KB)
    if (text.length > 80 * 1024) return json({ error: "too_large" }, 413);
    body = JSON.parse(text || "{}");
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
  } catch { return json({ error: "bad_json" }, 400); }
  const action = String(body.action ?? "");
  try {
    if (action === "ping") return json({ ok: true });
    if (action === "challenge") {
      // build 95: captcha-opgave voor het formulier (geen inloggen nodig)
      const key = await challengeKey();
      if (!key) return json({ error: "unavailable" }, 503);
      return json(await makeChallenge(key));
    }
    if (action === "poll_inbox") {
      const secret = env("SUPPORT_CRON_SECRET");
      if (!secret || !sameText(req.headers.get("x-support-cron") ?? "", secret)) return json({ error: "forbidden" }, 403);
      // build 140: rooktest van de workflow Backend: ook de plusmap van een testadres (support+ci-…@ komt in INBOX.ci-…),
      // alleen met een geldige mailtest-sleutel
      let ciTag: string | null = null;
      if (typeof body.ci_tag === "string" && CI_TAG.test(body.ci_tag)) {
        if (!(await mailtestOk(req.headers.get(MAILTEST_HEADER), async () => (await db.from("app_settings").select("value").eq("key", "mailtest").maybeSingle()).data?.value))) {
          return json({ error: "forbidden" }, 403);
        }
        ciTag = body.ci_tag;
      }
      return json(await pollInbox(String(body.source ?? "cron").slice(0, 20), ciTag));
    }
    if (action.startsWith("admin_")) {
      const secret = env("SUPPORT_ADMIN_SECRET");
      if (!secret || !sameText(req.headers.get("x-support-secret") ?? "", secret)) {
        // mailtest: alleen antwoorden/status op een testticket (adres support+ci-…@bingr.online)
        if (!(action === "admin_reply" || action === "admin_status") || !req.headers.get(MAILTEST_HEADER)) return json({ error: "forbidden" }, 403);
        const n = parseNumber(body.number);
        const t = n ? await ticketByNumber(n) : null;
        if (!t || !isMailtestAddress(t.email) ||
          !(await mailtestOk(req.headers.get(MAILTEST_HEADER), async () => (await db.from("app_settings").select("value").eq("key", "mailtest").maybeSingle()).data?.value))) {
          return json({ error: "forbidden" }, 403);
        }
      }
      return await handleAdmin(action, body, json);
    }
    return await handleCustomer(req, action, body, json);
  } catch (e) {
    console.error("support", action, e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});

// build 95: p_window in seconden (standaard 60 = per minuut); de limieten hieronder zijn per uur (3600)
async function rateOk(key: string, max: number, windowS = 60) {
  const { data, error } = await db.rpc("bingr_rate_hit", { p_key: key, p_max: max, p_window: windowS });
  if (error) throw new Error(error.message);
  return data === true;
}
// build 95: sleutel voor de captcha, afgeleid van een bestaand geheim (BINGR_SOURCES_KEY, anders de service-role-sleutel)
let powKeyCache: Promise<CryptoKey | null> | null = null;
const challengeKey = () => (powKeyCache ??= powKey(env("BINGR_SOURCES_KEY") || env("SUPABASE_SERVICE_ROLE_KEY")));
/** Opgeloste captcha controleren en de salt als gebruikt markeren; false = ongeldig, verlopen of al gebruikt. */
async function powOk(pow: unknown): Promise<{ ok: boolean; reason: string }> {
  const key = await challengeKey();
  if (!key) return { ok: false, reason: "no_key" };
  const r = await verifyPow(key, pow);
  if (!r.ok) return { ok: false, reason: r.reason };
  const { error } = await db.from("support_pow_used").insert({ salt: r.salt });
  if (error) {
    if (error.code === "23505") return { ok: false, reason: "reused" };
    throw new Error(error.message);
  }
  return { ok: true, reason: "" };
}
/** Schijnbaar "gelukt" zonder iets op te slaan of te mailen (build 93: lokveld; build 95: ook zonder geldige captcha),
 *  met dezelfde vorm en een korte wachttijd, zodat een bot niet merkt dat hij is tegengehouden. */
async function fakeCreated(json: Json) {
  await new Promise((r) => setTimeout(r, 600 + Math.floor(Math.random() * 900)));
  const fakeNo = 1000 + Math.floor(Math.random() * 9000), fakeTok = randomToken();
  return json({ ok: true, number: fakeNo, token: fakeTok, url: ticketUrl(SUPPORT_SITE, fakeNo, fakeTok), email_sent: true });
}
async function countSince(filter: (q: any) => any) {
  const { count, error } = await filter(db.from("support_tickets").select("id", { count: "exact", head: true }).gte("created_at", hourAgo()));
  if (error) throw new Error(error.message);
  return count ?? 0;
}

async function handleCustomer(req: Request, action: string, body: Record<string, unknown>, json: Json): Promise<Response> {
  const ip = clientIp(req);
  switch (action) {
    case "create": {
      const v = validateCreate(body);
      if (!v.ok && v.error === "spam") {
        // build 93: lokveld ingevuld of te snel verstuurd → niets opslaan of mailen, maar wel "gelukt" antwoorden (met
        // dezelfde vorm en een korte wachttijd), zodat een bot niet merkt dat hij is tegengehouden en het niet anders probeert
        console.log("support: spam tegengehouden", JSON.stringify({ hp: String(body.website ?? "").trim() !== "", ms: body.elapsed_ms ?? null }));
        return await fakeCreated(json);
      }
      if (!v.ok) return json({ error: v.error, field: v.field }, 400);
      // build 95: captcha (proof-of-work). Geen app roept create zelf aan (de apps openen support.bingr.online), dus
      // geen uitzondering: ontbreekt of klopt hij niet, dan net als het lokveld stil tegenhouden.
      const pw = await powOk(body.pow);
      if (!pw.ok) {
        console.log("support: captcha ongeldig", JSON.stringify({ reason: pw.reason }));
        return await fakeCreated(json);
      }
      const user = await userFrom(req);
      const input = v.value;
      // ingelogd: altijd het (bevestigde) adres van het account, zodat "Mijn tickets" en de mails kloppen
      if (user?.email) input.email = user.email.toLowerCase();
      const ih = await ipHash(ip);
      // build 95: limieten echt per uur (bingr_rate_hit telde per minuut), per IP en per e-mailadres; geen globale grens
      // meer die iedereen buitensluit (zie GLOBAL_CONFIRM_CAP)
      if (!(await rateOk(`support:create:${ih}`, 5, 3600))) return json({ error: "rate_limited" }, 429);
      const [byIp, byEmail] = await Promise.all([countSince((q) => q.eq("ip_hash", ih)), countSince((q) => q.eq("email", input.email))]);
      if (byIp >= 5 || byEmail >= 3) return json({ error: "rate_limited" }, 429);
      // gekozen apparaat: alleen als het van deze gebruiker is; naam, platform en systeemversie dan uit account_devices
      let device: DeviceRow | null = null;
      if (user && input.device_id) {
        const { data: d } = await db.from("account_devices").select("device_id,name,platform,app_version,os_version,last_seen_at")
          .eq("user_id", user.id).eq("device_id", input.device_id).maybeSingle();
        device = (d as DeviceRow | null) ?? null;
      }
      const token = randomToken();
      const { data, error } = await db.from("support_tickets").insert({
        user_id: user?.id ?? null, email: input.email, name: input.name, subject: input.subject, category: input.category,
        platform: (device && deviceKind(device.platform)) || input.platform, app_version: input.app_version, lang: input.lang, access_token: token, ip_hash: ih,
        device_id: device?.device_id ?? null, device_name: device ? (device.name || "").slice(0, 80) || null : null,
        os_version: device ? (device.os_version || "").slice(0, 40) || null : null,
      }).select("*").single();
      if (error) throw new Error(error.message);
      const t = data as Ticket;
      // build 95: lukt het bericht niet, dan ook geen ticket zonder bericht (zoals bij een ticket uit een mail)
      let mid: number;
      try { mid = await addMessage(t.id, "customer", input.message, "web"); }
      catch (e) { await db.from("support_tickets").delete().eq("id", t.id); throw e; }
      // build 95: de bevestiging bevat alleen voor een ingelogde klant met een aantoonbaar bevestigd adres het onderwerp en
      // bericht (security H1: met autoconfirm is email_confirmed_at geen bewijs, zie emailProven); een gast of een account
      // zonder bewezen adres krijgt alleen nummer, een neutrale regel en de link
      const full = emailProven(user, await requireConfirm());
      const confirm = await confirmAllowed();
      if (!confirm) console.log("support: globale grens bereikt, geen bevestiging", t.number);
      const [c, s] = await Promise.all([
        confirm ? toCustomer(t, mailData(t, "customer_created", full ? { body: input.message } : { minimal: true })) : Promise.resolve(notSent("global_cap")),
        toSupport(t, mailData(t, "support_created", { body: input.message })),
      ]);
      await markMail(mid, { ok: c.ok && s.ok, error: [c.error && `klant: ${c.error}`, s.error && `support: ${s.error}`].filter(Boolean).join(" · ") || undefined });
      return json({ ok: true, number: t.number, token, url: ticketUrl(SUPPORT_SITE, t.number, token), email_sent: c.ok });
    }
    case "mine": {
      const user = await userOrBanned(req);
      if (user === "banned") return json(BANNED_BODY, 401);
      if (!user) return json({ error: "not_signed_in" }, 401);
      // security H1: alleen tickets van dit account (user_id), nooit op e-mailadres
      const { data, error } = await db.from("support_tickets").select(`${PUBLIC_FIELDS},access_token,customer_seen_at`).eq("user_id", user.id)
        .order("last_reply_at", { ascending: false }).limit(100);
      if (error) throw new Error(error.message);
      return json({
        items: (data ?? []).map((t) => ({
          number: t.number, subject: t.subject, status: t.status, category: t.category, created_at: t.created_at,
          last_reply_at: t.last_reply_at, token: t.access_token,
          unread: !!t.last_support_at && (!t.customer_seen_at || t.last_support_at > t.customer_seen_at),
        })),
      });
    }
    case "my_devices": {
      const user = await userOrBanned(req);
      if (user === "banned") return json(BANNED_BODY, 401);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const { data, error } = await db.from("account_devices").select("device_id,name,platform,app_version,os_version,last_seen_at")
        .eq("user_id", user.id).order("last_seen_at", { ascending: false }).limit(50);
      if (error) throw new Error(error.message);
      return json({ ...myDevices((data ?? []) as DeviceRow[]), known: await knownBuilds() });
    }
    case "versions":
      return json({ known: await knownBuilds() });
    case "get": {
      if (!(await rateOk(`support:get:${await ipHash(ip)}`, 60))) return json({ error: "rate_limited" }, 429); // per minuut
      const r = await customerTicket(req, body);
      if (!r) return json({ error: "not_found" }, 404);
      const { t, user, viaLink } = r;
      await db.from("support_tickets").update({ customer_seen_at: nowIso() }).eq("id", t.id);
      const pub = Object.fromEntries(PUBLIC_FIELDS.split(",").map((k) => [k, (t as Record<string, unknown>)[k]]));
      const linked = ownsTicket(user?.id, t.user_id);
      return json({
        ticket: { ...pub, token: t.access_token, can_reply: t.status !== "closed", linked, can_link: viaLink && !!user && !t.user_id },
        messages: await messagesOf(t.id, false),
      });
    }
    case "link": {
      // security H1: een ticket alleen aan je account koppelen met de geheime link uit de mail (bewijs dat je die mail hebt)
      if (!(await rateOk(`support:get:${await ipHash(ip)}`, 60))) return json({ error: "rate_limited" }, 429); // per minuut
      const user = await userOrBanned(req);
      if (user === "banned") return json(BANNED_BODY, 401);
      if (!user) return json({ error: "not_signed_in" }, 401);
      const r = await customerTicket(req, body);
      if (!r || !r.viaLink) return json({ error: "not_found" }, 404);
      const { t } = r;
      if (t.user_id === user.id) return json({ ok: true, already: true });
      if (t.user_id) return json({ error: "linked_elsewhere" }, 409);
      const { data, error } = await db.from("support_tickets").update({ user_id: user.id, updated_at: nowIso() }).eq("id", t.id).is("user_id", null).select("id");
      if (error) throw new Error(error.message);
      if (!data?.length) return json({ error: "linked_elsewhere" }, 409);
      return json({ ok: true });
    }
    case "reply": {
      const v = validateMessage(body.message);
      if (!v.ok) return json({ error: v.error, field: v.field }, 400);
      const r = await customerTicket(req, body);
      if (!r) return json({ error: "not_found" }, 404);
      const { t } = r;
      if (t.status === "closed") return json({ error: "closed" }, 409);
      if (!(await rateOk(`support:reply:${t.id}`, 4))) return json({ error: "rate_limited" }, 429); // per minuut
      const { count } = await db.from("support_messages").select("id", { count: "exact", head: true })
        .eq("ticket_id", t.id).eq("author", "customer").gte("created_at", hourAgo());
      if ((count ?? 0) >= 20) return json({ error: "rate_limited" }, 429);
      const status = statusAfter(t.status, "customer");
      const now = nowIso();
      const mid = await addMessage(t.id, "customer", v.value, "web");
      if (status !== t.status) await addMessage(t.id, "event", status);
      await db.from("support_tickets").update({ status, updated_at: now, last_reply_at: now, last_customer_at: now, customer_seen_at: now, closed_at: null }).eq("id", t.id);
      const nt = { ...t, status };
      await markMail(mid, await toSupport(nt, mailData(nt, "support_reply", { body: v.value })));
      return json({ ok: true, status });
    }
    case "close": {
      const r = await customerTicket(req, body);
      if (!r) return json({ error: "not_found" }, 404);
      const { t } = r;
      if (t.status === "closed") return json({ ok: true, status: "closed" });
      const now = nowIso();
      await db.from("support_tickets").update({ status: "closed", closed_at: now, updated_at: now }).eq("id", t.id);
      const mid = await addMessage(t.id, "event", "closed");
      const nt = { ...t, status: "closed" as Status };
      await markMail(mid, await toSupport(nt, mailData(nt, "support_closed")));
      return json({ ok: true, status: "closed" });
    }
    case "app_list": case "app_get": case "app_mark_read": case "app_reply": case "app_create": case "app_close":
      return await handleApp(req, action, body, json);
    default:
      return json({ error: "unknown_action" }, 400);
  }
}

// ---- build 146: support vanuit de app (docs/ACCOUNT.md "Build 146" → "Support vanuit de app") ----
// Altijd met de sessie van het account (Authorization: Bearer <access_token>); eigenaar alleen via user_id (security H1),
// nooit via e-mailadres of de geheime link. Een ticket van een ander account (of dat niet bestaat) = 404 not_found.
const APP_TICKET_FIELDS = "id,number,user_id,email,name,subject,category,platform,app_version,device_name,device_type,device_model,os_version,status,lang,access_token,created_at,updated_at,last_reply_at,last_support_at,customer_seen_at,closed_at";
const appTicket = (t: Record<string, unknown>, unread?: number) => ({
  number: t.number, subject: t.subject, status: t.status, group: statusGroup(t.status), category: t.category, platform: t.platform ?? null,
  app_version: t.app_version ?? null, device_name: t.device_name ?? null, device_type: t.device_type ?? null, device_model: t.device_model ?? null,
  os_version: t.os_version ?? null, created_at: t.created_at, last_reply_at: t.last_reply_at, closed_at: t.closed_at ?? null,
  can_reply: t.status !== "closed",
  ...(unread !== undefined ? { unread_count: unread, unread: unread > 0 } : {}),
});
// limieten voor een nieuw ticket uit de app (geen captcha): per account 5 per uur en 15 per dag, per IP 10 per uur
const APP_CREATE_PER_HOUR = 5, APP_CREATE_PER_DAY = 15, APP_CREATE_PER_IP_HOUR = 10;

async function handleApp(req: Request, action: string, body: Record<string, unknown>, json: Json): Promise<Response> {
  const user = await userOrBanned(req);
  if (user === "banned") return json(BANNED_BODY, 401);
  if (!user) return json({ error: "not_signed_in" }, 401);
  if (!(await rateOk(`support:app:${user.id}`, 120))) return json({ error: "rate_limited" }, 429); // per minuut, alle acties samen
  const own = async (): Promise<Ticket | null> => {
    const n = parseNumber(body.number ?? body.n);
    if (!n) return null;
    const { data, error } = await db.from("support_tickets").select("*").eq("number", n).eq("user_id", user.id).maybeSingle();
    if (error) throw new Error(error.message);
    return data as Ticket | null;
  };
  // diagnose-bijlage (optioneel): opschonen volgens het schema; ongeldige kern = 400, te groot = 413
  const diag = (): { ok: true; value: Record<string, unknown> | null; note: "accepted" | "stripped" | null } | { ok: false; res: Response } => {
    if (body.diagnostics == null) return { ok: true, value: null, note: null };
    const d = cleanDiagnostics(body.diagnostics);
    if (!d.ok) return { ok: false, res: json({ error: d.error, field: d.field ?? "diagnostics" }, d.error === "diagnostics_too_large" ? 413 : 400) };
    return { ok: true, value: d.value, note: d.stripped ? "stripped" : "accepted" };
  };

  switch (action) {
    case "app_list": {
      const filter = String(body.status ?? "all");
      let q = db.from("support_tickets").select(APP_TICKET_FIELDS).eq("user_id", user.id);
      if (filter in STATUS_GROUPS) q = q.in("status", STATUS_GROUPS[filter as StatusGroup]);
      else if (filter !== "all") return json({ error: "bad_status" }, 400);
      const { data, error } = await q.order("last_reply_at", { ascending: false }).limit(200);
      if (error) throw new Error(error.message);
      const tickets = (data ?? []) as (Ticket & { customer_seen_at: string | null })[];
      // ongelezen = antwoorden van support na het laatst openen (ook voor de teller op de tab en apparaten zonder push)
      let msgs: { ticket_id: string; created_at: string }[] = [];
      if (tickets.length) {
        const { data: m, error: me } = await db.from("support_messages").select("ticket_id,created_at")
          .in("ticket_id", tickets.map((t) => t.id)).eq("author", "support").limit(5000);
        if (me) throw new Error(me.message);
        msgs = (m ?? []) as typeof msgs;
      }
      const unread = unreadCounts(tickets, msgs);
      // tellers altijd over alle eigen tickets (ook met een filter)
      const { data: all } = filter === "all" ? { data: tickets } : await db.from("support_tickets").select("id,status").eq("user_id", user.id).limit(1000);
      const counts = { open: 0, in_progress: 0, closed: 0, unread: 0 };
      for (const t of (all ?? []) as { status: string }[]) counts[statusGroup(t.status)]++;
      const items = tickets.map((t) => appTicket(t as unknown as Record<string, unknown>, unread.get(t.id) ?? 0));
      counts.unread = filter === "all" ? items.reduce((n, t) => n + (t.unread ? 1 : 0), 0) : await (async () => {
        const { data: ids } = await db.from("support_tickets").select("id,customer_seen_at").eq("user_id", user.id).limit(1000);
        const list = (ids ?? []) as { id: string; customer_seen_at: string | null }[];
        if (!list.length) return 0;
        const { data: m } = await db.from("support_messages").select("ticket_id,created_at").in("ticket_id", list.map((t) => t.id)).eq("author", "support").limit(5000);
        return [...unreadCounts(list, (m ?? []) as typeof msgs).values()].filter((n) => n > 0).length;
      })();
      return json({ items, counts });
    }
    case "app_get": {
      const t = await own();
      if (!t) return json({ error: "not_found" }, 404);
      if (body.mark_read !== false) await db.from("support_tickets").update({ customer_seen_at: nowIso() }).eq("id", t.id);
      return json({ ticket: appTicket(t as unknown as Record<string, unknown>), messages: await messagesOf(t.id, false) });
    }
    case "app_mark_read": {
      const t = await own();
      if (!t) return json({ error: "not_found" }, 404);
      await db.from("support_tickets").update({ customer_seen_at: nowIso() }).eq("id", t.id);
      return json({ ok: true });
    }
    case "app_reply": {
      const v = validateMessage(body.message);
      if (!v.ok) return json({ error: v.error, field: v.field }, 400);
      const d = diag();
      if (!d.ok) return d.res;
      const t = await own();
      if (!t) return json({ error: "not_found" }, 404);
      if (t.status === "closed") return json({ error: "closed" }, 409);
      if (!(await rateOk(`support:reply:${t.id}`, 4))) return json({ error: "rate_limited" }, 429); // per minuut
      const { count } = await db.from("support_messages").select("id", { count: "exact", head: true })
        .eq("ticket_id", t.id).eq("author", "customer").gte("created_at", hourAgo());
      if ((count ?? 0) >= 20) return json({ error: "rate_limited" }, 429);
      const status = statusAfter(t.status, "customer");
      const now = nowIso();
      const mid = await addMessage(t.id, "customer", v.value, "app", undefined, d.value);
      if (status !== t.status) await addMessage(t.id, "event", status);
      await db.from("support_tickets").update({ status, updated_at: now, last_reply_at: now, last_customer_at: now, customer_seen_at: now, closed_at: null }).eq("id", t.id);
      const nt = { ...t, status };
      await markMail(mid, await toSupport(nt, mailData(nt, "support_reply", { body: v.value })));
      return json({ ok: true, status, group: statusGroup(status), diagnostics: d.note });
    }
    case "app_close": {
      const t = await own();
      if (!t) return json({ error: "not_found" }, 404);
      if (t.status === "closed") return json({ ok: true, status: "closed", group: "closed" });
      const now = nowIso();
      await db.from("support_tickets").update({ status: "closed", closed_at: now, updated_at: now }).eq("id", t.id);
      const mid = await addMessage(t.id, "event", "closed");
      const nt = { ...t, status: "closed" as Status };
      await markMail(mid, await toSupport(nt, mailData(nt, "support_closed")));
      return json({ ok: true, status: "closed", group: "closed" });
    }
    case "app_create": {
      if (!user.email) return json({ error: "not_signed_in" }, 401);
      const d = diag();
      if (!d.ok) return d.res;
      const dv = d.value as { app?: { platform?: string; version?: string; build?: number }; device?: { type?: string; model?: string; os?: string; osVersion?: string } } | null;
      // zelfde controle als het formulier, met naam en adres van het account (geen lokveld, geen captcha)
      const v = validateCreate({
        name: accountName((user as { user_metadata?: unknown }).user_metadata), email: user.email, category: body.category,
        platform: body.platform ?? ticketPlatform(dv?.app?.platform), app_version: body.app_version ?? versionFromDiag(dv),
        subject: body.subject, message: body.message, lang: body.lang, device_id: body.device_id,
      });
      if (!v.ok) return json({ error: v.error, field: v.field }, 400);
      const ih = await ipHash(clientIp(req));
      if (!(await rateOk(`support:app-create:h:${user.id}`, APP_CREATE_PER_HOUR, 3600)) || !(await rateOk(`support:app-create:d:${user.id}`, APP_CREATE_PER_DAY, 86400))
        || !(await rateOk(`support:app-create:ip:${ih}`, APP_CREATE_PER_IP_HOUR, 3600))) return json({ error: "rate_limited" }, 429);
      const input = v.value;
      let device: DeviceRow | null = null;
      if (input.device_id) {
        const { data: dr } = await db.from("account_devices").select("device_id,name,platform,app_version,os_version,last_seen_at")
          .eq("user_id", user.id).eq("device_id", input.device_id).maybeSingle();
        device = (dr as DeviceRow | null) ?? null;
      }
      const token = randomToken();
      const { data, error } = await db.from("support_tickets").insert({
        user_id: user.id, email: input.email, name: input.name, subject: input.subject, category: input.category,
        platform: (device && deviceKind(device.platform)) || input.platform, app_version: input.app_version || device?.app_version || null,
        lang: input.lang, access_token: token, ip_hash: ih, source: "app",
        device_id: device?.device_id ?? null, device_name: device ? (device.name || "").slice(0, 80) || null : null,
        os_version: (device?.os_version || "").slice(0, 40) || osFromDiag(dv),
        device_type: dv?.device?.type ?? null, device_model: dv?.device?.model ?? null,
      }).select("*").single();
      if (error) throw new Error(error.message);
      const t = data as Ticket;
      let mid: number;
      try { mid = await addMessage(t.id, "customer", input.message, "app", undefined, d.value); }
      catch (e) { await db.from("support_tickets").delete().eq("id", t.id); throw e; }
      const full = emailProven(user, await requireConfirm());
      const confirm = await confirmAllowed();
      const [c, sp] = await Promise.all([
        confirm ? toCustomer(t, mailData(t, "customer_created", full ? { body: input.message } : { minimal: true })) : Promise.resolve(notSent("global_cap")),
        toSupport(t, mailData(t, "support_created", { body: input.message })),
      ]);
      await markMail(mid, { ok: c.ok && sp.ok, error: [c.error && `klant: ${c.error}`, sp.error && `support: ${sp.error}`].filter(Boolean).join(" · ") || undefined });
      return json({ ok: true, number: t.number, status: t.status, group: statusGroup(t.status), email_sent: c.ok, diagnostics: d.note });
    }
  }
  return json({ error: "unknown_action" }, 400);
}

async function handleAdmin(action: string, body: Record<string, unknown>, json: Json): Promise<Response> {
  const counts = async () => {
    const { data, error } = await db.rpc("bingr_support_counts");
    if (error) throw new Error(error.message);
    return data;
  };
  if (action === "admin_counts") return json({ ...(await counts()), smtp: smtpConfigured() });
  if (action === "admin_inbox") return json(await inboxStatus());
  if (action === "admin_poll") return json(await pollInbox("admin"));
  if (action === "admin_list") {
    const size = Math.min(Math.max(Number(body.page_size ?? 50) || 50, 1), 100);
    const page = Math.max(Math.floor(Number(body.page ?? 0) || 0), 0);
    const st = String(body.status ?? "active");
    let q = db.from("support_tickets")
      .select("number,subject,email,name,status,priority,category,platform,lang,user_id,created_at,updated_at,last_reply_at,last_customer_at,last_support_at,admin_seen_at,source,device_type,device_model,os_version", { count: "exact" });
    if (st === "active") q = q.in("status", ["new", "open", "pending"]);
    else if (isStatus(st)) q = q.eq("status", st);
    const n = parseNumber(body.q);
    const s = safeSearch(body.q);
    if (n) q = q.eq("number", n);
    else if (s) q = q.or(`subject.ilike.*${s}*,email.ilike.*${s}*,name.ilike.*${s}*`);
    const { data, error, count } = await q.order("last_reply_at", { ascending: false }).range(page * size, page * size + size - 1);
    if (error) throw new Error(error.message);
    const items = (data ?? []).map(({ admin_seen_at, user_id, ...t }) => ({
      ...t, has_account: !!user_id,
      unread: (t.status === "new" || t.status === "open") && (!admin_seen_at || t.last_customer_at > admin_seen_at),
    }));
    return json({ total: count ?? 0, page, page_size: size, items, counts: await counts(), smtp: smtpConfigured() });
  }

  const n = parseNumber(body.number);
  if (!n) return json({ error: "bad_number" }, 400);
  const t = await ticketByNumber(n);
  if (!t) return json({ error: "not_found" }, 404);
  const now = nowIso();

  switch (action) {
    case "admin_get": {
      await db.from("support_tickets").update({ admin_seen_at: now }).eq("id", t.id);
      const { data: account } = await db.rpc("bingr_support_account", { p_user: t.user_id, p_email: t.email });
      const { access_token, ip_hash: _ip, ...rest } = t as Ticket & { ip_hash?: string };
      return json({
        ticket: { ...rest, customer_url: ticketUrl(SUPPORT_SITE, t.number, access_token) },
        messages: await messagesOf(t.id, true), account: account ?? null, smtp: smtpConfigured(),
      });
    }
    case "admin_reply": {
      const v = validateMessage(body.message);
      if (!v.ok) return json({ error: v.error }, 400);
      const chosen = body.status == null || body.status === "" ? null : body.status;
      if (chosen !== null && !isStatus(chosen)) return json({ error: "bad_status" }, 400);
      const status = statusAfter(t.status, "support", chosen as Status | null);
      const mid = await addMessage(t.id, "support", v.value, "admin");
      if (status !== t.status) await addMessage(t.id, "event", status);
      await db.from("support_tickets").update({
        status, updated_at: now, last_reply_at: now, last_support_at: now, admin_seen_at: now,
        closed_at: status === "closed" ? now : null,
      }).eq("id", t.id);
      const nt = { ...t, status };
      const [r, pushed] = await Promise.all([toCustomer(nt, mailData(nt, "customer_reply", { body: v.value })), notifyOwner(nt, mid)]);
      await markMail(mid, r);
      return json({ ok: true, status, email_sent: r.ok, email_error: r.error ?? null, push_devices: pushed });
    }
    case "admin_status": {
      const upd: Record<string, unknown> = { updated_at: now };
      let status = t.status;
      if (body.status != null) {
        if (!isStatus(body.status)) return json({ error: "bad_status" }, 400);
        status = body.status;
        upd.status = status;
        upd.closed_at = status === "closed" ? now : null;
      }
      if (body.priority != null) {
        if (!(PRIORITIES as readonly string[]).includes(String(body.priority))) return json({ error: "bad_priority" }, 400);
        upd.priority = body.priority;
      }
      await db.from("support_tickets").update(upd).eq("id", t.id);
      let sent: Sent | null = null;
      if (status !== t.status) {
        const mid = await addMessage(t.id, "event", status);
        if ((status === "resolved" || status === "closed") && body.notify !== false) {
          const nt = { ...t, status };
          sent = await toCustomer(nt, mailData(nt, "customer_status"));
          await markMail(mid, sent);
        }
      }
      return json({ ok: true, status, priority: upd.priority ?? t.priority, email_sent: sent ? sent.ok : null, email_error: sent?.error ?? null });
    }
    case "admin_note": {
      const v = validateMessage(body.message);
      if (!v.ok) return json({ error: v.error }, 400);
      await addMessage(t.id, "note", v.value, "admin");
      await db.from("support_tickets").update({ admin_seen_at: now }).eq("id", t.id);
      return json({ ok: true });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}

// ---- inbox-import (IMAP) ----
const IMAP_BUDGET_MS = 45000; // daarna stoppen; de rest komt bij de volgende ronde
const IMAP_MAX_PER_RUN = 25;
// adressen die als support mogen antwoorden: het supportadres zelf (afzender, meldingen, IMAP-login) plus BINGR_SUPPORT_AGENTS;
// niet BINGR_SMTP_FROM (bv. noreply@): onze eigen mails herkennen we aan X-Bingr-Ticket
const ownAddresses = () => [SUPPORT_EMAIL(), addressOf(SUPPORT_FROM()), env("BINGR_IMAP_USER")];
const agents = () => agentList(ownAddresses(), env("BINGR_SUPPORT_AGENTS"));
// build 95: namen van onze ontvangende mailserver in Authentication-Results (alleen dan telt een agent-antwoord)
const authserv = () => authservNames(env("BINGR_IMAP_HOST"), env("BINGR_SUPPORT_AUTHSERV"));
const errText = (e: unknown) => (e instanceof Error ? e.message : String(e)).replace(/[\r\n]+/g, " ").slice(0, 300);

type InboxResult = { result: string; ticket?: number | null; detail?: string; seen: boolean; move: boolean };
type Counts = Record<"fetched" | "imported" | "agent" | "new_tickets" | "ignored" | "rejected" | "duplicates" | "errors", number>;

async function inboxStatus() {
  const [{ data: state }, { data: log }] = await Promise.all([
    db.from("support_inbox_state").select("mailbox,uidvalidity,last_uid,last_poll_at,last_ok_at,last_import_at,last_error,last_error_at,last_result,last_source").eq("id", 1).maybeSingle(),
    db.from("support_inbox_log").select("at,sender,subject,result,ticket_number,detail").order("at", { ascending: false }).limit(15),
  ]);
  return {
    configured: imapConfigured(), smtp: smtpConfigured(), host: env("BINGR_IMAP_HOST") || null, user: env("BINGR_IMAP_USER") || null,
    agents: agents().length, extra_agents: !!env("BINGR_SUPPORT_AGENTS").trim(), cron: !!env("SUPPORT_CRON_SECRET"),
    state: state ?? null,
    log: await Promise.all((log ?? []).map(async (l) => ({ ...l, sender: await openField(l.sender), subject: await openField(l.subject), detail: await openField(l.detail) }))),
  };
}

async function inboxLog(uid: number, mail: ParsedMail | null, r: InboxResult, folder = "INBOX", uidvalidity: number | null = null) {
  await db.from("support_inbox_log").insert({
    // build 146: afzender, onderwerp en detail versleuteld (het beheer toont ze via admin_inbox)
    uid, folder: folder.slice(0, 200), uidvalidity, message_id: mail?.messageId?.slice(0, 300) || null, sender: await sealField(mail?.from?.address?.slice(0, 254) ?? null),
    subject: await sealField(mail?.subject?.slice(0, 200) ?? null), result: r.result, ticket_number: r.ticket ?? null, detail: await sealField(r.detail?.slice(0, 300) ?? null),
  });
}

async function pollInbox(source: string, ciTag: string | null = null) {
  if (!imapConfigured()) return { skipped: "imap not configured" };
  // nooit twee rondes tegelijk (pg_cron + knop in het beheer): korte lease in support_inbox_state
  const { data: got, error: lockErr } = await db.rpc("bingr_support_inbox_lock", { p_seconds: 120 });
  if (lockErr) throw new Error(lockErr.message);
  if (got !== true) return { ok: true, busy: true };
  const started = Date.now();
  const counts: Counts = { fetched: 0, imported: 0, agent: 0, new_tickets: 0, ignored: 0, rejected: 0, duplicates: 0, errors: 0 };
  // per reden (alleen codes, geen adressen of onderwerpen), en hoeveel er nog wachten
  const reasons: Record<string, number> = {};
  let inboxTotal = 0, pending = 0, keywords = false;
  let imap: Imap | null = null;
  const upd: Record<string, unknown> = { last_poll_at: nowIso(), last_source: source };
  let cleanupAt: string | null = null;
  try {
    const { data: state } = await db.from("support_inbox_state").select("last_uid,error_uid,error_count,last_cleanup_at").eq("id", 1).maybeSingle();
    cleanupAt = state?.last_cleanup_at ?? null;
    imap = await Imap.connect({ host: env("BINGR_IMAP_HOST"), port: Number(env("BINGR_IMAP_PORT") || 993), timeoutMs: 20000 });
    await imap.login(env("BINGR_IMAP_USER"), env("BINGR_IMAP_PASSWORD"));
    const boxes = await imap.list().catch(() => []);
    const done = findFolder(boxes);
    const ciBox = ciTag ? findCiFolder(boxes, ciTag) : null;
    // build 140: geen cursor meer (last_uid / alleen ongelezen van 7 dagen): alle mails zonder $BingrDone, oudste eerst
    const folders = ciTag ? ["INBOX", ...(ciBox ? [ciBox] : [])] : ["INBOX"];
    let lastUid = Number(state?.last_uid ?? 0), uidvalidity: number | null = null, stopped = false, moved: string | null = null;
    for (const box of folders) {
      if (stopped || Date.now() - started > IMAP_BUDGET_MS) { stopped = true; break; }
      const sel = await imap.select(box);
      if (box === "INBOX") { uidvalidity = sel.uidvalidity; inboxTotal = sel.exists; }
      const kw = keywordAllowed(sel.permanentFlags);
      if (box === "INBOX") keywords = kw;
      const cands = sel.exists ? await imap.uidSearch(`NOT KEYWORD ${DONE_KEYWORD}`) : [];
      // vangnet (server zonder trefwoorden, of het zetten mislukte): wat volgens het logboek al definitief is, overslaan
      const doneInLog = new Set<number>();
      for (let i = 0; i < cands.length; i += 500) {
        const { data, error } = await db.from("support_inbox_log").select("uid,result").eq("folder", box).eq("uidvalidity", sel.uidvalidity ?? 0)
          .in("uid", cands.slice(i, i + 500)).limit(5000);
        if (error) throw new Error(error.message);
        for (const r of data ?? []) if (isFinal(String(r.result))) doneInLog.add(Number(r.uid));
      }
      // limiet per afzender: pas na een uur opnieuw (anders elke 5 minuten een logregel)
      const { data: limited } = cands.length
        ? await db.from("support_inbox_log").select("uid").eq("folder", box).eq("uidvalidity", sel.uidvalidity ?? 0).eq("result", "rejected:rate_limited")
          .gte("at", hourAgo()).in("uid", cands.slice(0, 500)).limit(500)
        : { data: [] };
      for (const r of limited ?? []) doneInLog.add(Number(r.uid));
      const { queue, pending: p } = pickQueue(cands, doneInLog, IMAP_MAX_PER_RUN - counts.fetched);
      pending += p;
      const seen: number[] = [], move: number[] = [], final: number[] = [];
      for (const uid of queue) {
        if (Date.now() - started > IMAP_BUDGET_MS) { stopped = true; break; }
        let mail: ParsedMail | null = null;
        let r: InboxResult;
        try {
          const [it] = await imap.uidFetch([uid], `(UID RFC822.SIZE BODY.PEEK[]<0.${MAX_FETCH_BYTES}>)`);
          if (!it?.body) { r = { result: "error:retry", detail: "geen inhoud", seen: false, move: false }; }
          else {
            counts.fetched++;
            mail = parseMessage(it.body, { truncated: (it.size ?? 0) > MAX_FETCH_BYTES });
            if (!mail.messageId) mail.messageId = `<imap-${sel.uidvalidity}-${uid}@bingr.invalid>`;
            r = await handleMail(mail, { ci: box !== "INBOX" });
          }
        } catch (e) {
          // databasefout of iets onverwachts: deze mail de volgende ronde opnieuw; lukt het drie rondes achter elkaar niet,
          // dan overslaan (blijft in de mailbox, met $BingrDone) zodat de rest niet blijft hangen
          console.error("support inbox", uid, errText(e));
          const tries = Number(state?.error_uid) === uid ? Number(state?.error_count ?? 0) + 1 : 1;
          if (tries < 3) {
            counts.errors++;
            await inboxLog(uid, mail, { result: "error", detail: `poging ${tries}: ${errText(e)}`, seen: false, move: false }, box, sel.uidvalidity).catch(() => {});
            Object.assign(upd, { error_uid: uid, error_count: tries });
            stopped = true;
            break;
          }
          r = { result: "error:skipped", detail: `overgeslagen na ${tries} pogingen: ${errText(e)}`, seen: false, move: false };
        }
        await inboxLog(uid, mail, r, box, sel.uidvalidity).catch((e) => console.error("support inbox log", errText(e)));
        const key = r.result.split(":")[0];
        if (key === "imported") counts.imported++;
        else if (key === "agent") counts.agent++;
        else if (key === "new_ticket") counts.new_tickets++;
        else if (key === "ignored") counts.ignored++;
        else if (key === "duplicate") counts.duplicates++;
        else if (key === "error") counts.errors++;
        else counts.rejected++;
        if (key === "ignored" || key === "rejected" || key === "error") reasons[r.result] = (reasons[r.result] ?? 0) + 1;
        if (isFinal(r.result)) { final.push(uid); pending--; }
        if (r.seen) seen.push(uid);
        if (r.move) move.push(uid);
        if (box === "INBOX") lastUid = Math.max(lastUid, uid);
      }
      // eerst de vlaggen (blijven bij MOVE behouden), dan verplaatsen
      const seenSet = new Set(seen);
      if (kw) {
        const both = final.filter((u) => seenSet.has(u)), only = final.filter((u) => !seenSet.has(u));
        if (both.length) await imap.uidStore(both, `+FLAGS.SILENT (\\Seen ${DONE_KEYWORD})`);
        if (only.length) await imap.uidStore(only, `+FLAGS.SILENT (${DONE_KEYWORD})`);
        const rest = seen.filter((u) => !final.includes(u));
        if (rest.length) await imap.uidStore(rest, "+FLAGS.SILENT (\\Seen)");
      } else if (seen.length) await imap.uidStore(seen, "+FLAGS.SILENT (\\Seen)");
      if (move.length && done && box === "INBOX") moved = await imap.uidMove(move, done);
    }
    await imap.logout();
    imap = null;
    const result = { ...counts, reasons, inbox: inboxTotal, pending: Math.max(0, pending), keywords, moved, more: stopped || pending > 0, ms: Date.now() - started };
    Object.assign(upd, {
      mailbox: done ? `INBOX → ${done}` : "INBOX", last_ok_at: nowIso(),
      uidvalidity, last_uid: lastUid, scan_until: null, scan_cursor: null,
      ...(stopped && counts.errors ? {} : { error_uid: null, error_count: 0 }),
      last_error: counts.errors ? "Een mail gaf een fout; volgende ronde opnieuw (zie logboek)" : null, last_error_at: counts.errors ? nowIso() : null,
      last_result: result,
      ...(counts.imported + counts.agent + counts.new_tickets ? { last_import_at: nowIso() } : {}),
    });
    return { ok: true, ...result, folder: done, ci_folder: ciTag ? !!ciBox : undefined };
  } catch (e) {
    const msg = errText(e);
    console.error("support inbox", msg);
    Object.assign(upd, { last_error: msg, last_error_at: nowIso(), last_result: { ...counts, reasons, ms: Date.now() - started } });
    return { ok: false, error: msg, ...counts };
  } finally {
    imap?.close();
    // logboek kort houden (30 dagen); build 95: hooguit één keer per dag in plaats van elke ronde
    if (!cleanupAt || Date.now() - Date.parse(cleanupAt) > 864e5) {
      const { error } = await db.from("support_inbox_log").delete().lt("at", new Date(Date.now() - 30 * 864e5).toISOString());
      if (!error) upd.last_cleanup_at = nowIso();
    }
    await db.from("support_inbox_state").update({ ...upd, lock_until: null, updated_at: nowIso() }).eq("id", 1);
  }
}

/** Tickets bij een mail: op nummer (kopregels, onderwerp) en op opgeslagen Message-ID's van onze mails. */
async function ticketsFor(mail: ParsedMail): Promise<(Ticket & TicketLite)[]> {
  const nums = candidateNumbers(mail);
  const ids = referencedIds(mail).map((i) => i.replace(/["\\,()]/g, "")).filter((i) => i.length > 2);
  let byId: string[] = [];
  const strongIds = new Set<string>();
  if (ids.length) {
    const list = ids.map((i) => `"${i}"`).join(",");
    const { data } = await db.from("support_messages").select("ticket_id,mail_message_id").or(`mail_message_id.in.(${list}),message_id.in.(${list})`).limit(20);
    byId = [...new Set((data ?? []).map((r) => r.ticket_id as string))];
    // build 140: een antwoord op een van onze mails met een willekeurig deel in de Message-ID (niet te raden) telt als sterk
    for (const r of data ?? []) {
      const mid = String(r.mail_message_id ?? "");
      if (/^<bingr-ticket-\d+\.[A-Za-z0-9_-]{6,}@/.test(mid) && ids.includes(mid)) strongIds.add(r.ticket_id as string);
    }
  }
  if (!nums.length && !byId.length) return [];
  let q = db.from("support_tickets").select("*");
  q = nums.length && byId.length ? q.or(`number.in.(${nums.join(",")}),id.in.(${byId.join(",")})`) : nums.length ? q.in("number", nums) : q.in("id", byId);
  const { data, error } = await q.limit(10);
  if (error) throw new Error(error.message);
  const list: (Ticket & TicketLite)[] = ((data ?? []) as (Ticket & TicketLite)[]).map((t) => ({ ...t, strong: strongIds.has(t.id) }));
  const ordered = nums.map((n) => list.find((t) => Number(t.number) === n)).filter((t): t is Ticket & TicketLite => !!t);
  for (const t of list) if (!ordered.includes(t)) ordered.push(t);
  return ordered;
}

const isDup = (e: unknown) => (e as { code?: string })?.code === "23505";
const mailRef = (mail: ParsedMail) => ({ messageId: mail.messageId.slice(0, 300), inReplyTo: mail.inReplyTo[0]?.slice(0, 300) ?? null });

async function handleMail(mail: ParsedMail, opts: { ci?: boolean } = {}): Promise<InboxResult> {
  // al verwerkt (dezelfde Message-ID)? dan alleen als gelezen markeren en opruimen
  const { data: dup } = await db.from("support_messages").select("id").eq("message_id", mail.messageId.slice(0, 300)).limit(1);
  if (dup?.length) return { result: "duplicate", seen: true, move: true };
  const tickets = await ticketsFor(mail);
  const d: Decision = decide(mail, tickets, agents(), authserv());
  const now = nowIso();
  switch (d.kind) {
    case "ignore": return { result: `ignored:${d.reason}`, seen: false, move: false };
    case "reject": return { result: `rejected:${d.reason}`, ticket: tickets[0]?.number ?? null, seen: false, move: false };
    case "customer_reply": {
      const t = d.ticket as Ticket & TicketLite;
      let body = messageBody(mail, t.lang);
      if (!body) return { result: "rejected:empty", ticket: t.number, seen: false, move: false };
      if ("otherSender" in d && d.otherSender) body = `${OTHER_SENDER[t.lang]}\n\n${body}`.slice(0, 5000);
      const { count } = await db.from("support_messages").select("id", { count: "exact", head: true })
        .eq("ticket_id", t.id).eq("author", "customer").gte("created_at", hourAgo());
      if ((count ?? 0) >= 20) return { result: "rejected:rate_limited", ticket: t.number, seen: false, move: false };
      try { await addMessage(t.id, "customer", body, "email", mailRef(mail)); }
      catch (e) { if (isDup(e)) return { result: "duplicate", ticket: t.number, seen: true, move: true }; throw e; }
      const status = statusAfter(t.status, "customer");
      if (status !== t.status) await addMessage(t.id, "event", status);
      // admin_seen_at blijft staan: het ticket is daardoor weer "ongelezen" in het beheer
      await db.from("support_tickets").update({ status, updated_at: now, last_reply_at: now, last_customer_at: now, closed_at: null }).eq("id", t.id);
      return { result: "imported", ticket: t.number, detail: "otherSender" in d && d.otherSender ? "ander adres" : undefined, seen: true, move: true };
    }
    case "agent_reply": {
      const t = d.ticket as Ticket & TicketLite;
      const body = messageBody(mail, t.lang);
      if (!body) return { result: "rejected:empty", ticket: t.number, seen: false, move: false };
      let mid: number;
      try { mid = await addMessage(t.id, "support", body, "email", mailRef(mail)); }
      catch (e) { if (isDup(e)) return { result: "duplicate", ticket: t.number, seen: true, move: true }; throw e; }
      const status = statusAfter(t.status, "support");
      if (status !== t.status) await addMessage(t.id, "event", status);
      await db.from("support_tickets").update({
        status, updated_at: now, last_reply_at: now, last_support_at: now, admin_seen_at: now, closed_at: null,
      }).eq("id", t.id);
      const nt = { ...t, status };
      const [r] = await Promise.all([toCustomer(nt, mailData(nt, "customer_reply", { body })), notifyOwner(nt, mid)]);
      await markMail(mid, r);
      return { result: "agent", ticket: t.number, detail: r.ok ? "gemaild aan de klant" : `niet gemaild: ${r.error ?? ""}`, seen: true, move: true };
    }
    case "new_ticket": {
      const email = mail.from!.address.toLowerCase().slice(0, LIMITS_EMAIL);
      // build 140: in de plusmap van de rooktest alleen mails van het testadres zelf
      if (opts.ci && !isMailtestAddress(email)) return { result: "ignored:not_ci", seen: false, move: false };
      if (!validEmailAddr(email)) return { result: "rejected:bad_email", seen: false, move: false };
      // build 95: per afzender 3 per uur (echt per uur); geen globale grens meer die alles tegenhoudt
      const byEmail = await countSince((q) => q.eq("email", email));
      if (byEmail >= 3 || !(await rateOk(`support:mail:${email}`, 3, 3600))) return { result: "rejected:rate_limited", seen: false, move: false };
      const lang = guessLang(mail, mail.text);
      let body = messageBody(mail, lang);
      if (!body) return { result: "rejected:empty", seen: false, move: false };
      if (d.followUp) body = `${FOLLOW_UP[lang](d.followUp)}\n\n${body}`.slice(0, 5000);
      else if (d.related) body = `${RELATED[lang](d.related)}\n\n${body}`.slice(0, 5000);
      const token = randomToken();
      const { data, error } = await db.from("support_tickets").insert({
        email, name: senderName(mail), subject: cleanSubject(mail.subject, lang), category: "overig", lang, access_token: token,
      }).select("*").single();
      if (error) throw new Error(error.message);
      const t = data as Ticket;
      let mid: number;
      try { mid = await addMessage(t.id, "customer", body, "email", mailRef(mail)); }
      catch (e) {
        await db.from("support_tickets").delete().eq("id", t.id);
        if (isDup(e)) return { result: "duplicate", seen: true, move: true };
        throw e;
      }
      // bevestiging aan de afzender (met de link naar het ticket), zoals bij het formulier voor een gast.
      // build 95: zonder onderwerp en tekst (de afzender kan vervalst zijn), en niet boven de globale grens
      const c = (await confirmAllowed()) ? await toCustomer(t, mailData(t, "customer_created", { minimal: true })) : notSent("global_cap");
      // build 140: ook de melding aan support@ (met de link naar het beheer), want de mail zelf gaat naar Bingr-verwerkt;
      // de push naar de beheer-app gaat vanzelf (functie push, nieuwe tickets). Testtickets (support+ci-…): geen melding.
      const s = isMailtestAddress(email) ? null : await toSupport(t, mailData(t, "support_created", { body }));
      await markMail(mid, { ok: c.ok && (s?.ok ?? true), error: [c.error && `klant: ${c.error}`, s?.error && `support: ${s.error}`].filter(Boolean).join("; ") || undefined, messageId: c.messageId });
      return { result: "new_ticket", ticket: t.number, detail: d.followUp ? `vervolg op #${d.followUp}` : d.related ? `verwijst naar #${d.related}` : undefined, seen: true, move: true };
    }
  }
}
const LIMITS_EMAIL = 254;
const validEmailAddr = (e: string) => /^[^\s@<>()",;:\\[\]]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(e);
