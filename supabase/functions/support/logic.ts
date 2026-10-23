// Supporttickets: pure hulpfuncties (geen database, geen netwerk), getest in support_test.ts.

export type Lang = "nl" | "en";
export const STATUSES = ["new", "open", "pending", "resolved", "closed"] as const;
export type Status = typeof STATUSES[number];
export const PRIORITIES = ["low", "normal", "high", "urgent"] as const;
export const CATEGORIES = ["account", "afspelen", "apps", "website", "overig"] as const;
export const PLATFORMS = ["ios", "tvos", "macos", "android", "androidtv", "tizen", "web"] as const;

// Labels voor de klant (site en e-mail). "pending" = wij wachten op de klant.
export const STATUS_LABEL: Record<Lang, Record<Status, string>> = {
  nl: { new: "Nieuw", open: "In behandeling", pending: "Wacht op jouw reactie", resolved: "Opgelost", closed: "Gesloten" },
  en: { new: "New", open: "In progress", pending: "Awaiting your reply", resolved: "Resolved", closed: "Closed" },
};
// Labels voor het beheer
export const STATUS_ADMIN: Record<Status, string> = {
  new: "Nieuw", open: "In behandeling", pending: "Wacht op klant", resolved: "Opgelost", closed: "Gesloten",
};
export const STATUS_COLOR: Record<Status, string> = {
  new: "#E50914", open: "#2f7cf6", pending: "#f5a524", resolved: "#2fa84f", closed: "#6b6b6b",
};
export const CATEGORY_LABEL: Record<Lang, Record<string, string>> = {
  nl: { account: "Account en inloggen", afspelen: "Afspelen en streams", apps: "Apps en installeren", website: "Website en webspeler", overig: "Overig" },
  en: { account: "Account and sign-in", afspelen: "Playback and streams", apps: "Apps and installing", website: "Website and web player", overig: "Other" },
};
export const PLATFORM_LABEL: Record<string, string> = {
  ios: "iPhone / iPad", tvos: "Apple TV", macos: "Mac", android: "Android",
  androidtv: "Android TV / Google TV / Fire TV", tizen: "Samsung TV", web: "Browser",
};

export const LIMITS = { name: 80, email: 254, subject: 120, message: 5000, appVersion: 40, minSubject: 3, minMessage: 10, deviceId: 128 };

// ---- apparaten van het account (tabel account_devices, gevuld door device-auth/register_device) ----
// De apps sturen als platform: "iPhone", "iPad", "Apple TV", "Mac" (Apple), "Android", "Android tablet", "Android TV",
// "Google TV", "Fire TV" (Android), "tizen" (Samsung TV) en "browser" (webspeler op bingr.online).
const DEVICE_KIND: Record<string, typeof PLATFORMS[number]> = {
  iphone: "ios", ipad: "ios", ios: "ios", ipados: "ios", "apple tv": "tvos", tvos: "tvos", mac: "macos", macos: "macos",
  android: "android", "android tablet": "android", "android tv": "androidtv", "google tv": "androidtv", "fire tv": "androidtv",
  androidtv: "androidtv", tizen: "tizen", "samsung tv": "tizen", browser: "web", web: "web",
};
/** Platform van een apparaat (zoals de app het registreert) als platform van een ticket; onbekend: null. */
export const deviceKind = (platform: unknown) => DEVICE_KIND[String(platform ?? "").trim().toLowerCase()] ?? null;
/** Leesbare naam van het platform van een apparaat ("tizen" -> "Samsung TV", "browser" -> "Browser"). */
export function deviceLabel(platform: unknown): string {
  const p = String(platform ?? "").trim();
  const l = p.toLowerCase();
  return l === "tizen" ? "Samsung TV" : l === "browser" ? "Browser" : p;
}
/** "1.0.0 (74)" -> [1, 0, 0, 74]; alle getallen op volgorde. */
const versionParts = (v: string) => (v.match(/\d+/g) ?? []).map(Number);
/** Nieuwste versie eerst (op getallen; gelijk: op tekst). */
export function compareVersionsDesc(a: string, b: string): number {
  const x = versionParts(a), y = versionParts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (y[i] ?? -1) - (x[i] ?? -1);
    if (d) return d;
  }
  return a.localeCompare(b);
}

export type DeviceRow = { device_id: string; name: string | null; platform: string | null; app_version: string | null; os_version: string | null; last_seen_at: string | null };
export type MyDevice = { id: string; name: string; platform: string; kind: string | null; label: string; app_version: string | null; os_version: string | null; last_seen_at: string | null };
/** Apparaten voor het formulier: laatst gebruikt eerst, plus de verschillende app-versies (nieuwste eerst). */
export function myDevices(rows: DeviceRow[]): { devices: MyDevice[]; versions: string[] } {
  const devices = rows
    .filter((r) => r && typeof r.device_id === "string" && r.device_id)
    .map((r) => {
      const label = deviceLabel(r.platform);
      return {
        id: r.device_id, name: cleanText(r.name, LIMITS.name) || label || "?", platform: String(r.platform ?? ""), kind: deviceKind(r.platform),
        label, app_version: cleanText(r.app_version, LIMITS.appVersion) || null, os_version: cleanText(r.os_version, 40) || null, last_seen_at: r.last_seen_at ?? null,
      };
    })
    .sort((a, b) => (b.last_seen_at ?? "").localeCompare(a.last_seen_at ?? ""));
  const versions = [...new Set(devices.map((d) => d.app_version).filter((v): v is string => !!v))].sort(compareVersionsDesc);
  return { devices, versions };
}

