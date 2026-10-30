// Bingr: pushmeldingen (contract docs/PUSH.md). Eigen verzending via APNs (HTTP/2), FCM HTTP v1 en Web Push (VAPID);
// geen externe pushdienst. POST /functions/v1/push met JSON {action, …}; header `apikey` altijd.
//
// Apps (ingelogd: Authorization: Bearer <access_token>):
//   register    {device_id, platform, channel, token, lang, app_version, app_build, sandbox?, tz?} -> {ok}
//               tvos/androidtv/tizen -> 400 {error:"no_push_platform"}; max. 20 per account per minuut -> 429.
//               Een token die al bij een ander account/apparaat hoort, gaat over naar dit account/apparaat.
//   unregister  {device_id} -> {ok}
//   vapid_key   {} (zonder inloggen) -> {key}   (publieke VAPID-sleutel, base64url)
// Beheer (header x-push-secret = PUSH_ADMIN_SECRET; release ook met PUSH_RELEASE_SECRET):
//   release        {platform_group:"apple"|"android", version, build} -> {ok, message_id, devices} | {ok, duplicate:true, message_id}
//   admin_send     {title_nl, body_nl, title_en?, body_en?, url?, target} -> {ok, message_id, devices, missing_channels}
//   admin_progress {message_id} -> {message_id, kind, devices, queued, sent, failed, invalid, errors, done}  (verstuurt ook een batch)
//   admin_retry    {message_id} -> {ok, retried, …progress}  (mislukte bezorgingen opnieuw in de wachtrij en meteen een batch)
//   admin_history  {page?} -> {items:[{id, kind, title, …, queued, sent, failed, invalid, errors}], page, has_more}
// Planning (header x-push-secret = PUSH_CRON_SECRET, pg_cron elke minuut):
//   cron        {} -> {ok, reminders, sent, failed, invalid, queued_left, beheer:{notices, sent, invalid, failed, skipped?}}
// Build 146: kind support_reply (antwoord van support op een ticket van het account) zet de functie support zelf in de
//   wachtrij (push_messages + bingr_push_enqueue) en roept daarna admin_progress aan; de cron verstuurt de rest.
//               (herinneringen + resterende batches + adminNotify: meldingen naar de beheer-app, zie beheer.ts)
// Fouten: 401 {error:"not_signed_in"} / BANNED_BODY, 403 {error:"forbidden"}, 400 {error:"bad_…"}.
// Logs bevatten nooit tokens, geheimen of e-mailadressen.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { openJsonField, sealJsonField, unseal } from "../_shared/sealed.ts";
import { profilesOrEmpty } from "../_shared/profiles_store.ts";
import { sameSecret } from "./crypto.ts";
import { Channels, type DeviceRow, type TokenStore } from "./channels.ts";
import { adminNotify, type BeheerResult } from "./beheer.ts";
import {
  checkRegister, checkTarget, GROUPS, MAX_ATTEMPTS, type MessageRow, parseReminders, releaseKey, reminderDue, reminderKey,
  reminderProfile, renderNotice, safeUrl, ttlFor,
} from "./logic.ts";

