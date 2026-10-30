// Bingr: status en monitoring (bingr.online/status en de tab Status in het beheer).
// Openbaar (geen sleutel; GET of POST {action}):
//   public                        -> {generated_at, overall:{state, level, down, degraded, partial, major, maintenance}, groups:[{id, name,
//                                     monitors:[{id, name, state, status, checked_at, ms24, uptime, days:[{d, u, s, dm, i}]}]}],
//                                     notices:{active, upcoming, recent}, titles:{id:{nl,en}}, incidents:[…]}   (~60 s in de cache)
//   history  {page?}              -> {page, pages, total, items:[melding]}   afgesloten storingen en onderhoud, nieuwste eerst
//   notice   {id}                 -> {notice, names}                         één melding met tijdlijn
//   feed     {format?: atom|rss, lang?: nl|en}  -> XML (storingen en onderhoud)
//   subscribe {email, lang?, website?}  -> {ok}  bevestigingsmail (dubbele opt-in); website = lokveld
//   confirm  {token} -> {ok, lang}   unsubscribe {token} -> {ok}
//   releases                      -> {apple:{live, beta}, android:{live, beta}, updatedAt}  versies voor de downloadknoppen op
//                                     bingr.online (app_settings.release_channels, in te stellen in het beheer; releases.ts)
//   Alleen openbare monitors; geen gebruikers- of apparaataantallen.
// Met header `x-status-secret: <STATUS_CRON_SECRET>` (pg_cron en de admin-functie; het geheim staat alleen op de server):
//   run            {force?, monitor_id?}  -> controleert wat aan de beurt is, slaat op, opent/sluit storingen en meldingen,
//                                            onderhoud begint/eindigt vanzelf, verstuurt meldingen aan abonnees (in porties)
//   admin          {}                     -> als public, maar alle monitors + instellingen, apparaten, planning, oorzaken,
//                                            meldingen (90 dagen, ook geannuleerd) en abonnees
//   checks         {monitor_id, limit?}   -> ruwe controles van de laatste 24 uur (nieuwste eerst)
//   monitor_save   {id?, name_nl, name_en, grp, target, keyword?, interval_min, public, enabled}
//   monitor_delete {id}                   -> alleen eigen monitors; standaardmonitors kun je uitzetten
//   notice_save    {id?, kind, title_nl, title_en?, impact?, status?, started_at?, window_start?, window_end?,
//                   components:[{id, impact}], message_nl?, message_en?, notify?, auto_resolve?}  -> {ok, id, queued}
//   notice_update  {id, status, message_nl, message_en?, notify?, components?}                   -> {ok, queued, mailed}
//   notice_delete  {id}                   -> {ok}
//   subscribers    {}                     -> {confirmed, pending, nl, en, last_7d, queue}
//   mail_run       {}                     -> verstuurt wat er in de wachtrij staat
//   mail_preview   {to, lang?, kind: notice|alert} -> {ok}  voorbeeld ("[Voorbeeld]") naar één adres: notice = de mail aan
//                  abonnees met de nieuwste melding (anders een voorbeeldmelding), alert = de monitoringmail aan
//                  BINGR_ALERT_EMAIL. Ook met header x-bingr-mailtest (workflow Diagnose, _shared/mail.ts), dan alleen
//                  naar een testadres support+ci-…@bingr.online.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { isMailtestAddress, MAILTEST_HEADER, mailErrorCode, mailtestOk, smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import { button, esc, eyebrow, footerHtml, layout, personName, redBar, title } from "../_shared/layout.ts";
import { clientIp } from "../_shared/ip.ts"; // build 95: laatste X-Forwarded-For-waarde, niet de eerste
import { type Monitor, runCheck } from "./checks.ts";
import { type DayRow, daySeries, durationS, evaluate, isDue, type State, uptimePct, windowUptime } from "./logic.ts";
import {
  annotateDays, atomFeed, autoOpenText, autoResolveText, autoTitle, COMP_IMPACTS, type CompImpact, componentLevels, effectiveStatus,
  IMPACTS, INCIDENT_STATUSES, isActive, isUpcoming, type Lang, MAINT_STATUSES, maintStatus, maintText, type Notice, overallLevel,
  publicNotice, type PublicNotice, rssFeed, span, validEmail, validToken,
} from "./notices.ts";
import { renderConfirm, renderNotice, unsubscribeUrl } from "./templates.ts";
import { releasesView } from "./releases.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { autoRefreshToken: false, persistSession: false },
});
const SITE = env("BINGR_SITE") || "https://bingr.online";
const BEHEER = env("BINGR_BEHEER_URL") || "https://beheer.bingr.online";
const GROUPS = [
  { id: "server", name: { nl: "Server", en: "Server" } },
  { id: "website", name: { nl: "Website", en: "Website" } },
  { id: "apps", name: { nl: "Apps", en: "Apps" } },
];
const INTERVALS = [5, 10, 15, 30, 60, 360, 720, 1440];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (body: unknown, status = 200, cache = "no-store") =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": cache } });

const enc = new TextEncoder();
async function sameSecret(given: string) {
  const want = env("STATUS_CRON_SECRET");
  if (!want || !given || given.length > 200) return false;
  const [a, b] = await Promise.all([given, want].map(async (s) => new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s)))));
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

// ---- overzicht ----
interface MonitorRow {
  id: string; name_nl: string; name_en: string; grp: string; kind: string; target: string; keyword: string | null;
  interval_min: number; public: boolean; enabled: boolean; builtin: boolean; sort: number; created_at: string;
  last_checked_at: string | null; last_state: State | null; last_ms: number | null; last_error: string | null;
  fail_streak: number; ok_streak: number;
}
interface Incident { id: number; m: string; started_at: string; ended_at: string | null; cause: string | null }

async function loadMonitors(): Promise<MonitorRow[]> {
  const { data, error } = await db.from("status_monitors").select("*").order("grp").order("sort").order("created_at");
  if (error) throw new Error(error.message);
  return (data ?? []) as MonitorRow[];
}

const NOTICE_SELECT = "*, components:status_notice_components(monitor_id,impact), updates:status_notice_updates(id,status,body_nl,body_en,auto,at)";
/** Meldingen die nog lopen of gepland zijn, plus alles wat in de laatste `days` dagen is afgesloten. */
async function loadNotices(days = 90): Promise<Notice[]> {
  const cut = new Date(Date.now() - days * 864e5).toISOString();
  const { data, error } = await db.from("status_notices").select(NOTICE_SELECT)
    .or(`resolved_at.is.null,resolved_at.gt.${cut},started_at.gt.${cut}`).order("started_at", { ascending: false }).limit(400);
  if (error) throw new Error(error.message);
  return (data ?? []) as Notice[];
}
async function loadNotice(id: number): Promise<Notice | null> {
  const { data, error } = await db.from("status_notices").select(NOTICE_SELECT).eq("id", id).maybeSingle();
  if (error) throw new Error(error.message);
  return data as Notice | null;
}
const shownOnPage = (n: Notice) => n.status !== "cancelled";

