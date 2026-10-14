// Bingr: supporttickets voor https://support.bingr.online, en het beheer (tab Support op beheer.bingr.online).
// POST /functions/v1/support met JSON {action, ...}; header `apikey`; `Authorization: Bearer <access_token>` optioneel
// (ingelogd met een Bingr-account: ticket gekoppeld aan het account, en "Mijn tickets").
//   ping    {}                                   -> {ok:true}  (statuscontrole)
//   create  {name, email, category, platform?, app_version?, subject, message, lang, website (lokveld), elapsed_ms?}
//                                                -> {ok, number, token, url, email_sent}
//           Limieten: 3 nieuwe tickets per e-mailadres en 5 per IP per uur, 100 in totaal per uur.
//   mine    {} (ingelogd)                        -> {items:[{number, subject, status, created_at, last_reply_at, unread, token}]}
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
// E-mail via _shared/mail.ts (BINGR_SMTP_*). Afzender BINGR_SUPPORT_FROM (standaard "Bingr Support <support@bingr.online>"),
// meldingen naar BINGR_SUPPORT_EMAIL (standaard support@bingr.online). Weigert de SMTP-server die afzender, dan gaat de
// mail met BINGR_SMTP_FROM als afzender en het supportadres als Reply-To. Mislukt mailen: het ticket blijft bestaan.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import {
  addressOf, beheerUrl, isStatus, parseNumber, PRIORITIES, randomToken, safeSearch, sameText, type Status, statusAfter,
  ticketUrl, validateCreate, validateMessage, validToken,
} from "./logic.ts";
import { type MailData, renderMail } from "./templates.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const SUPPORT_SITE = env("BINGR_SUPPORT_SITE") || "https://support.bingr.online";
const BEHEER = "https://beheer.bingr.online";
const SUPPORT_EMAIL = () => env("BINGR_SUPPORT_EMAIL") || "support@bingr.online";
const SUPPORT_FROM = () => env("BINGR_SUPPORT_FROM") || "Bingr Support <support@bingr.online>";
const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { autoRefreshToken: false, persistSession: false } });

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
  platform: string | null; app_version: string | null; status: Status; priority: string; lang: "nl" | "en";
  access_token: string; created_at: string; updated_at: string; last_reply_at: string; last_customer_at: string;
  last_support_at: string | null; admin_seen_at: string | null; customer_seen_at: string | null; closed_at: string | null;
};
const PUBLIC_FIELDS = "number,subject,category,platform,app_version,status,lang,name,email,created_at,updated_at,last_reply_at,last_support_at,closed_at";
function clientIp(req: Request) {
  const f = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  return (f || req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "?").slice(0, 64);
}
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
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return null;
  const { data, error } = await db.auth.getUser(token);
  return !error && data?.user ? data.user as User : null;
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
  let q = db.from("support_messages").select("id,author,body,created_at,email_sent,email_error").eq("ticket_id", ticketId).order("created_at").order("id");
  if (!includeNotes) q = q.neq("author", "note");
  const { data, error } = await q.limit(500);
  if (error) throw new Error(error.message);
  return (data ?? []).map((m) => includeNotes ? m : { author: m.author, body: m.body, created_at: m.created_at });
}
async function addMessage(ticketId: string, author: string, body: string) {
  const { data, error } = await db.from("support_messages").insert({ ticket_id: ticketId, author, body }).select("id").single();
  if (error) throw new Error(error.message);
  return data.id as number;
}

