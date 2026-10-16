// Bingr push: pure logica (geen database, geen netwerk), zodat alles met `deno test` te controleren is.
// Contract: docs/PUSH.md.

export const SITE = "https://bingr.online";
export const LANGS = ["nl", "en", "de", "fr", "es", "it", "pt", "tr", "pl", "ar", "zh-Hans"] as const;
export type Lang = typeof LANGS[number];

// Platforms met systeem-push en hun kanaal. tvos, androidtv en tizen registreren niet (geen meldingen in beeld).
export const CHANNEL_OF: Record<string, "apns" | "fcm" | "webpush"> = {
  ios: "apns", ipados: "apns", macos: "apns", android: "fcm", web: "webpush",
};
export const NO_PUSH = new Set(["tvos", "androidtv", "tizen"]);
export const GROUPS: Record<string, string[]> = { apple: ["ios", "ipados", "macos"], android: ["android"] };
export const PLATFORM_NAME: Record<string, string> = { ios: "iPhone", ipados: "iPad", macos: "Mac", android: "Android", web: "Web" };

// App-taal naar een van de ondersteunde talen; onbekend -> en. "zh", "zh-CN", "zh_Hans" -> zh-Hans; "pt-BR" -> pt.
export function normLang(v: unknown): Lang {
  const s = String(v ?? "").trim().replace(/_/g, "-");
  if (!s) return "en";
  if (/^zh\b/i.test(s)) return "zh-Hans";
  const base = s.split("-")[0].toLowerCase();
  return (LANGS as readonly string[]).includes(base) ? base as Lang : "en";
}

type ReleaseT = { title: string; body: string };
const RELEASE: Record<Lang, ReleaseT> = {
  nl: { title: "Bingr {v} (Build {b}) is beschikbaar", body: "Nieuw voor {p}. Tik om de wijzigingen te bekijken." },
  en: { title: "Bingr {v} (Build {b}) is available", body: "New for {p}. Tap to see what's changed." },
  de: { title: "Bingr {v} (Build {b}) ist verfügbar", body: "Neu für {p}. Tippe, um die Änderungen zu sehen." },
  fr: { title: "Bingr {v} (build {b}) est disponible", body: "Nouveau pour {p}. Touchez pour voir les nouveautés." },
  es: { title: "Bingr {v} (compilación {b}) ya está disponible", body: "Novedades para {p}. Toca para ver los cambios." },
  it: { title: "Bingr {v} (build {b}) è disponibile", body: "Novità per {p}. Tocca per vedere le modifiche." },
  pt: { title: "Bingr {v} (build {b}) está disponível", body: "Novidades para {p}. Toque para ver o que mudou." },
  tr: { title: "Bingr {v} (Derleme {b}) kullanıma sunuldu", body: "{p} için yenilikler. Değişiklikleri görmek için dokunun." },
  pl: { title: "Bingr {v} (kompilacja {b}) jest dostępny", body: "Nowości dla {p}. Stuknij, aby zobaczyć zmiany." },
  ar: { title: "Bingr {v} (الإصدار {b}) متاح الآن", body: "جديد لـ {p}. اضغط لعرض التغييرات." },
  "zh-Hans": { title: "Bingr {v}（版本 {b}）现已推出", body: "{p} 版有更新。轻点查看更新内容。" },
};
// Herinnering: {n} = profielnaam (alleen bij meer dan één profiel), {t} = programma, {time} = starttijd (HH:MM).
const REMINDER: Record<Lang, { withProfile: string; plain: string }> = {
  nl: { withProfile: "Voor {n}: {t} begint om {time}", plain: "{t} begint om {time}" },
  en: { withProfile: "For {n}: {t} starts at {time}", plain: "{t} starts at {time}" },
  de: { withProfile: "Für {n}: {t} beginnt um {time}", plain: "{t} beginnt um {time}" },
  fr: { withProfile: "Pour {n} : {t} commence à {time}", plain: "{t} commence à {time}" },
  es: { withProfile: "Para {n}: {t} empieza a las {time}", plain: "{t} empieza a las {time}" },
  it: { withProfile: "Per {n}: {t} inizia alle {time}", plain: "{t} inizia alle {time}" },
  pt: { withProfile: "Para {n}: {t} começa às {time}", plain: "{t} começa às {time}" },
  tr: { withProfile: "{n} için: {t}, başlangıç {time}", plain: "{t}, başlangıç {time}" },
  pl: { withProfile: "Dla {n}: {t} zaczyna się o {time}", plain: "{t} zaczyna się o {time}" },
  ar: { withProfile: "لـ {n}: يبدأ {t} في {time}", plain: "يبدأ {t} في {time}" },
  "zh-Hans": { withProfile: "{n}：{t} 将于 {time} 开始", plain: "{t} 将于 {time} 开始" },
};
const fill = (s: string, v: Record<string, string>) => s.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? "");