async function summary(full: boolean) {
  const [monitors, dataRes, notices] = await Promise.all([loadMonitors(), db.rpc("bingr_status_data", { p_days: 90 }), loadNotices(90)]);
  if (dataRes.error) throw new Error(dataRes.error.message);
  const data = dataRes.data as { today: string; daily: DayRow[]; last24: { m: string; n: number; x: number; ms: number | null }[]; incidents: Incident[] };
  const today = String(data.today).slice(0, 10);
  const now = Date.now();
  const openSet = new Set(data.incidents.filter((i) => !i.ended_at).map((i) => i.m));
  const visible = monitors.filter((m) => full || (m.public && m.enabled && m.kind !== "devices"));
  const pageNotices = full ? notices : notices.filter(shownOnPage);
  const out = visible.map((m) => {
    const rows = data.daily.filter((r) => r.m === m.id);
    const l24 = data.last24.find((r) => r.m === m.id);
    const state: State | null = !m.enabled || m.kind === "devices" ? null : openSet.has(m.id) ? "down" : m.last_state;
    const base = {
      id: m.id, name: { nl: m.name_nl, en: m.name_en }, group: m.grp, state, checked_at: m.last_checked_at,
      ms24: l24?.ms ?? null,
      uptime: { d1: l24 ? uptimePct(l24.n, l24.x) : null, d7: windowUptime(rows, today, 7), d30: windowUptime(rows, today, 30), d90: windowUptime(rows, today, 90) },
      days: annotateDays(daySeries(rows, today, 90), m.id, data.incidents, pageNotices, now),
    };
    return full
      ? { ...base, kind: m.kind, target: m.target, keyword: m.keyword, interval_min: m.interval_min, public: m.public, enabled: m.enabled,
          builtin: m.builtin, last_error: m.last_error, last_ms: m.last_ms, fail_streak: m.fail_streak }
      : base;
  }).filter((m) => full || m.state !== null || m.days.some((d) => d.s !== "none"));
  const names = new Map(monitors.map((m) => [m.id, { nl: m.name_nl, en: m.name_en }]));
  const shown = new Set(out.map((m) => m.id));
  const cut = Date.now() - (full ? 90 : 30) * 864e5;
  const incidents = data.incidents
    .filter((i) => shown.has(i.m) && (!i.ended_at || Date.parse(i.started_at) > cut))
    .map((i) => ({
      id: i.id, monitor_id: i.m, name: names.get(i.m), started_at: i.started_at, ended_at: i.ended_at,
      duration_s: durationS(i.started_at, i.ended_at), ...(full ? { cause: i.cause } : {}),
    }));
  // niveaus per onderdeel (monitor + meldingen) en het totaalbeeld
  const live = out.filter((m) => m.state !== null && (full ? (m as { enabled?: boolean }).enabled !== false : true));
  const levels = componentLevels(live.map((m) => ({ id: m.id, state: m.state })), pageNotices, now);
  const ol = overallLevel(levels, pageNotices, now);
  const legacy = ol.level === "major" || ol.level === "partial" ? "down" : ol.level === "degraded" ? "degraded" : "up";
  // meldingen: lopend, gepland, en wat de laatste 15 dagen speelde (voor "Afgelopen incidenten")
  const pub = (n: Notice) => publicNotice(n, full ? new Set(monitors.map((m) => m.id)) : shown, now);
  const recentCut = now - 15 * 864e5;
  const titles: Record<number, { nl: string; en: string }> = {};
  for (const n of pageNotices) titles[n.id] = { nl: n.title_nl, en: n.title_en || n.title_nl };
  const withLevel = (m: typeof out[number]) => ({ ...m, status: levels.get(m.id) ?? null });
  return {
    generated_at: new Date().toISOString(),
    overall: { state: legacy, level: ol.level, down: [...ol.major, ...ol.partial], degraded: ol.degraded,
      partial: ol.partial, major: ol.major, maintenance: ol.maintenance },
    groups: GROUPS.map((g) => ({ ...g, monitors: out.filter((m) => m.group === g.id).map((m) => { const { group: _g, ...rest } = withLevel(m); return rest; }) }))
      .filter((g) => g.monitors.length),
    notices: {
      active: pageNotices.filter((n) => isActive(n, now)).map(pub),
      upcoming: pageNotices.filter((n) => isUpcoming(n, now)).sort((a, b) => Date.parse(a.window_start ?? "") - Date.parse(b.window_start ?? "")).map(pub),
      recent: pageNotices.filter((n) => !isUpcoming(n, now) && n.status !== "cancelled" && span(n, now).end >= recentCut).map(pub),
    },
    titles,
    incidents,
    ...(full ? { all_notices: notices.map((n) => ({ ...pub(n), auto: n.auto, auto_resolve: n.auto_resolve, edited: n.edited, notify: n.notify,
      stored_status: n.status, updated_at: n.updated_at })) } : {}),
  };
}

let publicCache: { at: number; body: unknown } | null = null;
async function publicSummary() {
  if (publicCache && Date.now() - publicCache.at < 60_000) return publicCache.body;
  const body = await summary(false);
  publicCache = { at: Date.now(), body };
  return body;
}

/** Openbare monitors (voor de onderdelen van meldingen buiten de samenvatting). */
async function publicNames() {
  const { data } = await db.from("status_monitors").select("id,name_nl,name_en,public,enabled,kind");
  const rows = (data ?? []) as { id: string; name_nl: string; name_en: string; public: boolean; enabled: boolean; kind: string }[];
  const pubRows = rows.filter((r) => r.public && r.kind !== "devices");
  return {
    visible: new Set(pubRows.map((r) => r.id)),
    names: new Map(pubRows.map((r) => [r.id, { nl: r.name_nl, en: r.name_en }])),
    all: new Map(rows.map((r) => [r.id, { nl: r.name_nl, en: r.name_en }])),
  };
}

const HIST_PAGE = 20;
async function history(page: number) {
  const p = Math.min(Math.max(Math.floor(page) || 1, 1), 500);
  const { data, error, count } = await db.from("status_notices").select(NOTICE_SELECT, { count: "exact" })
    .in("status", ["resolved", "completed"]).order("started_at", { ascending: false }).range((p - 1) * HIST_PAGE, p * HIST_PAGE - 1);
  if (error) throw new Error(error.message);
  const { visible, names } = await publicNames();
  const items = ((data ?? []) as Notice[]).map((n) => publicNotice(n, visible));
  const total = count ?? items.length;
  return { page: p, pages: Math.max(1, Math.ceil(total / HIST_PAGE)), total, items, names: Object.fromEntries(names) };
}

async function noticeDetail(id: number) {
  const n = await loadNotice(id);
  if (!n) return null;
  const { visible, names } = await publicNames();
  const pn = publicNotice(n, visible);
  return { notice: pn, names: Object.fromEntries([...names].filter(([k]) => pn.components.some((c) => c.id === k))) };
}

let feedCache: Map<string, { at: number; body: string }> = new Map();
async function feed(format: "atom" | "rss", lang: Lang) {
  const key = `${format}-${lang}`;
  const c = feedCache.get(key);
  if (c && Date.now() - c.at < 120_000) return c.body;
  const { data, error } = await db.from("status_notices").select(NOTICE_SELECT).neq("status", "cancelled")
    .order("updated_at", { ascending: false }).limit(25);
  if (error) throw new Error(error.message);
  const { visible, names } = await publicNames();
  const items = ((data ?? []) as Notice[]).map((n) => publicNotice(n, visible));
  const updated = items.reduce((m, n) => [n.started_at, n.resolved_at ?? "", ...n.updates.map((u) => u.at)].reduce((a, b) => (b > a ? b : a), m), "2026-01-01T00:00:00Z");
  const self = `${SITE}/status/feed${lang === "en" ? ".en" : ""}.${format}`;
  const body = (format === "rss" ? rssFeed : atomFeed)(items, { lang, site: SITE, self, updated, names });
  feedCache.set(key, { at: Date.now(), body });
  return body;
}

