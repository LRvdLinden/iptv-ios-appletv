// Build 171: eigen crashrapporten, zonder derde partij (docs/ACCOUNT.md, "Build 171" → "Crashrapporten"). Pure logica, zonder
// database of netwerk, getest in crash_test.ts. De apps schonen message en stack zelf al op; de server doet het hier nog een
// keer (verdediging in de diepte): alles wat op een URL lijkt wordt `<url>` (IPTV-URL's bevatten gebruikersnamen en
// wachtwoorden), en IP-adressen, e-mailadressen en lange tokens gaan er ook uit. Nooit inhoud van een rapport in een log.

export const CRASH_PLATFORMS = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "web", "windows"] as const;
export const CRASH_KINDS = ["crash", "anr", "error"] as const;
export const MESSAGE_MAX = 500;          // tekens
export const STACK_MAX = 16 * 1024;      // bytes (UTF-8)
export const SIGNATURE_MAX = 200;        // tekens
export const BODY_MAX = 64 * 1024;       // ruwe aanvraag
export const PER_DEVICE_PER_HOUR = 20;   // rapporten per apparaat per uur
export const PER_ACCOUNT_PER_HOUR = 60;  // rapporten per account per uur (meerdere apparaten)
export const PER_IP_PER_HOUR = 30;       // zonder inloggen: rapporten per IP per uur
export const MAX_AGE_DAYS = 7;           // ouder (veld at) = niet meer aannemen (de apps bewaren max. 7 dagen)
export const COUNT_MAX = 1000;           // count = zo vaak gebeurd sinds het vorige rapport (ontdubbeld in de app)

export type CrashPlatform = typeof CRASH_PLATFORMS[number];
export type CrashKind = typeof CRASH_KINDS[number];
export type CleanCrash = {
  platform: CrashPlatform; app_version: string | null; build: number | null; os_version: string | null; device_model: string | null;
  kind: CrashKind; signature: string; message: string | null; stack: string | null; at: string; count: number;
};
export type CrashResult = { ok: true; report: CleanCrash } | { ok: false; error: "bad_report"; field: string };

// deno-lint-ignore no-control-regex
const CTRL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f​-‏‪-‮⁦-⁩]+/g;

/**
 * Tekst opschonen voor een crashrapport. Volgorde is belangrijk: eerst URL's (inclusief gebruikersnaam:wachtwoord@host), dan
 * e-mailadressen, IP-adressen (v4 en v6, met poort), sleutel=waarde-paren met geheimen en lange tokens (JWT, hex, base64).
 * Swift- en Kotlin-symbolen (`$s5Bingr…`, `nl.lrvdlinden.bingr.Main`) en bestandsnamen met regelnummers blijven staan.
 */
