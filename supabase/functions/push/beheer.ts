// Bingr push: meldingen naar de beheer-app Bingr Beheer (docs/PUSH.md, "Beheer-app"). Stap `adminNotify` van de cron
// (elke minuut): nieuwe tickets, klantantwoorden, builds en statuswijzigingen naar apparaten in admin_push_devices, via APNs
// met topic BEHEER_APNS_TOPIC (standaard nl.lrvdlinden.bingr.beheer) en dezelfde APNS_KEY_P8/ID/TEAM.
// Logs en het antwoord bevatten alleen tellingen en foutcodes: nooit tokens, onderwerpen, berichten of e-mailadressen.
import { fetchBuildManifest } from "../_shared/builds.ts";
import type { Apns } from "./channels.ts";
import {
  type BeheerNotice, beheerPayload, buildNotices, type Builds, initState, manifestBuilds, manifestDue, type MonitorNow,
  purchaseMark, purchaseNotices, type PurchaseRow, replyNotices, type ReplyRow, type State, statusNotices, ticketNotices, type TicketRow, wants,
} from "./beheer_logic.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
type Env = (k: string) => string | undefined;
export type BeheerResult = { notices: number; sent: number; invalid: number; failed: number; skipped?: string };

const DEFAULT_TOPIC = "nl.lrvdlinden.bingr.beheer";

async function maxOf(db: Db, table: string, col: string): Promise<number> {
  const { data, error } = await db.from(table).select(col).order(col, { ascending: false }).limit(1);
  if (error) throw new Error(`${table}: ${error.code ?? "fout"}`);
  return Number(data?.[0]?.[col] ?? 0) || 0;
}

async function loadMonitors(db: Db): Promise<MonitorNow[]> {
  const [mon, inc] = await Promise.all([
    db.from("status_monitors").select("id,name_nl,kind,enabled").eq("enabled", true),
    db.from("status_incidents").select("monitor_id,started_at").is("ended_at", null),
  ]);
  if (mon.error) throw new Error(`status_monitors: ${mon.error.code ?? "fout"}`);
  const open = new Map(((inc.data ?? []) as { monitor_id: string; started_at: string }[]).map((r) => [r.monitor_id, r.started_at]));
  return ((mon.data ?? []) as { id: string; name_nl: string; kind: string }[])
    .filter((m) => m.kind !== "devices")
    .map((m) => ({ id: m.id, name: m.name_nl, down: open.has(m.id), since: open.get(m.id) ?? null }));
}

async function newTickets(db: Db, after: number): Promise<TicketRow[]> {
  const { data, error } = await db.from("support_tickets").select("number,subject").gt("number", after).order("number").limit(50);
  if (error) throw new Error(`support_tickets: ${error.code ?? "fout"}`);
  return (data ?? []) as TicketRow[];
}

/** Nieuwe berichten na het watermerk; geeft de klantberichten (met ticketnummer en of het het eerste is) en het hoogste id. */
async function newReplies(db: Db, after: number): Promise<{ rows: ReplyRow[]; maxId: number }> {
  const { data, error } = await db.from("support_messages").select("id,ticket_id,author,body").gt("id", after).order("id").limit(100);
  if (error) throw new Error(`support_messages: ${error.code ?? "fout"}`);
  const all = (data ?? []) as { id: number; ticket_id: string; author: string; body: string }[];
  const maxId = all.reduce((m, r) => Math.max(m, Number(r.id)), after);
  const cust = all.filter((r) => r.author === "customer");
  if (!cust.length) return { rows: [], maxId };
  const ids = [...new Set(cust.map((r) => r.ticket_id))];
  const [tk, firsts] = await Promise.all([
    db.from("support_tickets").select("id,number").in("id", ids),
    db.from("support_messages").select("id,ticket_id").in("ticket_id", ids).eq("author", "customer").order("id").limit(1000),
  ]);
  const num = new Map(((tk.data ?? []) as { id: string; number: number }[]).map((t) => [t.id, Number(t.number)]));
  const first = new Map<string, number>();
  for (const r of (firsts.data ?? []) as { id: number; ticket_id: string }[]) if (!first.has(r.ticket_id)) first.set(r.ticket_id, Number(r.id));
  const rows = cust.filter((r) => num.has(r.ticket_id)).map((r) => ({
    id: Number(r.id), number: num.get(r.ticket_id)!, body: r.body, first: first.get(r.ticket_id) === Number(r.id),
  }));
  return { rows, maxId };
}