function maskEmail(e: string) {
  const at = e.lastIndexOf("@");
  if (at < 1) return e ? "***" : "";
  const d = e.slice(at + 1), dot = d.lastIndexOf(".");
  return `${e[0]}***@${d[0] ?? ""}***${dot > 0 ? d.slice(dot) : ""}`;
}

async function subscriberCounts() {
  const { data, error } = await db.rpc("bingr_status_subscriber_counts");
  if (error) throw new Error(error.message);
  return { ...(data as Record<string, number>), smtp: smtpConfigured() };
}

async function adminSummary() {
  const [s, dev, cron, runner, subs] = await Promise.all([
    summary(true), db.rpc("bingr_status_devices"), db.rpc("bingr_status_cron"),
    db.from("status_runner").select("last_run_at,last_source").eq("id", 1).maybeSingle(), subscriberCounts().catch(() => null),
  ]);
  const alert = env("BINGR_ALERT_EMAIL");
  return {
    ...s,
    devices: dev.data ?? [],
    scheduler: { cron: cron.data ?? null, last_run_at: runner.data?.last_run_at ?? null, last_source: runner.data?.last_source ?? null },
    alerts: { email: alert ? maskEmail(alert) : null, smtp: smtpConfigured() },
    subscribers: subs,
    intervals: INTERVALS,
  };
}

// ---- controleren ----
interface Event { kind: "open" | "close"; monitor: MonitorRow; cause?: string | null; started_at?: string; duration_s?: number; notice_id?: number | null }

/** Monitors waar nu onderhoud aan is (dan opent een fout geen storing). */
const maintenanceSet = (notices: Notice[], now = Date.now()) =>
  new Set(notices.filter((n) => n.kind === "maintenance" && isActive(n, now)).flatMap((n) => n.components.map((c) => c.monitor_id)));

async function run(force: boolean, onlyId: string | null, source: string) {
  const { data: got, error: le } = await db.rpc("bingr_status_lock", { p_source: source });
  if (le) throw new Error(le.message);
  if (!got) return { busy: true };
  const t0 = Date.now();
  let result: Record<string, unknown>;
  try {
    const [allMonitors, notices] = await Promise.all([loadMonitors(), loadNotices(2)]);
    const monitors = allMonitors.filter((m) => m.enabled && m.kind !== "devices" && (!onlyId || m.id === onlyId));
    const due = monitors.filter((m) => force || isDue(m.last_checked_at, m.interval_min, t0));
    const maint = maintenanceSet(notices, t0);
    const { data: openRows } = await db.from("status_incidents").select("id,monitor_id,started_at,notice_id").is("ended_at", null);
    type OpenRow = { id: number; monitor_id: string; started_at: string; notice_id: number | null };
    const open = new Map(((openRows ?? []) as OpenRow[]).map((r) => [r.monitor_id, r] as const));
    const ctx = { db, env, cache: new Map<string, Promise<unknown>>() };
    const results = await Promise.all(due.map(async (m) => [m, await runCheck(m as Monitor, ctx)] as const));
    const at = new Date().toISOString();
    const rows: Record<string, unknown>[] = [];
    const updates: PromiseLike<unknown>[] = [];
    const events: Event[] = [];
    let skipped = 0;
    const summaryRows: { id: string; state: string; ok: boolean; ms: number | null; error: string | null; detail?: string | null }[] = [];
    for (const [m, r] of results) {
      if (r.skip) {
        skipped++;
        updates.push(db.from("status_monitors").update({ last_checked_at: at, last_error: r.error ?? null }).eq("id", m.id));
        summaryRows.push({ id: m.id, state: "skip", ok: true, ms: r.ms ?? null, error: r.error ?? null });
        continue;
      }
      if (maint.has(m.id) && !r.ok) {
        // onderhoud: een fout telt niet als storing en niet mee voor de uptime (state "maint")
        rows.push({ monitor_id: m.id, at, ok: false, state: "maint", status_code: r.code ?? null, ms: r.ms ?? null,
          error: (r.error ?? "fout").slice(0, 160), detail: "onderhoud" });
        updates.push(db.from("status_monitors").update({ last_checked_at: at, last_ms: r.ms ?? null, last_error: (r.error ?? "fout").slice(0, 160) }).eq("id", m.id));
        summaryRows.push({ id: m.id, state: "maint", ok: false, ms: r.ms ?? null, error: r.error ?? null, detail: "onderhoud" });
        continue;
      }
      const ev = evaluate({ fail_streak: m.fail_streak, ok_streak: m.ok_streak, open: open.has(m.id) }, r);
      rows.push({ monitor_id: m.id, at, ok: r.ok, state: ev.checkState, status_code: r.code ?? null, ms: r.ms ?? null,
        error: r.ok ? (r.degraded && r.error ? r.error.slice(0, 160) : null) : (r.error ?? "fout").slice(0, 160), detail: r.detail ? String(r.detail).slice(0, 160) : null });
      updates.push(db.from("status_monitors").update({
        last_checked_at: at, last_state: ev.current, last_ms: r.ms ?? null,
        last_error: r.ok ? (r.degraded && r.error ? r.error.slice(0, 160) : null) : (r.error ?? "fout").slice(0, 160),
        fail_streak: ev.fail_streak, ok_streak: ev.ok_streak,
      }).eq("id", m.id));
      if (ev.open) events.push({ kind: "open", monitor: m, cause: r.error ?? null, started_at: at });
      if (ev.close) {
        const inc = open.get(m.id);
        events.push({ kind: "close", monitor: m, started_at: inc?.started_at, duration_s: inc ? durationS(inc.started_at, at) : undefined, notice_id: inc?.notice_id ?? null });
        updates.push(db.from("status_incidents").update({ ended_at: at }).eq("monitor_id", m.id).is("ended_at", null));
      }
      summaryRows.push({ id: m.id, state: ev.current, ok: r.ok, ms: r.ms ?? null, error: r.ok ? null : r.error ?? null, detail: r.detail ?? null });
    }
    if (rows.length) {
      const { error } = await db.from("status_checks").insert(rows);
      if (error) throw new Error(error.message);
    }
    await Promise.all(updates);
    let noticeLog: string[] = [];
    try { noticeLog = [...await autoNotices(events, at), ...await maintenanceTransitions(notices)]; }
    catch (e) { console.error("status notices", e instanceof Error ? e.message : e); noticeLog.push("fout bij meldingen"); }
    let mailed: boolean | string = false;
    if (events.length) mailed = await alert(events);
    await db.rpc("bingr_status_cleanup");
    await db.rpc("bingr_status_cleanup2");
    publicCache = null; feedCache = new Map();
    result = {
      checked: rows.length, skipped, due: due.length, total: monitors.length,
      up: summaryRows.filter((r) => r.state === "up").length,
      degraded: summaryRows.filter((r) => r.state === "degraded").length,
      down: summaryRows.filter((r) => r.state === "down").length,
      maintenance: summaryRows.filter((r) => r.state === "maint").length,
      opened: events.filter((e) => e.kind === "open").map((e) => e.monitor.id),
      closed: events.filter((e) => e.kind === "close").map((e) => e.monitor.id),
      notices: noticeLog,
      mailed, ms: Date.now() - t0, results: summaryRows,
    };
  } finally {
    await db.rpc("bingr_status_unlock");
  }
  // meldingen aan abonnees: na het slot van de controle, met een eigen slot en tijdsbudget
  try { result.subscribers = await processQueue(35_000, 60); }
  catch (e) { console.error("status queue", e instanceof Error ? e.message : e); result.subscribers = { error: "failed" }; }
  return result;
}