const env = (k: string) => Deno.env.get(k);
const admin = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
// APNs-providertoken gedeeld tussen alle instanties (tabel push_provider_tokens, versleuteld; zie channels.ts)
const tokenStore: TokenStore = {
  async load(name) {
    const { data, error } = await admin.from("push_provider_tokens").select("iat,sealed").eq("name", name).maybeSingle();
    if (error || !data) return null;
    const v = await openJsonField(data.sealed);
    return typeof v?.token === "string" ? { token: v.token, iat: Number(data.iat) } : null;
  },
  async save(name, token, iat) {
    const { data, error } = await admin.rpc("bingr_push_token_put", { p_name: name, p_iat: iat, p_sealed: await sealJsonField({ token }) });
    if (error || !data) return null;
    const v = await openJsonField((data as { sealed: string }).sealed);
    return typeof v?.token === "string" ? { token: v.token, iat: Number((data as { iat: number }).iat) } : null;
  },
};
const channels = new Channels(env, fetch, tokenStore);
const BATCH = Math.max(10, Math.min(500, Number(env("PUSH_BATCH") ?? 200) || 200));
const CONCURRENCY = 20;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Ingelogde gebruiker (zoals device-auth): 401 bij ongeldig token of geblokkeerd account, 503 als auth niet antwoordt.
async function authed(req: Request): Promise<{ id: string } | Response> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return json({ error: "not_signed_in" }, 401);
  const { data, error } = await admin.auth.getUser(token);
  if (!error && data?.user) return bannedUntilActive((data.user as { banned_until?: string }).banned_until) ? json(BANNED_BODY, 401) : data.user;
  if (isBanError(error)) return json(BANNED_BODY, 401);
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? json({ error: "not_signed_in" }, 401) : json({ error: "unavailable" }, 503);
}
async function rateLimited(key: string, max: number, windowS = 60): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: key, p_max: max, p_window: windowS });
  if (error) { console.error("rate_hit", error.message); return false; }
  return data === false;
}
const secretOk = (req: Request, ...names: string[]) => {
  const given = req.headers.get("x-push-secret");
  let ok = false;
  for (const n of names) ok = sameSecret(given, env(n)) || ok; // alle vergelijkingen uitvoeren (geen vroege return)
  return ok;
};
// Werk na het antwoord afmaken (Supabase Edge Runtime); zonder EdgeRuntime gewoon laten lopen.
function background(p: Promise<unknown>) {
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  const safe = p.catch((e) => console.error("push achtergrond", e instanceof Error ? e.message : e));
  if (rt?.waitUntil) rt.waitUntil(safe);
}
function missingChannels(): string[] {
  const m: string[] = [];
  if (!channels.apns.configured()) m.push("apns");
  if (!channels.fcm.configured()) m.push("fcm");
  if (!channels.web.configured()) m.push("webpush");
  return m;
}

// ---------- versturen in batches ----------
type Totals = { claimed: number; sent: number; failed: number; invalid: number; retry: number };
async function runBatch(messageId: number | null, t: Totals): Promise<number> {
  const { data: claimed, error } = await admin.rpc("bingr_push_claim", { p_limit: BATCH, p_message: messageId });
  if (error) throw new Error(`claim: ${error.message}`);
  const rows = (claimed ?? []) as { id: number; message_id: number; device_ref: number | null; attempts: number }[];
  if (!rows.length) return 0;
  const devIds = [...new Set(rows.map((r) => r.device_ref).filter((x): x is number => x != null))];
  const msgIds = [...new Set(rows.map((r) => r.message_id))];
  const [devRes, msgRes] = await Promise.all([
    devIds.length ? admin.from("push_devices").select("id,channel,token,sandbox,platform,lang,tz").in("id", devIds) : Promise.resolve({ data: [] }),
    admin.from("push_messages").select("id,kind,title_nl,body_nl,title_en,body_en,url,payload").in("id", msgIds),
  ]);
  const devs = new Map(((devRes.data ?? []) as (DeviceRow & { lang: string; tz: string | null })[]).map((d) => [d.id, d]));
  // build 146: payload van herinneringen en supportantwoorden staat versleuteld in payload.sealed
  const msgRows = await Promise.all(((msgRes.data ?? []) as MessageRow[]).map(async (m) => {
    const p = m.payload ?? {};
    if (typeof p.sealed !== "string") return m;
    const { sealed, ...rest } = p;
    return { ...m, payload: { ...rest, ...((await openJsonField(sealed)) ?? {}) } };
  }));
  const msgs = new Map(msgRows.map((m) => [m.id, m]));
  const results: { id: number; state: string; error?: string; tok?: string }[] = [];
  const now = Date.now();
  let i = 0;
  const worker = async () => {
    while (i < rows.length) {
      const r = rows[i++];
      const dev = r.device_ref != null ? devs.get(r.device_ref) : undefined;
      const msg = msgs.get(r.message_id);
      if (!dev || !msg) { results.push({ id: r.id, state: "failed", error: "device_removed" }); t.failed++; continue; }
      if (msg.kind === "reminder" && Number(msg.payload?.start_ms) <= now) {
        results.push({ id: r.id, state: "failed", error: "too_late" }); t.failed++; continue;
      }
      const o = await channels.send(dev, renderNotice(msg, dev), ttlFor(msg, now));
      if (o.state === "retry" && r.attempts < MAX_ATTEMPTS) { results.push({ id: r.id, state: "queued", error: o.error }); t.retry++; continue; }
      const state = o.state === "retry" ? "failed" : o.state;
      results.push({ id: r.id, state, error: o.error, tok: state === "invalid" ? dev.token : undefined });
      t[state]++;
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, rows.length) }, worker));
  const { error: fe } = await admin.rpc("bingr_push_finish", { p_results: results });
  if (fe) throw new Error(`finish: ${fe.message}`);
  t.claimed += rows.length;
  return rows.length;
}
async function drain(messageId: number | null, budgetMs: number): Promise<Totals> {
  const t: Totals = { claimed: 0, sent: 0, failed: 0, invalid: 0, retry: 0 };
  const until = Date.now() + budgetMs;
  while (Date.now() < until) {
    const n = await runBatch(messageId, t);
    if (n < BATCH) break;
  }
  return t;
}

