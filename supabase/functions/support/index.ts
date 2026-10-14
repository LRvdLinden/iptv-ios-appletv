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
//   get     {n, t} of {n} (ingelogd, eigen ticket) -> {ticket:{…}, messages:[{author, body, created_at}]}
//   reply   {n, t?, message}                     -> {ok, status}   (gesloten ticket: 409 closed)
//   close   {n, t?}                              -> {ok, status:"closed"}
// Beheer (alleen met header x-support-secret = SUPPORT_ADMIN_SECRET; de functie admin in bingr-beheer stuurt dit door):
//   admin_counts {}                               -> {new, open, pending, resolved, closed, active, unread, total, last_7d}
//   admin_list   {status?: active|all|<status>, q?, page?, page_size?} -> {total, page, page_size, items:[…], counts}
//   admin_get    {number}                         -> {ticket, messages (ook notities), account}  (zet admin_seen_at)
//   admin_reply  {number, message, status?}       -> {ok, status, email_sent}  (mailt de klant)
//   admin_status {number, status?, priority?, notify?} -> {ok, status, email_sent}  (opgelost/gesloten: mail aan de klant)
//   admin_note   {number, message}                -> {ok}   (interne notitie, nooit zichtbaar voor de klant)
//   admin_inbox  {}                               -> {configured, agents, state, log}  (status van de inbox-import)
//   admin_poll   {}                               -> zoals poll_inbox  (knop "Nu ophalen" in het beheer)
// Inbox-import (alleen met header x-support-cron = SUPPORT_CRON_SECRET; pg_cron roept dit elke 5 minuten aan, build 95):
//   poll_inbox   {}  -> {ok, fetched, imported, …} of {skipped:"imap not configured"} of {ok:false, error}
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
import { smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import {
  addressOf, beheerUrl, type DeviceRow, deviceKind, isStatus, type KnownVersion, knownVersions, myDevices, parseNumber, PRIORITIES, randomToken, safeSearch, sameText, type Status, statusAfter,
  ticketUrl, validateCreate, validateMessage, validToken,
} from "./logic.ts";
import { type MailData, renderMail } from "./templates.ts";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { Imap } from "./imap.ts";
import { parseMessage, type ParsedMail } from "./mime.ts";
import {
  agentList, authservNames, candidateNumbers, cleanSubject, decide, type Decision, DONE_FOLDER, findFolder, FOLLOW_UP, guessLang, imapDate,
  MAX_FETCH_BYTES, messageBody, referencedIds, senderName, type TicketLite,
} from "./inbox.ts";
import { clientIp } from "../_shared/ip.ts";
import { makeChallenge, powKey, verifyPow } from "./pow.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const SUPPORT_SITE = env("BINGR_SUPPORT_SITE") || "https://support.bingr.online";
const BEHEER = "https://beheer.bingr.online";
const SUPPORT_EMAIL = () => env("BINGR_SUPPORT_EMAIL") || "support@bingr.online";
const SUPPORT_FROM = () => env("BINGR_SUPPORT_FROM") || "Bingr Support <support@bingr.online>";
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

const ORIGIN = /^https:\/\/support\.bingr\.online$|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;
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

type User = { id: string; email?: string; email_confirmed_at?: string | null };
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
const ownsTicket = (u: User | null, t: Ticket) =>
  !!u && (t.user_id === u.id || (!!u.email_confirmed_at && !!u.email && u.email.toLowerCase() === t.email.toLowerCase()));

async function ticketByNumber(n: number): Promise<Ticket | null> {
  const { data, error } = await db.from("support_tickets").select("*").eq("number", n).maybeSingle();
  if (error) throw new Error(error.message);
  return data as Ticket | null;
}
/** Ticket voor de klant: met nummer + geheime link, of als eigenaar ingelogd. Altijd hetzelfde antwoord als het niet mag. */
async function customerTicket(req: Request, body: Record<string, unknown>): Promise<{ t: Ticket; user: User | null } | null> {
  const n = parseNumber(body.n ?? body.number);
  if (!n) return null;
  const t = await ticketByNumber(n);
  if (!t) return null;
  if (validToken(body.t) && sameText(body.t, t.access_token)) return { t, user: null };
  const user = await userFrom(req);
  return ownsTicket(user, t) ? { t, user } : null;
}
async function messagesOf(ticketId: string, includeNotes: boolean) {
  let q = db.from("support_messages").select("id,author,body,created_at,email_sent,email_error,source").eq("ticket_id", ticketId).order("created_at").order("id");
  if (!includeNotes) q = q.neq("author", "note");
  const { data, error } = await q.limit(500);
  if (error) throw new Error(error.message);
  return (data ?? []).map((m) => includeNotes ? m : { author: m.author, body: m.body, created_at: m.created_at });
}
type Source = "web" | "email" | "admin";
async function addMessage(ticketId: string, author: string, body: string, source: Source | null = null, mail?: { messageId: string; inReplyTo: string | null }) {
  const row: Record<string, unknown> = { ticket_id: ticketId, author, body };
  if (source) row.source = source;
  if (mail) { row.message_id = mail.messageId; row.in_reply_to = mail.inReplyTo; }
  const { data, error } = await db.from("support_messages").insert(row).select("id").single();
  if (error) throw Object.assign(new Error(error.message), { code: error.code });
  return data.id as number;
}

// ---- e-mail ----
type Sent = { ok: boolean; error?: string; messageId?: string };
const imapConfigured = () => !!(env("BINGR_IMAP_HOST") && env("BINGR_IMAP_USER") && env("BINGR_IMAP_PASSWORD"));
async function send(to: string, mail: { subject: string; html: string; text: string }, opts: { replyTo?: string; number: number; first?: boolean; auto?: boolean }): Promise<Sent> {
  if (!smtpConfigured()) return { ok: false, error: "smtp_not_configured" };
  // alle mails van één ticket in één gesprek (Message-ID / In-Reply-To / References). Elke mail een eigen Message-ID met het
  // ticketnummer erin (<bingr-ticket-1007.…@bingr.online>), zodat een antwoord erop altijd bij het ticket komt.
  const root = `<bingr-ticket-${opts.number}@bingr.online>`;
  const messageId = opts.first && to.toLowerCase() !== SUPPORT_EMAIL().toLowerCase() ? root : `<bingr-ticket-${opts.number}.${randomToken(9)}@bingr.online>`;
  // X-Bingr-Ticket: zo herkent de inbox-import onze eigen mails (geen lussen); Auto-Submitted voor systeemmails (RFC 3834),
  // zodat afwezigheidsmelders er niet op antwoorden
  const headers: Record<string, string> = { "X-Bingr-Ticket": String(opts.number), ...(opts.auto ? { "Auto-Submitted": "auto-generated" } : {}) };
  if (messageId !== root) { headers["In-Reply-To"] = root; headers["References"] = root; }
  const base = { to, subject: mail.subject, html: mail.html, text: mail.text, headers, messageId };
  const tx = transport();
  try {
    try {
      await tx.sendMail({ ...base, from: SUPPORT_FROM(), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
      return { ok: true, messageId };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // afzender geweigerd (het SMTP-account mag niet als support@ versturen): opnieuw met de standaardafzender
      if (smtpFrom() && addressOf(smtpFrom()).toLowerCase() !== addressOf(SUPPORT_FROM()).toLowerCase()) {
        console.error("support mail (support-afzender)", msg);
        await tx.sendMail({ ...base, from: smtpFrom(), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
        return { ok: true, messageId };
      }
      throw e;
    }
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 300);
    console.error("support mail", msg);
    return { ok: false, error: msg };
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
const toCustomer = (t: Ticket, d: MailData) =>
  send(t.email, renderMail(d), { number: t.number, first: d.kind === "customer_created", auto: d.kind !== "customer_reply" });
// build 95: boven dit aantal nieuwe tickets per uur (alle samen) geen bevestigingsmails meer aan klanten (tickets worden wel
// opgeslagen en support krijgt de melding): een veiligheidsgrens tegen misbruik als mailkanon, die niemand buitensluit
const GLOBAL_CONFIRM_CAP = 500;
const confirmAllowed = async () => (await countSince((q) => q)) < GLOBAL_CONFIRM_CAP;
const notSent = (error: string): Sent => ({ ok: false, error });
// Reply-To van een melding: met de inbox-import het supportadres zelf (het antwoord van de eigenaar komt dan via de import in
// het ticket en gaat als gebrande mail naar de klant); zonder import het adres van de klant (antwoord gaat direct naar de klant)
const toSupport = (t: Ticket, d: MailData) =>
  send(SUPPORT_EMAIL(), renderMail(d), { number: t.number, replyTo: imapConfigured() ? addressOf(SUPPORT_FROM()) : t.email, first: d.kind === "support_created", auto: true });
async function markMail(messageId: number, r: Sent) {
  await db.from("support_messages").update({ email_sent: r.ok, email_error: r.ok ? null : r.error ?? null, ...(r.messageId && r.ok ? { mail_message_id: r.messageId } : {}) }).eq("id", messageId);
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
    if (text.length > 32 * 1024) return json({ error: "too_large" }, 413);
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
      return json(await pollInbox(String(body.source ?? "cron").slice(0, 20)));
    }
    if (action.startsWith("admin_")) {
      const secret = env("SUPPORT_ADMIN_SECRET");
      if (!secret || !sameText(req.headers.get("x-support-secret") ?? "", secret)) return json({ error: "forbidden" }, 403);
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
      // build 95: de bevestiging bevat alleen voor een ingelogde klant (bevestigd adres) het onderwerp en bericht;
      // een gast kan een willekeurig adres invullen, die krijgt alleen nummer, een neutrale regel en de link
      const full = !!user?.email_confirmed_at;
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
      let q = db.from("support_tickets").select(`${PUBLIC_FIELDS},access_token,customer_seen_at`).order("last_reply_at", { ascending: false }).limit(100);
      q = user.email_confirmed_at && user.email
        ? q.or(`user_id.eq.${user.id},email.eq."${user.email.toLowerCase().replace(/["\\]/g, "")}"`)
        : q.eq("user_id", user.id);
      const { data, error } = await q;
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
      const { t } = r;
      await db.from("support_tickets").update({ customer_seen_at: nowIso() }).eq("id", t.id);
      const pub = Object.fromEntries(PUBLIC_FIELDS.split(",").map((k) => [k, (t as Record<string, unknown>)[k]]));
      return json({ ticket: { ...pub, token: t.access_token, can_reply: t.status !== "closed" }, messages: await messagesOf(t.id, false) });
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
    default:
      return json({ error: "unknown_action" }, 400);
  }
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
      .select("number,subject,email,name,status,priority,category,platform,lang,user_id,created_at,updated_at,last_reply_at,last_customer_at,last_support_at,admin_seen_at", { count: "exact" });
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
      const r = await toCustomer(nt, mailData(nt, "customer_reply", { body: v.value }));
      await markMail(mid, r);
      return json({ ok: true, status, email_sent: r.ok, email_error: r.error ?? null });
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
    state: state ?? null, log: log ?? [],
  };
}

async function inboxLog(uid: number, mail: ParsedMail | null, r: InboxResult) {
  await db.from("support_inbox_log").insert({
    uid, message_id: mail?.messageId?.slice(0, 300) || null, sender: mail?.from?.address?.slice(0, 254) ?? null,
    subject: mail?.subject?.slice(0, 200) ?? null, result: r.result, ticket_number: r.ticket ?? null, detail: r.detail?.slice(0, 300) ?? null,
  });
}

async function pollInbox(source: string) {
  if (!imapConfigured()) return { skipped: "imap not configured" };
  // nooit twee rondes tegelijk (pg_cron + knop in het beheer): korte lease in support_inbox_state
  const { data: got, error: lockErr } = await db.rpc("bingr_support_inbox_lock", { p_seconds: 120 });
  if (lockErr) throw new Error(lockErr.message);
  if (got !== true) return { ok: true, busy: true };
  const started = Date.now();
  const counts: Counts = { fetched: 0, imported: 0, agent: 0, new_tickets: 0, ignored: 0, rejected: 0, duplicates: 0, errors: 0 };
  let imap: Imap | null = null;
  const upd: Record<string, unknown> = { last_poll_at: nowIso(), last_source: source };
  let cleanupAt: string | null = null, backlogEnd: number | null = null;
  try {
    const { data: state } = await db.from("support_inbox_state").select("uidvalidity,last_uid,error_uid,error_count,scan_until,scan_cursor,last_cleanup_at").eq("id", 1).maybeSingle();
    cleanupAt = state?.last_cleanup_at ?? null;
    imap = await Imap.connect({ host: env("BINGR_IMAP_HOST"), port: Number(env("BINGR_IMAP_PORT") || 993), timeoutMs: 20000 });
    await imap.login(env("BINGR_IMAP_USER"), env("BINGR_IMAP_PASSWORD"));
    const done = findFolder(await imap.list().catch(() => []));
    const sel = await imap.select("INBOX");
    const fresh = !state?.uidvalidity || Number(state.uidvalidity) !== sel.uidvalidity || state.last_uid == null;
    // build 95: eerste ronde (of de mailbox is opnieuw opgebouwd): de ongelezen mails van de laatste 7 dagen tot nu zijn
    // een achterstand (scan_until = hoogste UID nu) die in porties over meerdere rondes wordt verwerkt (scan_cursor);
    // vroeger alleen de laatste 25 en de rest werd overgeslagen. Nieuwe mails (UID > last_uid) gaan gewoon door.
    let lastUid: number, scanUntil: number | null, scanCursor: number;
    if (fresh) {
      const top = sel.uidnext ? sel.uidnext - 1 : (await imap.uidSearch("ALL")).reduce((a, b) => Math.max(a, b), 0);
      lastUid = Math.max(0, top); scanUntil = lastUid; scanCursor = 0;
    } else {
      lastUid = Number(state!.last_uid);
      scanUntil = state?.scan_until == null ? null : Number(state.scan_until);
      scanCursor = Number(state?.scan_cursor ?? 0);
    }
    const queue: { uid: number; backlog: boolean }[] = [];
    if (scanUntil != null && scanCursor < scanUntil) {
      const back = (await imap.uidSearch(`UNSEEN SINCE ${imapDate(new Date(Date.now() - 7 * 864e5))}`))
        .filter((u) => u > scanCursor && u <= scanUntil!).sort((a, b) => a - b);
      if (!back.length) { scanCursor = scanUntil; }
      for (const uid of back.slice(0, IMAP_MAX_PER_RUN)) queue.push({ uid, backlog: true });
      // past alles in deze ronde, dan is de achterstand na afloop klaar
      if (back.length <= IMAP_MAX_PER_RUN && back.length) backlogEnd = back[back.length - 1];
    }
    if (queue.length < IMAP_MAX_PER_RUN) {
      const fresh_ = (await imap.uidSearch(`UID ${lastUid + 1}:*`)).filter((u) => u > lastUid).sort((a, b) => a - b);
      for (const uid of fresh_.slice(0, IMAP_MAX_PER_RUN - queue.length)) queue.push({ uid, backlog: false });
    }
    const seen: number[] = [], move: number[] = [];
    let stopped = false;
    for (const { uid, backlog } of queue) {
      if (Date.now() - started > IMAP_BUDGET_MS) { stopped = true; break; }
      let mail: ParsedMail | null = null;
      let r: InboxResult;
      try {
        const [it] = await imap.uidFetch([uid], `(UID RFC822.SIZE BODY.PEEK[]<0.${MAX_FETCH_BYTES}>)`);
        if (!it?.body) { r = { result: "error", detail: "geen inhoud", seen: false, move: false }; }
        else {
          counts.fetched++;
          mail = parseMessage(it.body, { truncated: (it.size ?? 0) > MAX_FETCH_BYTES });
          if (!mail.messageId) mail.messageId = `<imap-${sel.uidvalidity}-${uid}@bingr.invalid>`;
          r = await handleMail(mail);
        }
      } catch (e) {
        // databasefout of iets onverwachts: deze mail de volgende ronde opnieuw (niet voorbij deze UID gaan); lukt het
        // drie rondes achter elkaar niet, dan overslaan (laten staan in de mailbox) zodat de rest niet blijft hangen
        counts.errors++;
        console.error("support inbox", uid, errText(e));
        const tries = Number(state?.error_uid) === uid ? Number(state.error_count ?? 0) + 1 : 1;
        if (tries < 3) {
          await inboxLog(uid, mail, { result: "error", detail: `poging ${tries}: ${errText(e)}`, seen: false, move: false }).catch(() => {});
          Object.assign(upd, { error_uid: uid, error_count: tries });
          stopped = true;
          break;
        }
        r = { result: "error:skipped", detail: `overgeslagen na ${tries} pogingen: ${errText(e)}`, seen: false, move: false };
        counts.errors--;
      }
      await inboxLog(uid, mail, r).catch((e) => console.error("support inbox log", errText(e)));
      const key = r.result.split(":")[0];
      if (key === "imported") counts.imported++;
      else if (key === "agent") counts.agent++;
      else if (key === "new_ticket") counts.new_tickets++;
      else if (key === "ignored") counts.ignored++;
      else if (key === "duplicate") counts.duplicates++;
      else if (key === "error") counts.errors++;
      else counts.rejected++;
      if (r.seen) seen.push(uid);
      if (r.move) move.push(uid);
      if (backlog) scanCursor = Math.max(scanCursor, uid);
      else lastUid = Math.max(lastUid, uid);
    }
    if (scanUntil != null && (scanCursor >= scanUntil || (backlogEnd != null && scanCursor >= backlogEnd))) { scanUntil = null; scanCursor = 0; }
    if (seen.length) await imap.uidStore(seen, "+FLAGS.SILENT (\\Seen)");
    let moved: string | null = null;
    if (move.length && done) moved = await imap.uidMove(move, done);
    await imap.logout();
    imap = null;
    Object.assign(upd, {
      mailbox: done ? `INBOX → ${done}` : "INBOX", last_ok_at: nowIso(),
      // build 95: altijd de stand bewaren (ook in de eerste ronde): wat nog niet verwerkt is, komt via scan_cursor of
      // last_uid de volgende ronde aan de beurt; niets wordt overgeslagen
      uidvalidity: sel.uidvalidity, last_uid: lastUid, scan_until: scanUntil, scan_cursor: scanUntil == null ? null : scanCursor,
      ...(stopped && counts.errors ? {} : { error_uid: null, error_count: 0 }),
      last_error: counts.errors ? "Een mail gaf een fout; volgende ronde opnieuw (zie logboek)" : null, last_error_at: counts.errors ? nowIso() : null, last_result: { ...counts, moved, more: stopped || queue.length >= IMAP_MAX_PER_RUN || scanUntil != null, backlog: scanUntil != null, ms: Date.now() - started },
      ...(counts.imported + counts.agent + counts.new_tickets ? { last_import_at: nowIso() } : {}),
    });
    return { ok: true, ...counts, folder: done, moved, ms: Date.now() - started };
  } catch (e) {
    const msg = errText(e);
    console.error("support inbox", msg);
    Object.assign(upd, { last_error: msg, last_error_at: nowIso(), last_result: { ...counts, ms: Date.now() - started } });
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
  if (ids.length) {
    const list = ids.map((i) => `"${i}"`).join(",");
    const { data } = await db.from("support_messages").select("ticket_id").or(`mail_message_id.in.(${list}),message_id.in.(${list})`).limit(5);
    byId = [...new Set((data ?? []).map((r) => r.ticket_id as string))];
  }
  if (!nums.length && !byId.length) return [];
  let q = db.from("support_tickets").select("*");
  q = nums.length && byId.length ? q.or(`number.in.(${nums.join(",")}),id.in.(${byId.join(",")})`) : nums.length ? q.in("number", nums) : q.in("id", byId);
  const { data, error } = await q.limit(10);
  if (error) throw new Error(error.message);
  const list = (data ?? []) as (Ticket & TicketLite)[];
  const ordered = nums.map((n) => list.find((t) => Number(t.number) === n)).filter((t): t is Ticket & TicketLite => !!t);
  for (const t of list) if (!ordered.includes(t)) ordered.push(t);
  return ordered;
}

const isDup = (e: unknown) => (e as { code?: string })?.code === "23505";
const mailRef = (mail: ParsedMail) => ({ messageId: mail.messageId.slice(0, 300), inReplyTo: mail.inReplyTo[0]?.slice(0, 300) ?? null });

async function handleMail(mail: ParsedMail): Promise<InboxResult> {
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
      const body = messageBody(mail, t.lang);
      if (!body) return { result: "rejected:empty", ticket: t.number, seen: false, move: false };
      const { count } = await db.from("support_messages").select("id", { count: "exact", head: true })
        .eq("ticket_id", t.id).eq("author", "customer").gte("created_at", hourAgo());
      if ((count ?? 0) >= 20) return { result: "rejected:rate_limited", ticket: t.number, seen: false, move: false };
      try { await addMessage(t.id, "customer", body, "email", mailRef(mail)); }
      catch (e) { if (isDup(e)) return { result: "duplicate", ticket: t.number, seen: true, move: true }; throw e; }
      const status = statusAfter(t.status, "customer");
      if (status !== t.status) await addMessage(t.id, "event", status);
      // admin_seen_at blijft staan: het ticket is daardoor weer "ongelezen" in het beheer
      await db.from("support_tickets").update({ status, updated_at: now, last_reply_at: now, last_customer_at: now, closed_at: null }).eq("id", t.id);
      return { result: "imported", ticket: t.number, seen: true, move: true };
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
      const r = await toCustomer(nt, mailData(nt, "customer_reply", { body }));
      await markMail(mid, r);
      return { result: "agent", ticket: t.number, detail: r.ok ? `gemaild aan ${t.email}` : `niet gemaild: ${r.error ?? ""}`, seen: true, move: true };
    }
    case "new_ticket": {
      const email = mail.from!.address.toLowerCase().slice(0, LIMITS_EMAIL);
      if (!validEmailAddr(email)) return { result: "rejected:bad_email", seen: false, move: false };
      // build 95: per afzender 3 per uur (echt per uur); geen globale grens meer die alles tegenhoudt
      const byEmail = await countSince((q) => q.eq("email", email));
      if (byEmail >= 3 || !(await rateOk(`support:mail:${email}`, 3, 3600))) return { result: "rejected:rate_limited", seen: false, move: false };
      const lang = guessLang(mail, mail.text);
      let body = messageBody(mail, lang);
      if (!body) return { result: "rejected:empty", seen: false, move: false };
      if (d.followUp) body = `${FOLLOW_UP[lang](d.followUp)}\n\n${body}`.slice(0, 5000);
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
      // bevestiging aan de afzender (met de link naar het ticket); geen melding aan support@: de mail staat daar al.
      // build 95: zonder onderwerp en tekst (de afzender kan vervalst zijn), en niet boven de globale grens
      const c = (await confirmAllowed()) ? await toCustomer(t, mailData(t, "customer_created", { minimal: true })) : notSent("global_cap");
      await markMail(mid, { ok: c.ok, error: c.error && `klant: ${c.error}`, messageId: c.messageId });
      return { result: "new_ticket", ticket: t.number, detail: d.followUp ? `vervolg op #${d.followUp}` : undefined, seen: true, move: true };
    }
  }
}
const LIMITS_EMAIL = 254;
const validEmailAddr = (e: string) => /^[^\s@<>()",;:\\[\]]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(e);