// ---- automatische meldingen ----
async function addUpdate(noticeId: number, status: string, text: { body_nl: string; body_en: string }, auto: boolean, at = new Date().toISOString()) {
  const { data, error } = await db.from("status_notice_updates").insert({ notice_id: noticeId, status, ...text, auto, at }).select("id").single();
  if (error) throw new Error(error.message);
  return data.id as number;
}
async function enqueue(noticeId: number, updateId: number | null, delayMs = 0) {
  const { error } = await db.from("status_mail_queue").insert({ notice_id: noticeId, update_id: updateId, send_after: new Date(Date.now() + delayMs).toISOString() });
  if (error) throw new Error(error.message);
}
/** Korte storing: de melding is nog niet gemaild. Dan de wachtende mail schrappen en ook niet "opgelost" mailen. */
async function cancelPending(noticeId: number): Promise<boolean> {
  const { data } = await db.from("status_mail_queue").select("id,sent,cursor").eq("notice_id", noticeId).is("done_at", null).eq("cancelled", false);
  const pending = (data ?? []) as { id: number; sent: number; cursor: number }[];
  const { count } = await db.from("status_mail_queue").select("id", { count: "exact", head: true }).eq("notice_id", noticeId).gt("sent", 0);
  if ((count ?? 0) > 0 || pending.some((p) => p.sent > 0 || p.cursor > 0)) return false;
  if (pending.length) await db.from("status_mail_queue").update({ cancelled: true, done_at: new Date().toISOString() }).in("id", pending.map((p) => p.id));
  return true;
}
const AUTO_NOTIFY_DELAY = 10 * 60_000; // automatische storing pas na 10 min mailen (korte haperingen niet)

/** Storing geopend/gesloten door een monitor: melding openen, uitbreiden of (als alles weer werkt) vanzelf sluiten. */
async function autoNotices(events: Event[], at: string): Promise<string[]> {
  const log: string[] = [];
  const opens = events.filter((e) => e.kind === "open");
  const closes = events.filter((e) => e.kind === "close");
  if (opens.length) {
    const outageIds = new Map<string, number>();
    for (const e of opens) {
      const { data, error } = await db.from("status_incidents").insert({ monitor_id: e.monitor.id, started_at: at, cause: (e.cause ?? "fout").slice(0, 160) }).select("id").single();
      if (error) { console.error("status outage", error.message); continue; }
      outageIds.set(e.monitor.id, data.id as number);
    }
    const pub = opens.filter((e) => e.monitor.public && outageIds.has(e.monitor.id)).map((e) => e.monitor);
    if (pub.length) {
      const { data: ex } = await db.from("status_notices").select(NOTICE_SELECT).eq("kind", "incident").eq("auto", true).is("resolved_at", null)
        .gt("started_at", new Date(Date.now() - 6 * 3600e3).toISOString()).order("started_at", { ascending: false }).limit(1);
      let n = ((ex ?? []) as Notice[])[0];
      if (n) {
        const fresh = pub.filter((m) => !n.components.some((c) => c.monitor_id === m.id));
        if (fresh.length) {
          await db.from("status_notice_components").upsert(fresh.map((m) => ({ notice_id: n.id, monitor_id: m.id, impact: "major" })));
          const { all } = await publicNames();
          const ids = [...n.components.map((c) => c.monitor_id), ...fresh.map((m) => m.id)];
          if (!n.edited) {
            await db.from("status_notices").update({
              title_nl: autoTitle(ids.map((i) => all.get(i)?.nl ?? i), "nl"), title_en: autoTitle(ids.map((i) => all.get(i)?.en ?? i), "en"), updated_at: at,
            }).eq("id", n.id);
          }
          const nl = fresh.map((m) => m.name_nl).join(", "), en = fresh.map((m) => m.name_en).join(", ");
          await addUpdate(n.id, n.status, { body_nl: `Ook ${nl} werkt nu niet goed.`, body_en: `${en} is now affected as well.` }, true, at);
          log.push(`melding ${n.id} uitgebreid: ${fresh.map((m) => m.id).join(",")}`);
        }
      } else {
        const { data: created, error } = await db.from("status_notices").insert({
          kind: "incident", title_nl: autoTitle(pub.map((m) => m.name_nl), "nl"), title_en: autoTitle(pub.map((m) => m.name_en), "en"),
          impact: "major", status: "investigating", started_at: at, auto: true, auto_resolve: true, notify: true, updated_at: at,
        }).select("id").single();
        if (error) throw new Error(error.message);
        n = { id: created.id } as Notice;
        await db.from("status_notice_components").insert(pub.map((m) => ({ notice_id: n.id, monitor_id: m.id, impact: "major" })));
        const uid = await addUpdate(n.id, "investigating", autoOpenText(pub.map((m) => m.name_nl).join(", "), pub.map((m) => m.name_en).join(", ")), true, at);
        await enqueue(n.id, uid, AUTO_NOTIFY_DELAY);
        log.push(`melding ${n.id} geopend: ${pub.map((m) => m.id).join(",")}`);
      }
      await db.from("status_incidents").update({ notice_id: n.id }).in("id", pub.map((m) => outageIds.get(m.id)!));
    }
  }
  // gesloten storingen: meldingen met auto_resolve sluiten als er geen gekoppelde storing meer loopt
  const ids = [...new Set(closes.map((e) => e.notice_id).filter((x): x is number => !!x))];
  for (const id of ids) {
    const n = await loadNotice(id);
    if (!n || n.kind !== "incident" || n.resolved_at || !n.auto_resolve) continue;
    const { count } = await db.from("status_incidents").select("id", { count: "exact", head: true }).eq("notice_id", id).is("ended_at", null);
    if ((count ?? 0) > 0) continue;
    const { all } = await publicNames();
    const nl = n.components.map((c) => all.get(c.monitor_id)?.nl ?? c.monitor_id).join(", ");
    const en = n.components.map((c) => all.get(c.monitor_id)?.en ?? c.monitor_id).join(", ");
    await db.from("status_notices").update({ status: "resolved", resolved_at: at, updated_at: at }).eq("id", id);
    const uid = await addUpdate(id, "resolved", autoResolveText(nl || "Alles", en || "Everything"), true, at);
    const short = await cancelPending(id);
    if (!short && n.notify) await enqueue(id, uid);
    log.push(`melding ${id} vanzelf opgelost${short ? " (kort, niet gemaild)" : ""}`);
  }
  return log;
}

/** Onderhoud begint/eindigt vanzelf volgens het tijdvak: status opslaan, update in de tijdlijn, abonnees mailen. */
async function maintenanceTransitions(notices: Notice[]): Promise<string[]> {
  const log: string[] = [];
  const now = Date.now();
  for (const n of notices) {
    if (n.kind !== "maintenance" || n.status === "cancelled" || n.status === "completed") continue;
    const eff = maintStatus(n, now);
    if (eff === n.status) continue;
    const at = new Date().toISOString();
    const patch: Record<string, unknown> = { status: eff, updated_at: at };
    if (eff === "completed") patch.resolved_at = n.window_end && Date.parse(n.window_end) <= now ? n.window_end : at;
    await db.from("status_notices").update(patch).eq("id", n.id);
    // van gepland meteen naar afgerond (planning lag stil): alleen de afronding
    const uid = await addUpdate(n.id, eff, maintText(eff === "completed" ? "completed" : "in_progress"), true, at);
    if (n.notify) await enqueue(n.id, uid);
    log.push(`onderhoud ${n.id}: ${eff}`);
  }
  return log;
}