// ---- bekende builds (bingr.online/assets/changelog.json): terugval voor de keuzelijst App-versie ----
// Per ticketplatform de nieuwste build waarin dat platform veranderde ("1.0.0 (81)"); ipados telt als ios, server telt niet.
// Resultaat: één regel per versie (nieuwste eerst) met de platforms waarvoor dat de nieuwste build is.
const CHANGELOG_KIND: Record<string, typeof PLATFORMS[number]> = {
  ios: "ios", ipados: "ios", tvos: "tvos", macos: "macos", android: "android", androidtv: "androidtv", tizen: "tizen", web: "web",
};
export type KnownVersion = { version: string; build: number; platforms: string[] };
export function knownVersions(changelog: unknown): KnownVersion[] {
  const builds = Array.isArray(changelog) ? changelog : [];
  const latest = new Map<string, { build: number; version: string }>();
  for (const b of builds) {
    const n = Number(b?.build);
    if (!Number.isInteger(n) || n <= 0 || !Array.isArray(b?.items)) continue;
    const ver = cleanText(b.version, 20) || "1.0.0";
    for (const it of b.items) {
      for (const p of Array.isArray(it?.platforms) ? it.platforms : []) {
        const k = CHANGELOG_KIND[String(p)];
        if (k && (!latest.has(k) || latest.get(k)!.build < n)) latest.set(k, { build: n, version: ver });
      }
    }
  }
  const byVersion = new Map<string, KnownVersion>();
  for (const k of PLATFORMS) {
    const l = latest.get(k);
    if (!l) continue;
    const v = `${l.version} (${l.build})`;
    if (!byVersion.has(v)) byVersion.set(v, { version: v, build: l.build, platforms: [] });
    byVersion.get(v)!.platforms.push(k);
  }
  return [...byVersion.values()].sort((a, b) => compareVersionsDesc(a.version, b.version));
}

export const isStatus = (v: unknown): v is Status => typeof v === "string" && (STATUSES as readonly string[]).includes(v);
export const ticketLabel = (n: number | string) => `#${n}`;
export const langOf = (v: unknown): Lang => (String(v ?? "").toLowerCase().startsWith("en") ? "en" : "nl");

// tekst opschonen: geen stuurtekens (wel regeleinden en tabs), CRLF -> LF, max. 2 lege regels achter elkaar
export function cleanText(v: unknown, max: number, multiline = false): string {
  // onzichtbare en richting-tekens (spoofing) weg; overige stuurtekens: weg (meerregelig) of een spatie
  let s = String(v ?? "").replace(/\r\n?/g, "\n").replace(/[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, "");
  s = multiline ? s.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "") : s.replace(/[\u0000-\u001f\u007f]+/g, " ");
  s = s.trim();
  if (multiline) s = s.replace(/[ \t]+\n/g, "\n").replace(/\n{4,}/g, "\n\n\n");
  else s = s.replace(/\s{2,}/g, " ");
  return s.slice(0, max);
}

