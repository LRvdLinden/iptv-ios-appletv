// Bingr: status en monitoring (bingr.online/status en de tab Status in het beheer).
//   GET  /functions/v1/status?action=public   (of POST {action:"public"}) — openbaar, ~60 s in de cache:
//        {generated_at, overall:{state, down:[id], degraded:[id]}, groups:[{id, name:{nl,en}, monitors:[{id, name:{nl,en},
//         state, checked_at, ms24, uptime:{d1,d7,d30,d90}, days:[{d, u, s}]}]}], incidents:[{id, monitor_id, name, started_at,
//         ended_at, duration_s}]}. Alleen openbare monitors; geen gebruikers- of apparaataantallen.
// Met header `x-status-secret: <STATUS_CRON_SECRET>` (pg_cron en de admin-functie; het geheim staat alleen op de server):
//   run            {force?, monitor_id?}  -> controleert wat aan de beurt is, slaat op, opent/sluit storingen, mailt
//   admin          {}                     -> als public, maar alle monitors + instellingen, apparaten, planning, oorzaken
//   checks         {monitor_id, limit?}   -> ruwe controles van de laatste 24 uur (nieuwste eerst)
//   monitor_save   {id?, name_nl, name_en, grp, target, keyword?, interval_min, public, enabled}
//   monitor_delete {id}                   -> alleen eigen monitors; standaardmonitors kun je uitzetten
import { createClient } from "jsr:@supabase/supabase-js@2";
import { smtpConfigured, smtpFrom, transport } from "../_shared/mail.ts";
import { type Monitor, runCheck } from "./checks.ts";
import { type DayRow, daySeries, durationS, evaluate, isDue, overall, type State, uptimePct, windowUptime } from "./logic.ts";

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