// ---------- herinneringen ----------
// Accounts met push-apparaten -> state-section `reminders` (versleuteld, zoals device-auth hem schrijft) -> 2 minuten
// voor de start één bericht per (account, herinnering-id); de wachtrij is uniek per (bericht, apparaat).
async function reminders(nowMs: number): Promise<number> {
  let after: string | null = null, made = 0;
  for (let page = 0; page < 50; page++) {
    const { data: users, error }: { data: unknown; error: { message: string } | null } = await admin.rpc("bingr_push_users", { p_after: after, p_limit: 500 });
    if (error) throw new Error(`users: ${error.message}`);
    const ids: string[] = ((users ?? []) as { user_id: string }[]).map((u) => u.user_id);
    if (!ids.length) break;
    after = ids[ids.length - 1];
    for (let c = 0; c < ids.length; c += 100) {
      const chunk = ids.slice(c, c + 100);
      const { data: rows } = await admin.from("account_state").select("user_id,data").eq("section", "reminders").in("user_id", chunk);
      for (const row of (rows ?? []) as { user_id: string; data: string }[]) {
        let due;
        try { due = parseReminders(await unseal(row.data)).filter((r) => reminderDue(r.startMs, nowMs)); } catch { continue; }
        if (!due.length) continue;
        // build 146: profielen uit de versleutelde lijst; titel, zender en profielnaam versleuteld in de payload
        const profiles = await profilesOrEmpty(admin, row.user_id);
        for (const r of due) {
          const prof = reminderProfile(profiles, r.profileId);
          const key = reminderKey(row.user_id, r.id);
          await admin.from("push_messages").upsert({
            kind: "reminder", dedup_key: key, target: { accounts: [row.user_id] }, created_by: "cron",
            payload: {
              start_ms: r.startMs,
              sealed: await sealJsonField({ title: r.title, channel_id: r.channelId, channel_name: r.channelName, profile_id: prof.id, profile_name: prof.name }),
            },
          }, { onConflict: "dedup_key", ignoreDuplicates: true });
          const { data: m } = await admin.from("push_messages").select("id").eq("dedup_key", key).maybeSingle();
          if (!m) continue;
          const { data: n } = await admin.rpc("bingr_push_enqueue", { p_message: m.id, p_all: false, p_accounts: [row.user_id], p_platforms: null, p_below_build: null });
          made += Number(n ?? 0);
        }
      }
    }
    if (ids.length < 500) break;
  }
  return made;
}

async function progress(id: number) {
  const { data: m } = await admin.from("push_messages").select("id,kind,devices,counts,finished_at").eq("id", id).maybeSingle();
  if (!m) return null;
  const c = (m.counts ?? {}) as Record<string, unknown>;
  const queued = Number(c.queued ?? m.devices);
  return {
    message_id: m.id, kind: m.kind, devices: m.devices, queued, sent: Number(c.sent ?? 0), failed: Number(c.failed ?? 0),
    invalid: Number(c.invalid ?? 0), errors: c.errors ?? {}, done: queued === 0 && !!m.finished_at,
  };
}

const str = (v: unknown, max: number) => { const s = String(v ?? "").trim(); return s && s.length <= max ? s : null; };