export function scrubCrashText(v: unknown): string {
  if (typeof v !== "string" && typeof v !== "number") return "";
  // per regel, en elke regel max. LINE_MAX tekens: zo blijft de rekentijd van de reguliere expressies begrensd
  return String(v).split(/\r?\n/).map((l) => scrubLine(l.length > LINE_MAX ? l.slice(0, LINE_MAX) + "…" : l)).join("\n");
}
export const LINE_MAX = 1000;
function scrubLine(line: string): string {
  let s = line.replace(CTRL, " ");
  s = s
    // URL's met schema (http, https, rtmp, rtsp, udp, file, …) en zonder schema maar met inloggegevens of www.
    .replace(/[a-z][a-z0-9+.-]{1,15}:\/\/[^\s"'<>`)\]}]*/gi, "<url>")
    .replace(/\bwww\.[^\s"'<>`)\]}]+/gi, "<url>")
    .replace(/[^\s/@"'<>:]+:[^\s/@"'<>]+@[a-z0-9.-]+\.[a-z]{2,}[^\s"'<>]*/gi, "<url>")
    // Xtream-paden zonder host: /live/<user>/<pass>/123.ts, /movie/…, /series/…, get.php?username=…, player_api.php?…
    .replace(/\/(?:live|movie|series|timeshift)\/[^\s/"'<>]+\/[^\s/"'<>]+\/[^\s"'<>]*/gi, "<url>")
    .replace(/\b(?:get|player_api|xmltv|panel_api|portal|load|server\/load)\.php\?[^\s"'<>]*/gi, "<url>")
    // e-mailadressen
    .replace(/[^\s@"'<>()[\]{},;:]+@[^\s@"'<>()[\]{},;:]+\.[a-z]{2,}/gi, "<email>")
    // IPv4 (met poort) en IPv6
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b/g, "<ip>")
    .replace(/(?<![\w:.])[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}(?![\w:])/gi, (m) => (m.length >= 6 && /\d/.test(m) && /[0-9a-f]{2}/i.test(m) ? "<ip>" : m))
    // query-strings en sleutel=waarde met geheimen
    .replace(/((?:username|user|password|passwd|pass|pwd|token|access_token|refresh_token|apikey|api_key|key|secret|mac|auth|sig|signature|session)\s*[=:]\s*)[^\s&"',;)]+/gi, "$1<redacted>")
    .replace(/\?[a-z0-9_.-]+=[^\s"'<>]*/gi, "<query>")
    // lange tokens: JWT, hex (>= 32), base64/base64url (>= 40 met cijfers), behalve Swift-mangled symbolen ($s / _$s)
    .replace(/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*/g, "<token>")
    .replace(/(?<![\w$])[0-9a-f]{32,}(?![\w])/gi, "<token>")
    .replace(/(?<![\w$])(?:sb_(?:publishable|secret)_)?[A-Za-z0-9+/_-]{40,}={0,2}(?![\w])/g, (m) => {
      const digits = (m.match(/\d/g) ?? []).length;
      return digits >= 6 && /[A-Z]/.test(m) && /[a-z]/.test(m) ? "<token>" : m;
    });
  return s;
}

/** Inkorten op een aantal UTF-8-bytes zonder een teken doormidden te knippen. */
export function clipBytes(s: string, max: number): string {
  const enc = new TextEncoder();
  if (enc.encode(s).length <= max) return s;
  let lo = 0, hi = s.length;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if (enc.encode(s.slice(0, mid)).length <= max) lo = mid; else hi = mid - 1;
  }
  let out = s.slice(0, lo);
  if (/[\ud800-\udbff]$/.test(out)) out = out.slice(0, -1);
  return out;
}

const short = (v: unknown, n: number): string | null => {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const t = scrubCrashText(String(v)).replace(/\s+/g, " ").trim().slice(0, n);
  return t || null;
};

/** Rapport controleren en opschonen. nowMs voor de leeftijd van `at` (max. 7 dagen oud, max. 10 minuten in de toekomst). */
export function cleanCrash(input: unknown, nowMs = Date.now()): CrashResult {
  const bad = (field: string): CrashResult => ({ ok: false, error: "bad_report", field });
  if (!input || typeof input !== "object" || Array.isArray(input)) return bad("body");
  const b = input as Record<string, unknown>;
  const platform = String(b.platform ?? "").toLowerCase() as CrashPlatform;
  if (!(CRASH_PLATFORMS as readonly string[]).includes(platform)) return bad("platform");
  const kind = String(b.kind ?? "") as CrashKind;
  if (!(CRASH_KINDS as readonly string[]).includes(kind)) return bad("kind");
  const signature = short(b.signature, SIGNATURE_MAX);
  if (!signature) return bad("signature");
  let build: number | null = null;
  if (b.build != null && b.build !== "") {
    const n = Number(b.build);
    if (!Number.isInteger(n) || n < 1 || n > 1_000_000) return bad("build");
    build = n;
  }
  let at = nowMs;
  if (b.at != null && b.at !== "") {
    const t = typeof b.at === "number" ? (b.at > 1e12 ? b.at : b.at * 1000) : Date.parse(String(b.at));
    if (!Number.isFinite(t)) return bad("at");
    if (t < nowMs - MAX_AGE_DAYS * 864e5) return bad("at");
    at = Math.min(t, nowMs + 10 * 60_000);
  }
  let count = 1;
  if (b.count != null && b.count !== "") {
    const n = Number(b.count);
    if (!Number.isFinite(n) || n < 1) return bad("count");
    count = Math.min(Math.floor(n), COUNT_MAX);
  }
  const message = typeof b.message === "string" || typeof b.message === "number"
    ? (scrubCrashText(String(b.message).slice(0, MESSAGE_MAX * 2)).trim().slice(0, MESSAGE_MAX) || null) : null;
  const stackRaw = typeof b.stack === "string" ? b.stack : Array.isArray(b.stack) ? b.stack.map((x) => String(x)).join("\n") : "";
  // eerst op 2 × de grens knippen (tegen enorme invoer), dan opschonen, dan op de echte grens
  const stack = clipBytes(scrubCrashText(stackRaw.slice(0, STACK_MAX * 2)), STACK_MAX).trim() || null;
  return {
    ok: true,
    report: {
      platform, kind, signature, build, count, message, stack, at: new Date(at).toISOString(),
      app_version: short(b.app_version, 40), os_version: short(b.os_version, 40), device_model: short(b.device_model, 60),
    },
  };
}

/** Is de `apikey`-kopregel een van de sleutels van dit project (publishable key of de oude anon key)? */
export function validAppKey(header: string | null, publishableJson: string | undefined | null, anon: string | undefined | null): boolean {
  const h = (header ?? "").trim();
  if (h.length < 20) return false;
  const keys: string[] = [];
  if (publishableJson) {
    try {
      const o = JSON.parse(publishableJson);
      if (o && typeof o === "object") for (const v of Object.values(o)) if (typeof v === "string" && v) keys.push(v);
    } catch { /* geen JSON */ }
  }
  if (anon) keys.push(anon);
  return keys.some((k) => k.length === h.length && timingSafe(k, h));
}
function timingSafe(a: string, b: string): boolean {
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