// ---- meldingen aan abonnees (wachtrij, in porties) ----
/** Voornamen voor de aanhef ("Hoi <voornaam>,"): user_metadata.first_name van bevestigde Bingr-accounts met deze adressen
 *  (bingr_first_names, alleen service role). Abonnees zonder account of zonder naam, of als het opzoeken mislukt: geen aanhef. */
async function firstNames(emails: string[]): Promise<Map<string, string>> {
  const m = new Map<string, string>();
  if (!emails.length) return m;
  try {
    const { data, error } = await db.rpc("bingr_first_names", { p_emails: emails });
    if (error) return m;
    for (const r of (data ?? []) as { email: string; first_name: string | null }[]) {
      const n = personName(r.first_name);
      if (n && r.email) m.set(r.email.toLowerCase(), n);
    }
  } catch { /* zonder aanhef */ }
  return m;
}
async function sendTo(tx: ReturnType<typeof transport>, to: string, m: { subject: string; html: string; text: string }, unsub?: string) {
  await tx.sendMail({
    from: env("BINGR_STATUS_FROM") || smtpFrom(), to, subject: m.subject, html: m.html, text: m.text,
    headers: {
      "Auto-Submitted": "auto-generated", "X-Bingr-Mail": unsub ? "status-notice" : "status-confirm",
      ...(unsub ? { "List-Unsubscribe": `<${unsub}>`, "List-Id": "Bingr status <status.bingr.online>" } : {}),
    },
  });
}

/** Verstuurt wat er in de wachtrij staat, binnen `budgetMs` en maximaal `max` mails. Eén ronde tegelijk (eigen slot). */
async function processQueue(budgetMs: number, max: number) {
  const { data: q } = await db.from("status_mail_queue").select("id,notice_id,update_id,cursor,sent,failed").is("done_at", null).eq("cancelled", false)
    .lte("send_after", new Date().toISOString()).order("id").limit(20);
  const items = (q ?? []) as { id: number; notice_id: number; update_id: number | null; cursor: number; sent: number; failed: number }[];
  if (!items.length) return { queued: 0, sent: 0 };
  if (!smtpConfigured()) return { queued: items.length, sent: 0, skipped: "smtp" };
  const { data: got } = await db.rpc("bingr_status_mail_lock");
  if (!got) return { busy: true };
  const t0 = Date.now();
  let sent = 0, failed = 0;
  const tx = transport();
  try {
    const { visible, names } = await publicNames();
    for (const it of items) {
      if (Date.now() - t0 > budgetMs || sent + failed >= max) break;
      // samenvoegen: staat er voor dezelfde melding al een nieuwere, nog niet begonnen ronde, dan deze overslaan
      if (it.cursor === 0 && items.some((x) => x.notice_id === it.notice_id && x.id > it.id && x.cursor === 0)) {
        await db.from("status_mail_queue").update({ cancelled: true, done_at: new Date().toISOString() }).eq("id", it.id);
        continue;
      }
      const n = await loadNotice(it.notice_id);
      if (!n || !n.notify) { await db.from("status_mail_queue").update({ done_at: new Date().toISOString() }).eq("id", it.id); continue; }
      const pn = publicNotice(n, visible);
      let cursor = it.cursor, s = it.sent, f = it.failed, done = false;
      while (!done && Date.now() - t0 <= budgetMs && sent + failed < max) {
        const { data: subs } = await db.from("status_subscribers").select("id,email,lang,token").not("confirmed_at", "is", null)
          .gt("id", cursor).order("id").limit(Math.min(25, max - sent - failed));
        const list = (subs ?? []) as { id: number; email: string; lang: Lang; token: string }[];
        if (!list.length) { done = true; break; }
        const hi = await firstNames(list.map((x) => x.email));
        for (const sub of list) {
          if (Date.now() - t0 > budgetMs) break;
          try {
            await sendTo(tx, sub.email, renderNotice(pn, sub.lang === "en" ? "en" : "nl", names, sub.token, hi.get(sub.email.toLowerCase()) ?? ""), unsubscribeUrl(sub.token));
            s++; sent++;
            await db.from("status_subscribers").update({ last_sent_at: new Date().toISOString() }).eq("id", sub.id);
          } catch (e) {
            f++; failed++;
            console.error("status mail", mailErrorCode(e)); // alleen de code: de servertekst kan het adres bevatten
          }
          cursor = sub.id;
        }
      }
      await db.from("status_mail_queue").update({ cursor, sent: s, failed: f, ...(done ? { done_at: new Date().toISOString() } : {}) }).eq("id", it.id);
    }
  } finally {
    tx.close();
    await db.rpc("bingr_status_mail_unlock");
  }
  return { queued: items.length, sent, failed, ms: Date.now() - t0 };
}

function fmtDuration(s: number | undefined) {
  if (s == null) return "";
  if (s < 60) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return `${h} uur${m % 60 ? ` ${m % 60} min` : ""}`;
}