export function releaseText(lang: unknown, version: string, build: number, platform: string): ReleaseT {
  const t = RELEASE[normLang(lang)];
  const v = { v: version, b: String(build), p: PLATFORM_NAME[platform] ?? platform };
  return { title: fill(t.title, v), body: fill(t.body, v) };
}

export const DEFAULT_TZ = "Europe/Amsterdam";
export function validTz(tz: unknown): string | null {
  const s = String(tz ?? "").trim();
  if (!s || s.length > 64) return null;
  try { new Intl.DateTimeFormat("en", { timeZone: s }); return s; } catch { return null; }
}
export function timeIn(ms: number, tz: unknown): string {
  const f = new Intl.DateTimeFormat("en-GB", { timeZone: validTz(tz) ?? DEFAULT_TZ, hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  return f.format(new Date(ms));
}
export function reminderBody(lang: unknown, r: { profileName?: string | null; title: string; startMs: number }, tz: unknown): string {
  const t = REMINDER[normLang(lang)];
  const v = { n: r.profileName ?? "", t: r.title, time: timeIn(r.startMs, tz) };
  return fill(r.profileName ? t.withProfile : t.plain, v);
}

// Teksten van een beheerbericht: nl voor nl-apparaten, anders en (ontbreekt en, dan nl).
export function adminText(lang: unknown, m: { title_nl: string; body_nl: string; title_en?: string | null; body_en?: string | null }) {
  if (normLang(lang) === "nl" || !(m.title_en && m.body_en)) return { title: m.title_nl, body: m.body_nl };
  return { title: m.title_en, body: m.body_en };
}

// ---------- links ----------
export function releaseLinks(platform: string, build: number) {
  return {
    url: `${SITE}/changelog/?p=${encodeURIComponent(platform)}#build-${build}`,
    deeplink: `bingr://changelog?p=${encodeURIComponent(platform)}&b=${build}`,
  };
}
export function reminderLinks(channelId: string, profileId: string | null) {
  const q = `channel=${encodeURIComponent(channelId)}${profileId ? `&profile=${encodeURIComponent(profileId)}` : ""}`;
  return { url: `${SITE}/web/#/live?${q}`, deeplink: `bingr://live?${q}` };
}
// Alleen https-links uit het beheer; anders geen url (de app opent zichzelf).
export function safeUrl(v: unknown): string | null {
  const s = String(v ?? "").trim();
  if (!s || s.length > 1000) return null;
  try { const u = new URL(s); return u.protocol === "https:" ? u.href : null; } catch { return null; }
}

// ---------- payloads per kanaal ----------
export type Notice = { title: string; body: string; data: Record<string, string> };
// url ontbreekt alleen bij een beheerbericht zonder link (dan opent de app zichzelf).
export function noticeData(kind: string, msgId: number | string, url: string | null, deeplink?: string | null): Record<string, string> {
  const d: Record<string, string> = { kind, msg_id: String(msgId) };
  if (url) d.url = url;
  if (deeplink) d.deeplink = deeplink;
  return d;
}

export type MessageRow = {
  id: number; kind: string; title_nl?: string | null; body_nl?: string | null; title_en?: string | null; body_en?: string | null;
  url?: string | null; payload?: Record<string, unknown> | null;
};
export type DevInfo = { platform: string; lang: string; tz?: string | null };
// Tekst en data van een bericht voor één apparaat (taal, platform en tijdzone van dat apparaat).
export function renderNotice(m: MessageRow, d: DevInfo): Notice {
  const p = m.payload ?? {};
  if (m.kind === "release") {
    const build = Number(p.build), t = releaseText(d.lang, String(p.version ?? "1.0.0"), build, d.platform);
    const l = releaseLinks(d.platform, build);
    return { ...t, data: noticeData("release", m.id, l.url, l.deeplink) };
  }
  if (m.kind === "reminder") {
    const l = reminderLinks(String(p.channel_id ?? ""), p.profile_id ? String(p.profile_id) : null);
    const body = reminderBody(d.lang, { profileName: p.profile_name ? String(p.profile_name) : null, title: String(p.title ?? ""), startMs: Number(p.start_ms) }, d.tz);
    return { title: String(p.channel_name || "Bingr"), body, data: noticeData("reminder", m.id, l.url, l.deeplink) };
  }
  const t = adminText(d.lang, { title_nl: m.title_nl ?? "", body_nl: m.body_nl ?? "", title_en: m.title_en, body_en: m.body_en });
  return { ...t, data: noticeData("admin", m.id, m.url ?? null) };
}
// Hoe lang een pushdienst het bericht mag bewaren (s): herinnering tot de start, overige 1 dag.
export function ttlFor(m: MessageRow, nowMs: number): number {
  if (m.kind === "reminder") return Math.max(30, Math.floor((Number(m.payload?.start_ms) - nowMs) / 1000));
  return 86400;
}
// APNs: {aps:{alert:{title, body}, sound}, data:{kind, url?, deeplink?, msg_id}} en dezelfde sleutels ook plat naast aps
// (de Apple-app leest beide).
export function apnsPayload(n: Notice) {
  return { ...n.data, aps: { alert: { title: n.title, body: n.body }, sound: "default", "thread-id": n.data.kind }, data: n.data };
}
// FCM HTTP v1: data-only (geen notification-blok), alle waarden strings: title, body, kind, url?, deeplink?, msg_id.
// De Android-app toont de melding zelf (kanalen releases/messages/reminders) en ontdubbelt op msg_id.
export function fcmMessage(token: string, n: Notice, ttlS = 86400) {
  return {
    message: {
      token,
      data: { title: n.title, body: n.body, ...n.data },
      android: { priority: "high", ttl: `${Math.max(0, Math.floor(ttlS))}s`, collapse_key: `bingr-${n.data.msg_id}` },
    },
  };
}
// Web Push: JSON {title, body, data} (service worker bingr.online/web/sw.js).
export function webPayload(n: Notice) {
  return { title: n.title, body: n.body, data: n.data };
}

// ---------- registratie ----------
const WEBPUSH_HOSTS = ["fcm.googleapis.com", "android.googleapis.com", "push.services.mozilla.com", "push.apple.com", "notify.windows.com"];
export function webpushHostAllowed(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    if (u.protocol !== "https:" || u.port || u.username || u.password) return false;
    const h = u.hostname.toLowerCase();
    return WEBPUSH_HOSTS.some((s) => h === s || h.endsWith("." + s));
  } catch { return false; }
}
export type WebSub = { endpoint: string; p256dh: string; auth: string };
export function parseWebSub(token: string): WebSub | null {
  try {
    const j = JSON.parse(token);
    const endpoint = String(j?.endpoint ?? ""), p256dh = String(j?.keys?.p256dh ?? ""), auth = String(j?.keys?.auth ?? "");
    if (!webpushHostAllowed(endpoint) || endpoint.length > 1000) return null;
    if (!/^[A-Za-z0-9_\-+/=]{80,100}$/.test(p256dh) || !/^[A-Za-z0-9_\-+/=]{16,30}$/.test(auth)) return null;
    return { endpoint, p256dh, auth };
  } catch { return null; }
}

export type RegisterInput = {
  device_id: string; platform: string; channel: "apns" | "fcm" | "webpush"; token: string; lang: Lang;
  app_version: string | null; app_build: number | null; sandbox: boolean; tz: string | null;
};
// Controle van {action:"register", …}; geeft de schone rij of een foutcode.
export function checkRegister(b: Record<string, unknown>): RegisterInput | { error: string } {
  const device_id = String(b.device_id ?? "").trim();
  if (!device_id || device_id.length > 80) return { error: "bad_device_id" };
  const platform = String(b.platform ?? "").trim().toLowerCase();
  if (NO_PUSH.has(platform)) return { error: "no_push_platform" };
  const channel = CHANNEL_OF[platform];
  if (!channel) return { error: "bad_platform" };
  if (String(b.channel ?? "") !== channel) return { error: "bad_channel" };
  let token = String(b.token ?? "").trim();
  if (channel === "apns") {
    token = token.toLowerCase();
    if (!/^[0-9a-f]{64,200}$/.test(token)) return { error: "bad_token" };
  } else if (channel === "fcm") {
    if (!/^[A-Za-z0-9_:\-.]{20,4096}$/.test(token)) return { error: "bad_token" };
  } else {
    const sub = parseWebSub(token);
    if (!sub) return { error: "bad_token" };
    token = JSON.stringify({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } });
  }
  const buildN = Number(b.app_build);
  const app_build = Number.isInteger(buildN) && buildN >= 0 && buildN < 1e7 ? buildN : null;
  const v = String(b.app_version ?? "").trim().slice(0, 40);
  return {
    device_id, platform, channel, token, lang: normLang(b.lang), app_version: v || null, app_build,
    sandbox: channel === "apns" && b.sandbox === true, tz: validTz(b.tz),
  };
}