export async function adminNotify(db: Db, apns: Apns, env: Env, nowMs = Date.now(), f: typeof fetch = fetch): Promise<BeheerResult> {
  const res: BeheerResult = { notices: 0, sent: 0, invalid: 0, failed: 0 };
  const { data: row, error: re } = await db.from("admin_push_state").select("*").eq("id", 1).maybeSingle();
  if (re) throw new Error(`admin_push_state: ${re.code ?? "fout"}`);
  const prev = (row ?? null) as (Partial<State> & { updated_at?: string }) | null;

  // huidige stand ophalen (alleen wat nodig is)
  const monitors = await loadMonitors(db);
  const hasT = prev?.last_ticket_number != null, hasM = prev?.last_message_id != null;
  const [maxTicket, maxMessage] = await Promise.all([
    hasT ? 0 : maxOf(db, "support_tickets", "number"),
    hasM ? 0 : maxOf(db, "support_messages", "id"),
  ]);
  let builds: Builds | null = null;
  let checkedAt = prev?.builds_checked_at ?? null;
  const key = (env("BINGR_BUILDS_KEY") || "").trim();
  if (key.length >= 32 && manifestDue(checkedAt, nowMs)) {
    checkedAt = new Date(nowMs).toISOString();
    try {
      const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 10_000);
      try { builds = manifestBuilds(await fetchBuildManifest(key, { fetch: f, signal: ctl.signal, ua: "BingrPush/1.0" })); }
      finally { clearTimeout(timer); }
    } catch (e) { console.error("push beheer manifest", e instanceof Error ? e.message.slice(0, 60) : "fout"); }
  }

  const { state, armed } = initState(prev, { maxTicket, maxMessage, builds, monitors }, nowMs);
  state.builds_checked_at = checkedAt;
  const notices: BeheerNotice[] = [];

  if (armed.ticket) {
    const t = await newTickets(db, state.last_ticket_number!);
    notices.push(...ticketNotices(t));
    state.last_ticket_number = t.reduce((m, r) => Math.max(m, Number(r.number)), state.last_ticket_number!);
  }
  if (armed.reply) {
    const r = await newReplies(db, state.last_message_id!);
    notices.push(...replyNotices(r.rows));
    state.last_message_id = r.maxId;
  }
  if (armed.build && builds) {
    const b = buildNotices(builds, state.builds!);
    notices.push(...b.notices);
    state.builds = b.mark;
  }
  // build 133: nieuwe betaalde Lifetime-aankopen (billing_purchases.paid_at na het watermerk). Eerste keer: watermerk = nu.
  // Ontbreekt de tabel of de kolom nog (ouder schema), dan stil overslaan.
  const prevPurchase = (prev as { last_purchase_at?: string | null } | null)?.last_purchase_at ?? null;
  let lastPurchase: string | undefined = prevPurchase ?? new Date(nowMs).toISOString();
  if (prevPurchase) {
    const { data, error } = await db.from("billing_purchases").select("paid_at,amount,currency").eq("status", "paid")
      .gt("paid_at", prevPurchase).order("paid_at").limit(50);
    if (error) { console.error("push beheer aankopen", error.code ?? "fout"); lastPurchase = prevPurchase; }
    else {
      const rows = (data ?? []) as PurchaseRow[];
      notices.push(...purchaseNotices(rows));
      lastPurchase = purchaseMark(rows, prevPurchase);
    }
  }
  if (prev && !("last_purchase_at" in prev)) lastPurchase = undefined; // kolom bestaat nog niet
  if (armed.status) {
    const s = statusNotices(monitors, state.monitors!, nowMs);
    notices.push(...s.notices);
    state.monitors = s.mark;
  }

  // Watermerken eerst vastleggen (optimistisch: alleen als niemand anders tussendoor schreef), dan pas versturen. Zo
  // verstuurt een tweede, gelijktijdige ronde niets dubbel.
  const upd = { ...state, ...(lastPurchase !== undefined ? { last_purchase_at: lastPurchase } : {}), updated_at: new Date(nowMs).toISOString() };
  if (!prev) {
    const { data, error } = await db.from("admin_push_state").upsert({ id: 1, ...upd }, { onConflict: "id", ignoreDuplicates: true }).select("id");
    if (error) throw new Error(`admin_push_state: ${error.code ?? "fout"}`);
    if (!data?.length) return { ...res, skipped: "busy" };
  } else {
    const { data, error } = await db.from("admin_push_state").update(upd).eq("id", 1).eq("updated_at", prev.updated_at).select("id");
    if (error) throw new Error(`admin_push_state: ${error.code ?? "fout"}`);
    if (!data?.length) return { ...res, skipped: "busy" };
  }

  res.notices = notices.length;
  if (!notices.length) return res;
  if (!apns.configured()) return { ...res, skipped: "apns_not_configured" };
  const { data: devs, error: de } = await db.from("admin_push_devices").select("id,token,sandbox,prefs,last_error").limit(50);
  if (de) throw new Error(`admin_push_devices: ${de.code ?? "fout"}`);
  const devices = (devs ?? []) as { id: number; token: string; sandbox: boolean; prefs: unknown; last_error: string | null }[];
  if (!devices.length) return { ...res, skipped: "no_devices" };

  const topic = env("BEHEER_APNS_TOPIC") || DEFAULT_TOPIC;
  const gone = new Set<number>();
  const errs = new Map<number, string>();
  const okIds = new Set<number>();
  for (const n of notices) {
    const payload = beheerPayload(n);
    await Promise.all(devices.filter((d) => !gone.has(d.id) && wants(d.prefs, n.kind)).map(async (d) => {
      let o;
      try { o = await apns.post(d.token, d.sandbox === true, payload, { topic, ttlS: 86400 }); }
      catch (e) { o = { state: "failed" as const, error: `network_${(e instanceof Error ? e.name : "error").slice(0, 40)}` }; }
      if (o.state === "sent") { res.sent++; okIds.add(d.id); return; }
      if (o.state === "invalid") { res.invalid++; gone.add(d.id); return; }
      res.failed++; errs.set(d.id, (o.error ?? "apns_error").slice(0, 120));
    }));
  }
  if (gone.size) await db.from("admin_push_devices").delete().in("id", [...gone]);
  for (const [id, code] of errs) if (!gone.has(id)) await db.from("admin_push_devices").update({ last_error: code }).eq("id", id);
  // weer gelukt: oude foutcode weg
  const cleared = devices.filter((d) => d.last_error && okIds.has(d.id) && !errs.has(d.id) && !gone.has(d.id)).map((d) => d.id);
  if (cleared.length) await db.from("admin_push_devices").update({ last_error: null }).in("id", cleared);
  return res;
}