/** Eén e-mail per run met alle nieuwe en opgeloste storingen (alleen als BINGR_ALERT_EMAIL en SMTP zijn ingesteld). */
function alertMail(events: Event[]) {
  const lines = events.map((e) => e.kind === "open"
    ? `STORING: ${e.monitor.name_nl} — ${e.cause ?? "onbekende oorzaak"} (sinds ${new Date(e.started_at!).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })})`
    : `HERSTELD: ${e.monitor.name_nl}${e.duration_s != null ? ` — duurde ${fmtDuration(e.duration_s)}` : ""}`);
  const first = events[0];
  const subject = events.length > 1
    ? `Bingr-status: ${events.length} wijzigingen`
    : first.kind === "open" ? `Bingr-status: storing bij ${first.monitor.name_nl}` : `Bingr-status: ${first.monitor.name_nl} werkt weer`;
  const text = `${lines.join("\n")}\n\nStatuspagina: ${SITE}/status/\nBeheer: ${BEHEER}/`;
  const opened = events.some((e) => e.kind === "open");
  const html = layout({
    lang: "nl", docTitle: subject, preheader: lines[0], label: "Status",
    contentHtml: `${eyebrow("Monitoring")}${redBar("14px 0 22px")}${title(opened ? "Storing gemeld door de monitoring" : "Storing voorbij")}
${events.map((e, i) => `<p style="margin:0 0 10px;font-size:15px;line-height:22px;color:${e.kind === "open" ? "#ff8a80" : "#6ee68a"}">${esc(lines[i])}</p>`).join("")}
${button(`${BEHEER}/`, "Openen in beheer")}
<p style="margin:16px 0 0;font-size:13px;line-height:19px;color:#b3b3b3">Openbare statuspagina: <a href="${SITE}/status/" style="color:#ffffff">bingr.online/status</a>${opened ? ". Een automatische melding staat daar al; abonnees krijgen pas na 10 minuten een mail." : ""}</p>`,
    footerHtml: footerHtml({ lang: "nl", reasonHtml: "Melding van de statusmonitor van Bingr aan BINGR_ALERT_EMAIL." }),
  });
  return { subject, text, html };
}
async function alert(events: Event[]): Promise<boolean | string> {
  const to = env("BINGR_ALERT_EMAIL");
  if (!to || !smtpConfigured()) return false;
  const { subject, text, html } = alertMail(events);
  const tx = transport();
  try {
    await tx.sendMail({ from: smtpFrom(), to, subject, text, html, headers: { "Auto-Submitted": "auto-generated", "X-Bingr-Mail": "status-alert" } });
    return true;
  } catch (e) {
    console.error("status alert", mailErrorCode(e));
    return "failed";
  } finally { tx.close(); }
}

/** Voorbeeld van de statusmails naar één adres (beheer of mailtest); onderwerp met "[Voorbeeld]". */
async function mailPreview(b: Record<string, unknown>) {
  const to = validEmail(b.to);
  if (!to) return { status: 400, body: { error: "bad_email" } };
  if (!smtpConfigured()) return { status: 503, body: { error: "mail_unavailable" } };
  const lang: Lang = b.lang === "en" ? "en" : "nl";
  const kind = b.kind === "alert" ? "alert" : "notice";
  const tag = lang === "en" ? "[Preview] " : "[Voorbeeld] ";
  const tx = transport();
  try {
    if (kind === "alert") {
      const now = new Date().toISOString();
      const m = alertMail([{ kind: "open", monitor: { id: "preview", name_nl: "Voorbeeld" } as unknown as MonitorRow, cause: "voorbeeld (geen echte storing)", started_at: now }]);
      await tx.sendMail({ from: smtpFrom(), to, subject: tag + m.subject, text: m.text, html: m.html, headers: { "Auto-Submitted": "auto-generated", "X-Bingr-Mail": "status-alert-preview" } });
    } else {
      const { visible, names } = await publicNames();
      const latest = (await loadNotices(90)).find(shownOnPage);
      const now = Date.now();
      const pn: PublicNotice = latest ? publicNotice(latest, visible) : {
        id: 0, kind: "incident", title: { nl: "Voorbeeldmelding", en: "Sample notice" }, impact: "minor", status: "resolved",
        started_at: new Date(now - 3600e3).toISOString(), resolved_at: new Date(now).toISOString(), window_start: null, window_end: null, components: [],
        updates: [{ status: "resolved", body: { nl: "Dit is een voorbeeld; er is geen storing.", en: "This is a sample; there is no incident." }, at: new Date(now).toISOString() }],
      };
      // token van een niet-bestaande abonnee: afmelden doet niets
      const token = "0".repeat(48);
      const m = renderNotice(pn, lang, names, token, "");
      await sendTo(tx, to, { ...m, subject: tag + m.subject }, unsubscribeUrl(token));
    }
  } catch (e) {
    console.error("status preview", e instanceof Error ? e.name : "fout");
    return { status: 502, body: { error: "mail_failed" } };
  } finally { tx.close(); }
  return { status: 200, body: { ok: true } };
}

// ---- beheer van meldingen ----
const str = (v: unknown, n: number) => String(v ?? "").replace(/\r\n/g, "\n").trim().slice(0, n);
const isoOrNull = (v: unknown) => {
  if (v == null || v === "") return null;
  const t = Date.parse(String(v));
  return Number.isFinite(t) ? new Date(t).toISOString() : undefined; // undefined = ongeldig
};

async function knownMonitors(): Promise<Set<string>> {
  const { data } = await db.from("status_monitors").select("id");
  return new Set(((data ?? []) as { id: string }[]).map((r) => r.id));
}
function parseComponents(v: unknown, kind: string, known: Set<string>): { monitor_id: string; impact: CompImpact }[] | string {
  if (!Array.isArray(v)) return [];
  if (v.length > 40) return "too_many_components";
  const out = new Map<string, CompImpact>();
  for (const c of v) {
    const id = str((c as { id?: unknown })?.id, 40);
    if (!known.has(id)) return "bad_component";
    const imp = kind === "maintenance" ? "maintenance" : String((c as { impact?: unknown })?.impact ?? "major") as CompImpact;
    if (kind !== "maintenance" && !COMP_IMPACTS.includes(imp)) return "bad_impact";
    out.set(id, imp);
  }
  return [...out].map(([monitor_id, impact]) => ({ monitor_id, impact }));
}

/** Meteen een eerste portie mailen na een wijziging uit het beheer (de planning doet de rest). */
async function mailSoon() {
  try { return await processQueue(15_000, 25); } catch (e) { console.error("status queue", e instanceof Error ? e.message : e); return { error: "failed" }; }
}
const invalidate = () => { publicCache = null; feedCache = new Map(); };

async function noticeSave(b: Record<string, unknown>) {
  const id = b.id == null || b.id === "" ? null : Number(b.id);
  const cur = id ? await loadNotice(id) : null;
  if (id && !cur) return { status: 404, body: { error: "not_found" } };
  const kind = cur?.kind ?? (b.kind === "maintenance" ? "maintenance" : "incident");
  const row: Record<string, unknown> = { title_nl: str(b.title_nl, 140), title_en: str(b.title_en, 140), updated_at: new Date().toISOString() };
  if (!row.title_nl) return { status: 400, body: { error: "title_missing" } };
  if (b.notify !== undefined) row.notify = b.notify !== false;
  if (kind === "incident") {
    const impact = String(b.impact ?? cur?.impact ?? "minor");
    if (!IMPACTS.includes(impact as never)) return { status: 400, body: { error: "bad_impact" } };
    row.impact = impact;
    if (b.auto_resolve !== undefined) row.auto_resolve = b.auto_resolve === true;
    if (b.started_at !== undefined) {
      const s = isoOrNull(b.started_at);
      if (!s || Date.parse(s) > Date.now() + 60_000) return { status: 400, body: { error: "bad_time" } };
      row.started_at = s;
    }
  } else {
    row.impact = "maintenance";
    const ws = isoOrNull(b.window_start ?? cur?.window_start), we = isoOrNull(b.window_end ?? cur?.window_end);
    if (!ws || !we || Date.parse(we) <= Date.parse(ws) || Date.parse(we) - Date.parse(ws) > 31 * 864e5) return { status: 400, body: { error: "bad_window" } };
    row.window_start = ws; row.window_end = we; row.started_at = ws;
  }
  const comps = b.components === undefined && cur ? null : parseComponents(b.components, kind, await knownMonitors());
  if (typeof comps === "string") return { status: 400, body: { error: comps } };

  if (cur) {
    row.edited = true;
    // onderhoud: nieuw tijdvak kan de status terugzetten (bv. verschoven naar later)
    if (kind === "maintenance" && (cur.status === "scheduled" || cur.status === "in_progress")) {
      row.status = maintStatus({ status: "scheduled", window_start: row.window_start as string, window_end: row.window_end as string });
      if (row.status === "completed") row.resolved_at = row.window_end;
    }
    const { error } = await db.from("status_notices").update(row).eq("id", cur.id);
    if (error) throw new Error(error.message);
    if (comps) {
      await db.from("status_notice_components").delete().eq("notice_id", cur.id);
      if (comps.length) await db.from("status_notice_components").insert(comps.map((c) => ({ notice_id: cur.id, ...c })));
    }
    invalidate();
    return { status: 200, body: { ok: true, id: cur.id } };
  }

  // nieuw: eerste update in de tijdlijn is verplicht (dat is wat abonnees en de pagina lezen)
  const msg = { body_nl: str(b.message_nl, 4000), body_en: str(b.message_en, 4000) };
  if (!msg.body_nl) return { status: 400, body: { error: "message_missing" } };
  let status = String(b.status ?? (kind === "incident" ? "investigating" : "scheduled"));
  if (kind === "incident" && !INCIDENT_STATUSES.includes(status as never)) return { status: 400, body: { error: "bad_status" } };
  if (kind === "maintenance") status = maintStatus({ status: "scheduled", window_start: row.window_start as string, window_end: row.window_end as string });
  const at = new Date().toISOString();
  const { data, error } = await db.from("status_notices").insert({
    kind, ...row, status, notify: b.notify !== false, auto: false, auto_resolve: false, edited: true,
    started_at: row.started_at ?? at, resolved_at: status === "resolved" || status === "completed" ? at : null,
  }).select("id").single();
  if (error) throw new Error(error.message);
  const nid = data.id as number;
  if (comps && comps.length) await db.from("status_notice_components").insert(comps.map((c) => ({ notice_id: nid, ...c })));
  const uid = await addUpdate(nid, status, msg, false, at);
  let mailed: unknown = null;
  if (b.notify !== false) { await enqueue(nid, uid); mailed = await mailSoon(); }
  invalidate();
  return { status: 200, body: { ok: true, id: nid, queued: b.notify !== false, mailed } };
}

async function noticeUpdate(b: Record<string, unknown>) {
  const n = await loadNotice(Number(b.id));
  if (!n) return { status: 404, body: { error: "not_found" } };
  const status = String(b.status ?? effectiveStatus(n));
  const allowed: string[] = n.kind === "incident" ? INCIDENT_STATUSES : MAINT_STATUSES;
  if (!allowed.includes(status)) return { status: 400, body: { error: "bad_status" } };
  const msg = { body_nl: str(b.message_nl, 4000), body_en: str(b.message_en, 4000) };
  if (!msg.body_nl) return { status: 400, body: { error: "message_missing" } };
  if (b.components !== undefined) {
    const comps = parseComponents(b.components, n.kind, await knownMonitors());
    if (typeof comps === "string") return { status: 400, body: { error: comps } };
    await db.from("status_notice_components").delete().eq("notice_id", n.id);
    if (comps.length) await db.from("status_notice_components").insert(comps.map((c) => ({ notice_id: n.id, ...c })));
  }
  const at = new Date().toISOString();
  const closing = ["resolved", "completed", "cancelled"].includes(status);
  const patch: Record<string, unknown> = { status, updated_at: at, edited: true, resolved_at: closing ? (n.resolved_at ?? at) : null };
  // onderhoud met de hand begonnen/afgerond: tijdvak volgt, anders zet de planning de status terug
  if (n.kind === "maintenance" && status === "in_progress" && n.window_start && Date.parse(n.window_start) > Date.now()) patch.window_start = at;
  if (n.kind === "maintenance" && status === "completed" && n.window_end && Date.parse(n.window_end) > Date.now()) patch.window_end = at;
  if (n.kind === "maintenance" && status === "scheduled" && n.window_start && Date.parse(n.window_start) <= Date.now()) return { status: 400, body: { error: "bad_status" } };
  if (closing && n.auto_resolve) patch.auto_resolve = false;
  const { error } = await db.from("status_notices").update(patch).eq("id", n.id);
  if (error) throw new Error(error.message);
  const uid = await addUpdate(n.id, status, msg, false, at);
  const notify = b.notify !== false && n.notify !== false;
  let mailed: unknown = null;
  if (notify) { await enqueue(n.id, uid); mailed = await mailSoon(); }
  invalidate();
  return { status: 200, body: { ok: true, queued: notify, mailed } };
}

// ---- abonneren ----
const ipHits = new Map<string, number[]>();
function ipLimited(ip: string, max = 5, windowMs = 10 * 60_000) {
  const now = Date.now();
  const hits = (ipHits.get(ip) ?? []).filter((t) => now - t < windowMs);
  hits.push(now);
  ipHits.set(ip, hits);
  if (ipHits.size > 5000) ipHits.clear();
  return hits.length > max;
}
const newToken = () => Array.from(crypto.getRandomValues(new Uint8Array(24)), (x) => x.toString(16).padStart(2, "0")).join("");

async function subscribe(b: Record<string, unknown>, ip: string) {
  if (str(b.website, 200)) return { status: 400, body: { error: "spam" } };
  const email = validEmail(b.email);
  if (!email) return { status: 400, body: { error: "bad_email" } };
  const lang: Lang = b.lang === "en" ? "en" : "nl";
  if (ipLimited(ip)) return { status: 429, body: { error: "too_many" } };
  if (!smtpConfigured()) return { status: 503, body: { error: "mail_unavailable" } };
  const { count } = await db.from("status_subscribers").select("id", { count: "exact", head: true }).gt("created_at", new Date(Date.now() - 3600e3).toISOString());
  if ((count ?? 0) > 300) return { status: 429, body: { error: "too_many" } };
  const { data: ex } = await db.from("status_subscribers").select("id,token,confirmed_at,confirm_sent_at,lang").eq("email", email).maybeSingle();
  // bestaat het adres al en is het bevestigd: zelfde antwoord (we verklappen niet wie er geabonneerd is)
  if (ex?.confirmed_at) return { status: 200, body: { ok: true } };
  if (ex && ex.confirm_sent_at && Date.now() - Date.parse(ex.confirm_sent_at) < 10 * 60_000) return { status: 200, body: { ok: true } };
  let token = ex?.token as string | undefined;
  if (ex) {
    await db.from("status_subscribers").update({ lang, confirm_sent_at: new Date().toISOString(), created_at: new Date().toISOString() }).eq("id", ex.id);
  } else {
    token = newToken();
    const { error } = await db.from("status_subscribers").insert({ email, lang, token, confirm_sent_at: new Date().toISOString() });
    if (error) {
      if (error.code === "23505") return { status: 200, body: { ok: true } };
      throw new Error(error.message);
    }
  }
  const hi = await firstNames([email]);
  const tx = transport();
  try { await sendTo(tx, email, renderConfirm(lang, token!, hi.get(email.toLowerCase()) ?? "")); }
  catch (e) { console.error("status confirm", e instanceof Error ? e.message : e); return { status: 502, body: { error: "mail_failed" } }; }
  finally { tx.close(); }
  return { status: 200, body: { ok: true } };
}

async function confirm(b: Record<string, unknown>) {
  if (!validToken(b.token)) return { status: 400, body: { error: "bad_token" } };
  const { data } = await db.from("status_subscribers").select("id,lang,confirmed_at,created_at").eq("token", b.token as string).maybeSingle();
  if (!data) return { status: 404, body: { error: "not_found" } };
  if (!data.confirmed_at) {
    if (Date.now() - Date.parse(data.created_at) > 7 * 864e5) return { status: 410, body: { error: "expired" } };
    await db.from("status_subscribers").update({ confirmed_at: new Date().toISOString() }).eq("id", data.id);
  }
  return { status: 200, body: { ok: true, lang: data.lang } };
}

async function unsubscribe(b: Record<string, unknown>) {
  if (!validToken(b.token)) return { status: 400, body: { error: "bad_token" } };
  const { data } = await db.from("status_subscribers").delete().eq("token", b.token as string).select("id");
  return { status: 200, body: { ok: true, removed: (data ?? []).length > 0 } };
}

// ---- beheer van monitors ----
function privateHost(h: string) {
  const host = h.toLowerCase().replace(/^\[|\]$/g, "");
  return host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") || host.includes(":") ||
    /^(127\.|10\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(host) || /^\d+$/.test(host);
}

async function saveMonitor(b: Record<string, unknown>) {
  const s = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);
  const id = b.id == null || b.id === "" ? null : s(b.id, 40);
  let cur: MonitorRow | null = null;
  if (id) {
    const { data } = await db.from("status_monitors").select("*").eq("id", id).maybeSingle();
    if (!data) return { status: 404, body: { error: "not_found" } };
    cur = data as MonitorRow;
  }
  const kind = cur?.kind ?? "http";
  const row: Record<string, unknown> = {
    name_nl: s(b.name_nl, 60), name_en: s(b.name_en, 60) || s(b.name_nl, 60),
    interval_min: Number(b.interval_min), public: b.public === true, enabled: b.enabled !== false,
  };
  if (!row.name_nl) return { status: 400, body: { error: "name_missing" } };
  if (!INTERVALS.includes(row.interval_min as number)) return { status: 400, body: { error: "bad_interval" } };
  if (kind === "devices") row.public = false;
  if (!cur || !cur.builtin) {
    const grp = s(b.grp, 20);
    if (!GROUPS.some((g) => g.id === grp)) return { status: 400, body: { error: "bad_group" } };
    row.grp = grp;
  }
  if (kind === "http") {
    let u: URL;
    try { u = new URL(s(b.target, 500)); } catch { return { status: 400, body: { error: "bad_url" } }; }
    if ((u.protocol !== "https:" && u.protocol !== "http:") || u.username || u.password || privateHost(u.hostname)) {
      return { status: 400, body: { error: "bad_url" } };
    }
    row.target = u.toString();
    row.keyword = s(b.keyword, 100) || null;
  }
  if (cur) {
    if (!row.enabled || row.target !== undefined && row.target !== cur.target) {
      // uitgezet of ander adres: een lopende storing afsluiten en opnieuw beginnen
      row.fail_streak = 0; row.ok_streak = 0; row.last_state = null;
      const at = new Date().toISOString();
      const { data: openOut } = await db.from("status_incidents").select("notice_id").eq("monitor_id", cur.id).is("ended_at", null).maybeSingle();
      await db.from("status_incidents").update({ ended_at: at }).eq("monitor_id", cur.id).is("ended_at", null);
      if (openOut) await autoNotices([{ kind: "close", monitor: cur, notice_id: openOut.notice_id as number | null }], at).catch(() => []);
    }
    const { error } = await db.from("status_monitors").update(row).eq("id", cur.id);
    if (error) throw new Error(error.message);
    publicCache = null;
    return { status: 200, body: { ok: true, id: cur.id } };
  }
  const newId = `c-${Array.from(crypto.getRandomValues(new Uint8Array(4)), (x) => x.toString(16).padStart(2, "0")).join("")}`;
  const { error } = await db.from("status_monitors").insert({ id: newId, kind: "http", sort: 200, builtin: false, ...row });
  if (error) throw new Error(error.message);
  publicCache = null;
  return { status: 200, body: { ok: true, id: newId } };
}

// ---- verzoeken ----
const xml = (body: string, type: string) =>
  new Response(body, { status: 200, headers: { ...cors, "Content-Type": `${type}; charset=utf-8`, "Cache-Control": "public, max-age=300" } });

// Versies voor de downloadknoppen (app_settings.release_channels), 60 s in het geheugen; bij een fout geen versies.
let relCache: { at: number; body: ReturnType<typeof releasesView> } | null = null;
async function releases() {
  if (relCache && Date.now() - relCache.at < 60_000) return relCache.body;
  const { data, error } = await db.from("app_settings").select("value").eq("key", "release_channels").maybeSingle();
  if (error) throw new Error(error.message);
  relCache = { at: Date.now(), body: releasesView(data?.value) };
  return relCache.body;
}

/** Openbare acties (GET met ?action= of POST met {action}). null = geen openbare actie. */
async function publicAction(action: string, p: Record<string, unknown>, req: Request): Promise<Response | null> {
  switch (action) {
    case "public": return json(await publicSummary(), 200, "public, max-age=60");
    case "ping": return json({ ok: true });
    case "releases": return json(await releases(), 200, "public, max-age=60");
    case "history": return json(await history(Number(p.page ?? 1)), 200, "public, max-age=60");
    case "notice": {
      const id = Number(p.id);
      if (!Number.isInteger(id) || id < 1) return json({ error: "bad_id" }, 400);
      const r = await noticeDetail(id);
      return r ? json(r, 200, "public, max-age=60") : json({ error: "not_found" }, 404);
    }
    case "feed": {
      const format = p.format === "rss" ? "rss" : "atom";
      return xml(await feed(format, p.lang === "en" ? "en" : "nl"), format === "rss" ? "application/rss+xml" : "application/atom+xml");
    }
    case "subscribe": case "confirm": case "unsubscribe": {
      if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      const r = action === "subscribe" ? await subscribe(p, clientIp(req)) : action === "confirm" ? await confirm(p) : await unsubscribe(p);
      return json(r.body, r.status);
    }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.method === "GET") {
      const q = Object.fromEntries(new URL(req.url).searchParams);
      const r = await publicAction(q.action ?? "public", q, req);
      return r ?? json({ error: "unknown_action" }, 400);
    }
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    let body: Record<string, unknown>;
    try {
      const text = await req.text();
      if (text.length > 16384) return json({ error: "too_large" }, 413);
      body = JSON.parse(text || "{}");
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    } catch { return json({ error: "bad_json" }, 400); }
    const action = String(body.action ?? "");
    const pr = await publicAction(action, body, req);
    if (pr) return pr;

    const mailtest = action === "mail_preview" && isMailtestAddress(body.to) &&
      await mailtestOk(req.headers.get(MAILTEST_HEADER), async () => (await db.from("app_settings").select("value").eq("key", "mailtest").maybeSingle()).data?.value);
    if (!mailtest && !(await sameSecret(req.headers.get("x-status-secret") ?? ""))) return json({ error: "forbidden" }, env("STATUS_CRON_SECRET") ? 403 : 503);

    switch (action) {
      case "run": {
        const only = body.monitor_id ? String(body.monitor_id).slice(0, 40) : null;
        return json(await run(body.force === true || !!only, only, String(body.source ?? "cron")));
      }
      case "admin":
        return json(await adminSummary());
      case "checks": {
        const id = String(body.monitor_id ?? "").slice(0, 40);
        const limit = Math.min(Math.max(Number(body.limit ?? 300) || 300, 1), 500);
        const { data, error } = await db.from("status_checks").select("at,ok,state,status_code,ms,error,detail")
          .eq("monitor_id", id).gt("at", new Date(Date.now() - 24 * 3600e3).toISOString()).order("at", { ascending: false }).limit(limit);
        if (error) throw new Error(error.message);
        return json({ items: data ?? [] });
      }
      case "monitor_save": {
        const r = await saveMonitor(body);
        return json(r.body, r.status);
      }
      case "monitor_delete": {
        const id = String(body.id ?? "").slice(0, 40);
        const { data } = await db.from("status_monitors").select("builtin").eq("id", id).maybeSingle();
        if (!data) return json({ error: "not_found" }, 404);
        if (data.builtin) return json({ error: "builtin" }, 400);
        const { error } = await db.from("status_monitors").delete().eq("id", id);
        if (error) throw new Error(error.message);
        invalidate();
        return json({ ok: true });
      }
      case "notice_save": {
        const r = await noticeSave(body);
        return json(r.body, r.status);
      }
      case "notice_update": {
        const r = await noticeUpdate(body);
        return json(r.body, r.status);
      }
      case "notice_delete": {
        const id = Number(body.id);
        if (!Number.isInteger(id) || id < 1) return json({ error: "bad_id" }, 400);
        const { data, error } = await db.from("status_notices").delete().eq("id", id).select("id");
        if (error) throw new Error(error.message);
        if (!(data ?? []).length) return json({ error: "not_found" }, 404);
        invalidate();
        return json({ ok: true });
      }
      case "subscribers":
        return json(await subscriberCounts());
      case "mail_run":
        return json(await processQueue(40_000, 80));
      case "mail_preview": {
        const r = await mailPreview(body);
        return json(r.body, r.status);
      }
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error("status", e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});