// ---------- doelgroep beheerbericht ----------
export type Target = { all: true } | { accounts: string[] } | { platforms: string[] };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function checkTarget(t: unknown): Target | null {
  const o = (t && typeof t === "object" && !Array.isArray(t)) ? t as Record<string, unknown> : null;
  if (!o) return null;
  if (o.all === true) return { all: true };
  if (Array.isArray(o.accounts)) {
    const a = [...new Set(o.accounts.map((x) => String(x).toLowerCase()).filter((x) => UUID.test(x)))].slice(0, 1000);
    return a.length ? { accounts: a } : null;
  }
  if (Array.isArray(o.platforms)) {
    const p = [...new Set(o.platforms.map((x) => String(x).toLowerCase()).filter((x) => CHANNEL_OF[x]))];
    return p.length ? { platforms: p } : null;
  }
  return null;
}

// ---------- dedup ----------
export const releaseKey = (group: string, build: number) => `release:${group}:${build}`;
export const reminderKey = (userId: string, reminderId: string) => `reminder:${userId}:${reminderId}`;

// ---------- herinneringen (state-section `reminders`, docs/ACCOUNT.md "Herinneringen per profiel") ----------
export type Reminder = { id: string; profileId: string | null; channelId: string; channelName: string; title: string; startMs: number };
function toMs(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v > 1e12 ? v : v * 1000; // seconden of milliseconden
  const t = Date.parse(String(v ?? ""));
  return Number.isFinite(t) ? t : NaN;
}
export function parseReminders(state: unknown): Reminder[] {
  const s = (state && typeof state === "object") ? state as Record<string, unknown> : {};
  const list = Array.isArray(s.items) ? s.items : Array.isArray(s.reminders) ? s.reminders : Array.isArray(s.list) ? s.list : [];
  const removed = (s.removed && typeof s.removed === "object") ? s.removed as Record<string, unknown> : {};
  const out: Reminder[] = [];
  for (const raw of list.slice(0, 2000)) {
    if (!raw || typeof raw !== "object") continue;
    const r = raw as Record<string, unknown>;
    const id = String(r.id ?? "").slice(0, 200);
    if (!id || r.deleted === true) continue;
    if (removed[id] != null) {
      const rm = toMs(removed[id]), at = toMs(r.at);
      if (!(Number.isFinite(at) && Number.isFinite(rm) && at > rm)) continue;
    }
    const channelId = String(r.channelID ?? r.channelId ?? r.channel_id ?? r.channel ?? "").slice(0, 200);
    const startMs = toMs(r.start ?? r.startDate ?? r.start_at);
    if (!channelId || !Number.isFinite(startMs)) continue;
    let profileId = r.profileID ?? r.profileId ?? null;
    if (!profileId) { const m = /^p:([^:]+):/.exec(id); profileId = m ? m[1] : null; }
    out.push({
      id, channelId, startMs,
      profileId: profileId ? String(profileId).toLowerCase().slice(0, 80) : null,
      channelName: String(r.channelName ?? r.channel_name ?? "").slice(0, 120),
      title: String(r.title ?? r.programTitle ?? r.program ?? "").slice(0, 200),
    });
  }
  return out;
}
// Stuur 2 minuten vóór de start (cron elke minuut; 5 s marge vóór, tot de start zelf).
export const REMIND_BEFORE_MS = 120_000;
export function reminderDue(startMs: number, nowMs: number): boolean {
  return nowMs >= startMs - REMIND_BEFORE_MS - 5_000 && nowMs < startMs;
}
// Profielnaam en -id voor een herinnering: zonder profiel = hoofdprofiel (isMain). Naam alleen als er meer dan één profiel is.
export type ProfileRow = { id?: unknown; name?: unknown; isMain?: unknown; deleted?: unknown };
export function reminderProfile(profiles: unknown, profileId: string | null): { id: string | null; name: string | null } {
  const list = (Array.isArray(profiles) ? profiles : []).filter((p): p is ProfileRow => !!p && typeof p === "object" && (p as ProfileRow).deleted !== true);
  const p = profileId
    ? list.find((x) => String(x.id ?? "").toLowerCase() === profileId)
    : list.find((x) => x.isMain === true);
  const id = profileId ?? (p ? String(p.id ?? "").toLowerCase() || null : null);
  const name = list.length > 1 && p && typeof p.name === "string" && p.name.trim() ? p.name.trim().slice(0, 50) : null;
  return { id, name };
}