export const EMAIL_RE = /^[^\s@<>()",;:\\[\]]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
export const validEmail = (e: string) => e.length <= LIMITS.email && EMAIL_RE.test(e) && !/\.\./.test(e);
const urlCount = (s: string) => (s.match(/https?:\/\//gi) ?? []).length;

export type CreateInput = {
  name: string; email: string; category: string; platform: string | null; app_version: string | null;
  subject: string; message: string; lang: Lang;
  /** gekozen apparaat van het account; de functie controleert of het van de ingelogde gebruiker is (anders genegeerd) */
  device_id: string | null;
};
export type Invalid = { ok: false; error: string; field?: string };

/** Controleert een nieuw ticket. `website` is het verborgen lokveld (bots vullen het in), `elapsed_ms` de tijd
 *  sinds het formulier openging (sneller dan 2,5 s = bot). */
export function validateCreate(b: Record<string, unknown>): { ok: true; value: CreateInput } | Invalid {
  if (String(b.website ?? "").trim() !== "") return { ok: false, error: "spam" };
  const elapsed = Number(b.elapsed_ms);
  if (b.elapsed_ms != null && Number.isFinite(elapsed) && elapsed >= 0 && elapsed < 2500) return { ok: false, error: "spam" };
  const name = cleanText(b.name, LIMITS.name);
  const email = cleanText(b.email, LIMITS.email + 1).toLowerCase();
  const subject = cleanText(b.subject, LIMITS.subject + 1);
  const message = cleanText(b.message, LIMITS.message + 1, true);
  const category = String(b.category ?? "");
  const platform = b.platform == null || b.platform === "" ? null : String(b.platform);
  const app_version = cleanText(b.app_version, LIMITS.appVersion) || null;
  const dev = typeof b.device_id === "string" ? b.device_id.trim() : "";
  const device_id = dev && dev.length <= LIMITS.deviceId && /^[\x21-\x7e]+$/.test(dev) ? dev : null;
  if (!name) return { ok: false, error: "name_missing", field: "name" };
  if (!validEmail(email)) return { ok: false, error: "bad_email", field: "email" };
  if (!(CATEGORIES as readonly string[]).includes(category)) return { ok: false, error: "bad_category", field: "category" };
  if (platform !== null && !(PLATFORMS as readonly string[]).includes(platform)) return { ok: false, error: "bad_platform", field: "platform" };
  if (subject.length < LIMITS.minSubject) return { ok: false, error: "subject_missing", field: "subject" };
  if (subject.length > LIMITS.subject) return { ok: false, error: "subject_too_long", field: "subject" };
  if (message.length < LIMITS.minMessage) return { ok: false, error: "message_too_short", field: "message" };
  if (message.length > LIMITS.message) return { ok: false, error: "message_too_long", field: "message" };
  if (urlCount(message) > 6 || urlCount(subject) > 1) return { ok: false, error: "too_many_links", field: "message" };
  return { ok: true, value: { name, email, category, platform, app_version, subject, message, lang: langOf(b.lang), device_id } };
}

export function validateMessage(v: unknown): { ok: true; value: string } | Invalid {
  const m = cleanText(v, LIMITS.message + 1, true);
  if (m.length < 1) return { ok: false, error: "message_missing", field: "message" };
  if (m.length > LIMITS.message) return { ok: false, error: "message_too_long", field: "message" };
  if (urlCount(m) > 10) return { ok: false, error: "too_many_links", field: "message" };
  return { ok: true, value: m };
}

/** Ticketnummer uit "#1001", "1001" of een getal; anders null. */
export function parseNumber(v: unknown): number | null {
  const s = String(v ?? "").trim().replace(/^#/, "");
  if (!/^\d{1,12}$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 ? n : null;
}

/** Zoektekst voor het beheer: veilig voor een PostgREST or()-filter (geen komma's, haakjes, sterretjes of procenten). */
export function safeSearch(v: unknown): string {
  return String(v ?? "").replace(/[,()*%\\:"'`]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

/** Statusovergang na een bericht. Klant reageert: wachtend of opgelost wordt weer "open" (nieuw blijft nieuw).
 *  Support antwoordt zonder gekozen status: "pending" (wacht op klant). */
export function statusAfter(current: Status, author: "customer" | "support", chosen?: Status | null): Status {
  if (author === "customer") return current === "new" ? "new" : "open";
  return chosen ?? "pending";
}

export function ticketUrl(site: string, number: number, token: string) {
  return `${site.replace(/\/+$/, "")}/ticket/?n=${number}&t=${encodeURIComponent(token)}`;
}
export function beheerUrl(beheer: string, number: number) {
  return `${beheer.replace(/\/+$/, "")}/#support/${number}`;
}

/** Tijdsveilig vergelijken van twee strings. */
export function sameText(a: string, b: string) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export function randomToken(bytes = 24) {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export const validToken = (t: unknown): t is string => typeof t === "string" && /^[A-Za-z0-9_-]{20,64}$/.test(t);

/** "Naam <adres>" uit een From-waarde; alleen het adres als er geen naam is. */
export function addressOf(from: string): string {
  const m = /<([^>]+)>/.exec(from);
  return (m ? m[1] : from).trim();
}

/** Eigenaar van een ticket (security H1): alleen het account dat het ticket ingelogd aanmaakte of het met de geheime link
 *  expliciet aan zich koppelde (user_id). Nooit op e-mailadres: met autoconfirm (bevestigen per e-mail uit) bewijst
 *  email_confirmed_at niets, en ook daarna kan iemand een account met andermans adres hebben. */
export const ownsTicket = (userId: string | null | undefined, ticketUserId: string | null | undefined) =>
  typeof userId === "string" && userId !== "" && userId === ticketUserId;

/** Is het e-mailadres van dit account aantoonbaar bevestigd (via de link in de bevestigingsmail)? Alleen als bevestigen per
 *  e-mail verplicht is (app_settings.require_email_confirm) én de bevestiging echt later kwam dan het aanmaken: met
 *  autoconfirm zet Supabase email_confirmed_at op hetzelfde moment als created_at. Gebruikt voor de volledige tekst in de
 *  bevestigingsmail en de voornaam in de aanhef; nooit voor toegang tot tickets. */
export function emailProven(u: { email_confirmed_at?: string | null; created_at?: string | null } | null | undefined, requireConfirm: boolean): boolean {
  if (!requireConfirm || !u?.email_confirmed_at || !u.created_at) return false;
  const c = Date.parse(u.created_at), e = Date.parse(u.email_confirmed_at);
  return Number.isFinite(c) && Number.isFinite(e) && e - c >= 5000;
}