async function handle(req: Request, body: Record<string, unknown>): Promise<Response> {
  switch (body.action) {
    case "vapid_key": {
      const key = env("VAPID_PUBLIC_KEY");
      return key ? json({ key }) : json({ error: "not_configured" }, 503);
    }
    case "register": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      if (await rateLimited(`push-reg:u:${user.id}`, 20)) return json({ error: "rate_limited" }, 429);
      const r = checkRegister(body);
      if ("error" in r) return json(r, 400);
      const { count } = await admin.from("push_devices").select("id", { count: "exact", head: true }).eq("user_id", user.id);
      if ((count ?? 0) >= 30) {
        const { data: own } = await admin.from("push_devices").select("id").eq("user_id", user.id).eq("device_id", r.device_id).maybeSingle();
        if (!own) return json({ error: "too_many_devices" }, 409);
      }
      // dezelfde token bij een ander account of apparaat: die registratie vervalt (token gaat over)
      const { data: same } = await admin.from("push_devices").select("id,user_id,device_id").eq("channel", r.channel).eq("token", r.token);
      const other = ((same ?? []) as { id: number; user_id: string; device_id: string }[])
        .filter((d) => d.user_id !== user.id || d.device_id !== r.device_id).map((d) => d.id);
      if (other.length) await admin.from("push_devices").delete().in("id", other);
      const row = {
        user_id: user.id, device_id: r.device_id, platform: r.platform, channel: r.channel, token: r.token, lang: r.lang, tz: r.tz,
        app_version: r.app_version, app_build: r.app_build, sandbox: r.sandbox, updated_at: new Date().toISOString(), last_error: null,
      };
      let { error } = await admin.from("push_devices").upsert(row, { onConflict: "user_id,device_id" });
      if (error?.code === "23505") { // gelijktijdige registratie van dezelfde token: nog één keer
        await admin.from("push_devices").delete().eq("channel", r.channel).eq("token", r.token);
        ({ error } = await admin.from("push_devices").upsert(row, { onConflict: "user_id,device_id" }));
      }
      if (error) throw new Error(`register: ${error.message}`);
      return json({ ok: true });
    }
    case "unregister": {
      const user = await authed(req);
      if (user instanceof Response) return user;
      const device_id = str(body.device_id, 80);
      if (!device_id) return json({ error: "bad_device_id" }, 400);
      await admin.from("push_devices").delete().eq("user_id", user.id).eq("device_id", device_id);
      return json({ ok: true });
    }
    case "release": {
      if (!secretOk(req, "PUSH_RELEASE_SECRET", "PUSH_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
      // wie verstuurde: het beheer (PUSH_ADMIN_SECRET, knop in Downloads) of de oude weg (PUSH_RELEASE_SECRET, workflow Builds)
      const fromBeheer = secretOk(req, "PUSH_ADMIN_SECRET");
      const group = String(body.platform_group ?? "");
      const build = Number(body.build);
      const version = String(body.version ?? "").trim();
      if (!GROUPS[group]) return json({ error: "bad_platform_group" }, 400);
      if (!Number.isInteger(build) || build <= 0 || build > 1e7) return json({ error: "bad_build" }, 400);
      if (!/^[0-9][0-9A-Za-z.\-]{0,19}$/.test(version)) return json({ error: "bad_version" }, 400);
      const key = releaseKey(group, build);
      const { data: ins, error } = await admin.from("push_messages").upsert({
        kind: "release", dedup_key: key, platform_group: group, build, payload: { version, build, platform_group: group },
        target: { platforms: GROUPS[group], below_build: build }, created_by: fromBeheer ? "beheer" : "builds",
      }, { onConflict: "dedup_key", ignoreDuplicates: true }).select("id");
      if (error) throw new Error(`release: ${error.message}`);
      if (!ins?.length) {
        const { data: m } = await admin.from("push_messages").select("id").eq("dedup_key", key).maybeSingle();
        return json({ ok: true, duplicate: true, message_id: m?.id ?? null });
      }
      const id = ins[0].id;
      const { data: n, error: e2 } = await admin.rpc("bingr_push_enqueue", { p_message: id, p_all: false, p_accounts: null, p_platforms: GROUPS[group], p_below_build: build });
      if (e2) throw new Error(`enqueue: ${e2.message}`);
      await admin.rpc("bingr_push_refresh", { p_ids: [id] });
      background(drain(id, 40_000));
      return json({ ok: true, message_id: id, devices: Number(n ?? 0), missing_channels: missingChannels() });
    }
    case "admin_send": {
      if (!secretOk(req, "PUSH_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
      const title_nl = str(body.title_nl, 120), body_nl = str(body.body_nl, 1000);
      if (!title_nl || !body_nl) return json({ error: "bad_text" }, 400);
      const title_en = str(body.title_en, 120), body_en = str(body.body_en, 1000);
      if ((body.title_en || body.body_en) && !(title_en && body_en)) return json({ error: "bad_text" }, 400);
      let url: string | null = null;
      if (body.url != null && String(body.url).trim() !== "") { url = safeUrl(body.url); if (!url) return json({ error: "bad_url" }, 400); }
      const target = checkTarget(body.target);
      if (!target) return json({ error: "bad_target" }, 400);
      const { data: m, error } = await admin.from("push_messages").insert({
        kind: "admin", title_nl, body_nl, title_en, body_en, url, target, created_by: str(body.created_by, 80) ?? "beheer",
      }).select("id").single();
      if (error) throw new Error(`admin_send: ${error.message}`);
      const { data: n, error: e2 } = await admin.rpc("bingr_push_enqueue", {
        p_message: m.id, p_all: "all" in target, p_accounts: "accounts" in target ? target.accounts : null,
        p_platforms: "platforms" in target ? target.platforms : null, p_below_build: null,
      });
      if (e2) throw new Error(`enqueue: ${e2.message}`);
      await admin.rpc("bingr_push_refresh", { p_ids: [m.id] });
      background(drain(m.id, 40_000));
      return json({ ok: true, message_id: m.id, devices: Number(n ?? 0), missing_channels: missingChannels() });
    }
    case "admin_progress": {
      if (!secretOk(req, "PUSH_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
      const id = Number(body.message_id);
      if (!Number.isInteger(id) || id <= 0) return json({ error: "bad_message_id" }, 400);
      await drain(id, 15_000);
      const p = await progress(id);
      return p ? json(p) : json({ error: "not_found" }, 404);
    }
    case "admin_retry": {
      if (!secretOk(req, "PUSH_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
      const id = Number(body.message_id);
      if (!Number.isInteger(id) || id <= 0) return json({ error: "bad_message_id" }, 400);
      const { data: n, error } = await admin.rpc("bingr_push_retry", { p_message: id });
      if (error) throw new Error(`retry: ${error.message}`);
      if (Number(n ?? 0) > 0) await drain(id, 15_000);
      const p = await progress(id);
      return p ? json({ ok: true, retried: Number(n ?? 0), ...p }) : json({ error: "not_found" }, 404);
    }
    case "admin_history": {
      if (!secretOk(req, "PUSH_ADMIN_SECRET")) return json({ error: "forbidden" }, 403);
      const page = Math.max(0, Math.min(1000, Math.floor(Number(body.page ?? 0)) || 0)), size = 20;
      const { data, error } = await admin.from("push_messages")
        .select("id,kind,title_nl,body_nl,title_en,body_en,url,target,platform_group,build,payload,devices,counts,created_at,created_by,finished_at")
        .in("kind", ["admin", "release"]).order("id", { ascending: false }).range(page * size, page * size + size);
      if (error) throw new Error(`history: ${error.message}`);
      const rows = data ?? [];
      // deno-lint-ignore no-explicit-any
      const items = rows.slice(0, size).map((m: Record<string, any>) => {
        const c = (m.counts ?? {}) as Record<string, unknown>;
        return {
          id: m.id, kind: m.kind, title_nl: m.title_nl, body_nl: m.body_nl, title_en: m.title_en, body_en: m.body_en, url: m.url,
          target: m.target, platform_group: m.platform_group, build: m.build, version: (m.payload as Record<string, unknown>)?.version ?? null,
          devices: m.devices, queued: Number(c.queued ?? 0), sent: Number(c.sent ?? 0), failed: Number(c.failed ?? 0),
          invalid: Number(c.invalid ?? 0), errors: c.errors ?? {}, created_at: m.created_at, created_by: m.created_by, finished_at: m.finished_at,
        };
      });
      return json({ items, page, has_more: rows.length > size, missing_channels: missingChannels() });
    }
    case "cron": {
      if (!secretOk(req, "PUSH_CRON_SECRET")) return json({ error: "forbidden" }, 403);
      const started = Date.now();
      let made = 0;
      try { made = await reminders(started); } catch (e) { console.error("push herinneringen", e instanceof Error ? e.message : e); }
      let beheer: BeheerResult | { error: string };
      try { beheer = await adminNotify(admin, channels.apns, env, Date.now()); }
      catch (e) { console.error("push beheer", e instanceof Error ? e.message.slice(0, 80) : "fout"); beheer = { error: "failed" }; }
      const t = await drain(null, Math.max(5_000, 45_000 - (Date.now() - started)));
      const { count } = await admin.from("push_deliveries").select("id", { count: "exact", head: true }).in("state", ["queued", "sending"]);
      return json({ ok: true, reminders: made, sent: t.sent, failed: t.failed, invalid: t.invalid, retry: t.retry, queued_left: count ?? 0, beheer });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
}

const MAX_BODY = 64 * 1024;
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
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
    console.error("push", String(body.action ?? ""), e instanceof Error ? e.message : e);
    return json({ error: "server_error" }, 500);
  }
});