// ---- e-mail ----
type Sent = { ok: boolean; error?: string };
async function send(to: string, mail: { subject: string; html: string; text: string }, opts: { replyTo?: string; number: number; first?: boolean }): Promise<Sent> {
  if (!smtpConfigured()) return { ok: false, error: "smtp_not_configured" };
  // alle mails van één ticket in één gesprek (Message-ID / In-Reply-To / References)
  const root = `<bingr-ticket-${opts.number}@bingr.online>`;
  const headers: Record<string, string> = opts.first ? {} : { "In-Reply-To": root, "References": root };
  const base = { to, subject: mail.subject, html: mail.html, text: mail.text, headers, ...(opts.first ? { messageId: root } : {}) };
  const tx = transport();
  try {
    try {
      await tx.sendMail({ ...base, from: SUPPORT_FROM(), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
      return { ok: true };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // afzender geweigerd (het SMTP-account mag niet als support@ versturen): opnieuw met de standaardafzender
      if (smtpFrom() && addressOf(smtpFrom()).toLowerCase() !== addressOf(SUPPORT_FROM()).toLowerCase()) {
        console.error("support mail (support-afzender)", msg);
        await tx.sendMail({ ...base, from: smtpFrom(), replyTo: opts.replyTo ?? addressOf(SUPPORT_FROM()) });
        return { ok: true };
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
    hasAccount: !!t.user_id, createdAt: t.created_at, ...extra,
  };
}
const toCustomer = (t: Ticket, d: MailData) => send(t.email, renderMail(d), { number: t.number, first: d.kind === "customer_created" });
const toSupport = (t: Ticket, d: MailData) => send(SUPPORT_EMAIL(), renderMail(d), { number: t.number, replyTo: t.email, first: d.kind === "support_created" });
async function markMail(messageId: number, r: Sent) {
  await db.from("support_messages").update({ email_sent: r.ok, email_error: r.ok ? null : r.error ?? null }).eq("id", messageId);
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

async function rateOk(key: string, max: number) {
  const { data, error } = await db.rpc("bingr_rate_hit", { p_key: key, p_max: max });
  if (error) throw new Error(error.message);
  return data === true;
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
      if (!v.ok) return json({ error: v.error, field: v.field }, 400);
      const user = await userFrom(req);
      const input = v.value;
      // ingelogd: altijd het (bevestigde) adres van het account, zodat "Mijn tickets" en de mails kloppen
      if (user?.email) input.email = user.email.toLowerCase();
      const ih = await ipHash(ip);
      if (!(await rateOk(`support:create:${ih}`, 3))) return json({ error: "rate_limited" }, 429);
      const [byIp, byEmail, all] = await Promise.all([
        countSince((q) => q.eq("ip_hash", ih)), countSince((q) => q.eq("email", input.email)), countSince((q) => q),
      ]);
      if (byIp >= 5 || byEmail >= 3 || all >= 100) return json({ error: "rate_limited" }, 429);
      const token = randomToken();
      const { data, error } = await db.from("support_tickets").insert({
        user_id: user?.id ?? null, email: input.email, name: input.name, subject: input.subject, category: input.category,
        platform: input.platform, app_version: input.app_version, lang: input.lang, access_token: token, ip_hash: ih,
      }).select("*").single();
      if (error) throw new Error(error.message);
      const t = data as Ticket;
      const mid = await addMessage(t.id, "customer", input.message);
      const [c, s] = await Promise.all([
        toCustomer(t, mailData(t, "customer_created", { body: input.message })),
        toSupport(t, mailData(t, "support_created", { body: input.message })),
      ]);
      await markMail(mid, { ok: c.ok && s.ok, error: [c.error && `klant: ${c.error}`, s.error && `support: ${s.error}`].filter(Boolean).join(" · ") || undefined });
      return json({ ok: true, number: t.number, token, url: ticketUrl(SUPPORT_SITE, t.number, token), email_sent: c.ok });
    }
    case "mine": {
      const user = await userFrom(req);
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
    case "get": {
      if (!(await rateOk(`support:get:${await ipHash(ip)}`, 60))) return json({ error: "rate_limited" }, 429);
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
      if (!(await rateOk(`support:reply:${t.id}`, 4))) return json({ error: "rate_limited" }, 429);
      const { count } = await db.from("support_messages").select("id", { count: "exact", head: true })
        .eq("ticket_id", t.id).eq("author", "customer").gte("created_at", hourAgo());
      if ((count ?? 0) >= 20) return json({ error: "rate_limited" }, 429);
      const status = statusAfter(t.status, "customer");
      const now = nowIso();
      const mid = await addMessage(t.id, "customer", v.value);
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
      const mid = await addMessage(t.id, "support", v.value);
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
      await addMessage(t.id, "note", v.value);
      await db.from("support_tickets").update({ admin_seen_at: now }).eq("id", t.id);
      return json({ ok: true });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}