// ---------- antwoorden van de pushdiensten ----------
// Uitkomst: sent | invalid (token weg) | retry (tijdelijk, nog eens) | failed (blijvend voor dit bericht).
export type Outcome = { state: "sent" | "invalid" | "retry" | "failed"; error?: string; resetAuth?: boolean };
export function apnsOutcome(status: number, reason: string): Outcome {
  if (status === 200) return { state: "sent" };
  if (status === 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"].includes(reason)) {
    return { state: "invalid", error: `apns_${reason || status}` };
  }
  if (status === 403 && /ProviderToken/.test(reason)) return { state: "retry", error: `apns_${reason}`, resetAuth: true };
  if (status === 429 || status >= 500) return { state: "retry", error: `apns_${reason || status}` };
  return { state: "failed", error: `apns_${reason || status}` };
}
export function fcmOutcome(status: number, body: unknown): Outcome {
  if (status === 200) return { state: "sent" };
  const err = (body as { error?: { status?: string; message?: string; details?: { errorCode?: string }[] } })?.error;
  const code = err?.details?.find((d) => d?.errorCode)?.errorCode ?? err?.status ?? String(status);
  if (code === "UNREGISTERED" || status === 404) return { state: "invalid", error: `fcm_${code}` };
  if (code === "INVALID_ARGUMENT" && /registration token|not a valid FCM/i.test(err?.message ?? "")) return { state: "invalid", error: "fcm_INVALID_TOKEN" };
  if (code === "SENDER_ID_MISMATCH") return { state: "invalid", error: `fcm_${code}` };
  if (status === 401) return { state: "retry", error: "fcm_UNAUTHENTICATED", resetAuth: true };
  if (status === 429 || status >= 500 || code === "UNAVAILABLE" || code === "INTERNAL" || code === "QUOTA_EXCEEDED") return { state: "retry", error: `fcm_${code}` };
  return { state: "failed", error: `fcm_${code}` };
}
export function webpushOutcome(status: number): Outcome {
  if (status >= 200 && status < 300) return { state: "sent" };
  if (status === 404 || status === 410) return { state: "invalid", error: `webpush_${status}` };
  if (status === 429 || status >= 500) return { state: "retry", error: `webpush_${status}` };
  return { state: "failed", error: `webpush_${status}` };
}
export const MAX_ATTEMPTS = 3;