async function summary(full: boolean) {
  const [monitors, dataRes] = await Promise.all([loadMonitors(), db.rpc("bingr_status_data", { p_days: 90 })]);
  if (dataRes.error) throw new Error(dataRes.error.message);
  const data = dataRes.data as { today: string; daily: DayRow[]; last24: { m: string; n: number; x: number; ms: number | null }[]; incidents: Incident[] };
  const today = String(data.today).slice(0, 10);
  const openSet = new Set(data.incidents.filter((i) => !i.ended_at).map((i) => i.m));
  const visible = monitors.filter((m) => full || (m.public && m.enabled && m.kind !== "devices"));
  const out = visible.map((m) => {
    const rows = data.daily.filter((r) => r.m === m.id);
    const l24 = data.last24.find((r) => r.m === m.id);
    const state: State | null = !m.enabled || m.kind === "devices" ? null : openSet.has(m.id) ? "down" : m.last_state;
    const base = {
      id: m.id, name: { nl: m.name_nl, en: m.name_en }, group: m.grp, state, checked_at: m.last_checked_at,
      ms24: l24?.ms ?? null,
      uptime: { d1: l24 ? uptimePct(l24.n, l24.x) : null, d7: windowUptime(rows, today, 7), d30: windowUptime(rows, today, 30), d90: windowUptime(rows, today, 90) },
      days: daySeries(rows, today, 90).map(({ d, u, s }) => ({ d, u, s })),
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
  const ov = overall(out.filter((m) => m.state !== null && (full ? (m as { enabled?: boolean }).enabled !== false : true)).map((m) => ({ id: m.id, state: m.state })));
  return {
    generated_at: new Date().toISOString(),
    overall: ov,
    groups: GROUPS.map((g) => ({ ...g, monitors: out.filter((m) => m.group === g.id).map(({ group: _g, ...m }) => m) })).filter((g) => g.monitors.length),
    incidents,
  };
}

let publicCache: { at: number; body: unknown } | null = null;
async function publicSummary() {
  if (publicCache && Date.now() - publicCache.at < 60_000) return publicCache.body;
  const body = await summary(false);
  publicCache = { at: Date.now(), body };
  return body;
}

function maskEmail(e: string) {
  const at = e.lastIndexOf("@");
  if (at < 1) return e ? "***" : "";
  const d = e.slice(at + 1), dot = d.lastIndexOf(".");
  return `${e[0]}***@${d[0] ?? ""}***${dot > 0 ? d.slice(dot) : ""}`;
}

async function adminSummary() {
  const [s, dev, cron, runner] = await Promise.all([
    summary(true), db.rpc("bingr_status_devices"), db.rpc("bingr_status_cron"),
    db.from("status_runner").select("last_run_at,last_source").eq("id", 1).maybeSingle(),
  ]);
  const alert = env("BINGR_ALERT_EMAIL");
  return {
    ...s,
    devices: dev.data ?? [],
    scheduler: { cron: cron.data ?? null, last_run_at: runner.data?.last_run_at ?? null, last_source: runner.data?.last_source ?? null },
    alerts: { email: alert ? maskEmail(alert) : null, smtp: smtpConfigured() },
    intervals: INTERVALS,
  };
}

// ---- controleren ----
interface Event { kind: "open" | "close"; monitor: MonitorRow; cause?: string | null; started_at?: string; duration_s?: number }

async function run(force: boolean, onlyId: string | null, source: string) {
  const { data: got, error: le } = await db.rpc("bingr_status_lock", { p_source: source });
  if (le) throw new Error(le.message);
  if (!got) return { busy: true };
  const t0 = Date.now();
  try {
    const monitors = (await loadMonitors()).filter((m) => m.enabled && m.kind !== "devices" && (!onlyId || m.id === onlyId));
    const due = monitors.filter((m) => force || isDue(m.last_checked_at, m.interval_min, t0));
    const { data: openRows } = await db.from("status_incidents").select("id,monitor_id,started_at").is("ended_at", null);
    const open = new Map((openRows ?? []).map((r) => [r.monitor_id as string, r as { id: number; started_at: string }]));
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
      const ev = evaluate({ fail_streak: m.fail_streak, ok_streak: m.ok_streak, open: open.has(m.id) }, r);
      rows.push({ monitor_id: m.id, at, ok: r.ok, state: ev.checkState, status_code: r.code ?? null, ms: r.ms ?? null,
        error: r.ok ? null : (r.error ?? "fout").slice(0, 160), detail: r.detail ? String(r.detail).slice(0, 160) : null });
      updates.push(db.from("status_monitors").update({
        last_checked_at: at, last_state: ev.current, last_ms: r.ms ?? null, last_error: r.ok ? null : (r.error ?? "fout").slice(0, 160),
        fail_streak: ev.fail_streak, ok_streak: ev.ok_streak,
      }).eq("id", m.id));
      if (ev.open) {
        events.push({ kind: "open", monitor: m, cause: r.error ?? null, started_at: at });
        updates.push(db.from("status_incidents").insert({ monitor_id: m.id, started_at: at, cause: (r.error ?? "fout").slice(0, 160) }));
      }
      if (ev.close) {
        const inc = open.get(m.id);
        events.push({ kind: "close", monitor: m, started_at: inc?.started_at, duration_s: inc ? durationS(inc.started_at, at) : undefined });
        updates.push(db.from("status_incidents").update({ ended_at: at }).eq("monitor_id", m.id).is("ended_at", null));
      }
      summaryRows.push({ id: m.id, state: ev.current, ok: r.ok, ms: r.ms ?? null, error: r.ok ? null : r.error ?? null, detail: r.detail ?? null });
    }
    if (rows.length) {
      const { error } = await db.from("status_checks").insert(rows);
      if (error) throw new Error(error.message);
    }
    await Promise.all(updates);
    let mailed: boolean | string = false;
    if (events.length) mailed = await alert(events);
    await db.rpc("bingr_status_cleanup");
    publicCache = null;
    return {
      checked: rows.length, skipped, due: due.length, total: monitors.length,
      up: summaryRows.filter((r) => r.state === "up").length,
      degraded: summaryRows.filter((r) => r.state === "degraded").length,
      down: summaryRows.filter((r) => r.state === "down").length,
      opened: events.filter((e) => e.kind === "open").map((e) => e.monitor.id),
      closed: events.filter((e) => e.kind === "close").map((e) => e.monitor.id),
      mailed, ms: Date.now() - t0, results: summaryRows,
    };
  } finally {
    await db.rpc("bingr_status_unlock");
  }
}

function fmtDuration(s: number | undefined) {
  if (s == null) return "";
  if (s < 60) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return `${h} uur${m % 60 ? ` ${m % 60} min` : ""}`;
}
const escHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

/** Eén e-mail per run met alle nieuwe en opgeloste storingen (alleen als BINGR_ALERT_EMAIL en SMTP zijn ingesteld). */
async function alert(events: Event[]): Promise<boolean | string> {
  const to = env("BINGR_ALERT_EMAIL");
  if (!to || !smtpConfigured()) return false;
  const lines = events.map((e) => e.kind === "open"
    ? `STORING: ${e.monitor.name_nl} — ${e.cause ?? "onbekende oorzaak"} (sinds ${new Date(e.started_at!).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })})`
    : `HERSTELD: ${e.monitor.name_nl}${e.duration_s != null ? ` — duurde ${fmtDuration(e.duration_s)}` : ""}`);
  const first = events[0];
  const subject = events.length > 1
    ? `Bingr-status: ${events.length} wijzigingen`
    : first.kind === "open" ? `Bingr-status: storing bij ${first.monitor.name_nl}` : `Bingr-status: ${first.monitor.name_nl} werkt weer`;
  const text = `${lines.join("\n")}\n\nStatuspagina: ${SITE}/status/\nBeheer: ${BEHEER}/`;
  const html = `<!doctype html><html><body style="margin:0;background:#000;padding:24px;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#fff">
<div style="max-width:520px;margin:0 auto;background:#141414;border-radius:12px;border-top:4px solid #E50914;padding:24px">
<div style="font-weight:900;font-size:22px;margin-bottom:14px">BINGR <span style="color:#b3b3b3;font-weight:600;font-size:14px">Status</span></div>
${events.map((e, i) => `<p style="margin:0 0 10px;font-size:15px;line-height:22px;color:${e.kind === "open" ? "#ff8a80" : "#6ee68a"}">${escHtml(lines[i])}</p>`).join("")}
<p style="margin:18px 0 0;font-size:13px"><a href="${SITE}/status/" style="color:#fff">Statuspagina</a> · <a href="${BEHEER}/" style="color:#b3b3b3">Beheer</a></p>
</div></body></html>`;
  const tx = transport();
  try {
    await tx.sendMail({ from: smtpFrom(), to, subject, text, html });
    return true;
  } catch (e) {
    console.error("status alert", e instanceof Error ? e.message : e);
    return "failed";
  } finally { tx.close(); }
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
      await db.from("status_incidents").update({ ended_at: new Date().toISOString() }).eq("monitor_id", cur.id).is("ended_at", null);
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
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.method === "GET") {
      const action = new URL(req.url).searchParams.get("action") ?? "public";
      if (action !== "public") return json({ error: "unknown_action" }, 400);
      return json(await publicSummary(), 200, "public, max-age=60");
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
    if (action === "public") return json(await publicSummary(), 200, "public, max-age=60");
    if (action === "ping") return json({ ok: true });

    if (!(await sameSecret(req.headers.get("x-status-secret") ?? ""))) return json({ error: "forbidden" }, env("STATUS_CRON_SECRET") ? 403 : 503);

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
        publicCache = null;
        return json({ ok: true });
      }
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error("status", e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});
