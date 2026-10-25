// Security M1/L8: wat mag de web-proxy ophalen en hoe geeft hij het terug? Pure functies, getest in policy_test.ts.
//
// Doelen: alleen de eigen IPTV-servers van het account (account_sources: m3uURL, epgURL, serverURL, plus subdomeinen van
// hetzelfde domein), en daarop alleen wat de webspeler echt gebruikt:
//   - de M3U-URL en EPG-URL zelf (precies dat pad);
//   - Xtream/Stalker-API's: player_api.php, get.php, xmltv.php, panel_api.php, portal.php, (stalker_portal/)server/load.php,
//     (stalker_portal/)c/;
//   - streams en bijbehorende bestanden: /live/, /movie/, /series/, /timeshift/, /streaming/, /hls/ enz., de korte
//     Xtream-vorm /<gebruiker>/<wachtwoord>/<id>, en paden die eindigen op een media-, afspeellijst-, ondertitel-, EPG- of
//     afbeeldingsextensie.
// Een URL die de proxy zelf in een HLS-afspeellijst zette (handtekening `s`) mag elk pad en elke publieke host, maar het
// antwoord moet dan media zijn (mediaLike). Poorten: 80, 443 en vanaf 1024, behalve bekende interne diensten.
// Antwoorden nooit als HTML/script: zulke types worden text/plain, en altijd nosniff + CSP sandbox (en voor niet-media
// Content-Disposition: attachment), zodat niets op *.supabase.co als pagina kan draaien (phishing, L8).

// prefixes: "host|/pad" van een serverURL met een pad ervoor (Xtream-panels achter een map, bv. http://host:8080/pad): daaronder
// gelden dezelfde API- en streampaden (spoedfix 25-10-2026)
export type Allow = { hosts: Set<string>; exact: Set<string>; prefixes?: Set<string> };

// "tv.example.co.uk" -> "example.co.uk", "a.b.example.com" -> "example.com" (eenvoudige benadering, genoeg voor IPTV-hosts)
export function baseDomain(host: string): string {
  if (/^[\d.]+$/.test(host) || host.includes(":")) return host;
  const p = host.split(".");
  if (p.length <= 2) return host;
  const sld = p[p.length - 2];
  const two = p[p.length - 1].length === 2 && /^(co|com|net|org|gov|ac|edu|ne|or)$/.test(sld);
  return p.slice(two ? -3 : -2).join(".");
}

const exactKey = (u: URL) => `${u.protocol}//${u.host.toLowerCase()}${u.pathname}`;

/** Toegestane hosts en exacte URL's (M3U/EPG) uit de ontsleutelde bronnen van het account. */
export function allowFromSources(sources: unknown): Allow {
  const hosts = new Set<string>(), exact = new Set<string>(), prefixes = new Set<string>();
  for (const s of Array.isArray(sources) ? sources : []) {
    if (!s || typeof s !== "object" || (s as { deleted?: unknown }).deleted === true) continue;
    for (const f of ["m3uURL", "epgURL", "serverURL"]) {
      try {
        const v = String((s as Record<string, unknown>)[f] ?? "").trim();
        if (!v) continue;
        const u = new URL(/^[a-z]+:\/\//i.test(v) ? v : `https://${v}`);
        const h = u.hostname.toLowerCase();
        if (!h) continue;
        hosts.add(h); hosts.add("*." + baseDomain(h));
        if (f === "serverURL") {
          const pre = u.pathname.replace(/\/+$/, "").replace(/\/(player_api|get|panel_api|portal)\.php$/i, "");
          if (pre && pre !== "/" && !pre.includes("..")) prefixes.add(`${h}|${pre.toLowerCase()}`);
        }
        if (f !== "serverURL" && u.pathname && u.pathname !== "/") {
          exact.add(exactKey(u));
          // dezelfde lijst op http én https (veel panels kennen beide)
          const other = new URL(u.toString());
          other.protocol = u.protocol === "https:" ? "http:" : "https:";
          exact.add(exactKey(other));
        }
      } catch { /* geen geldige URL */ }
    }
  }
  return { hosts, exact, prefixes };
}

export function hostAllowed(host: string, allow: Allow) {
  const h = host.toLowerCase();
  return allow.hosts.has(h) || allow.hosts.has("*." + baseDomain(h));
}

// Xtream / Stalker / Ministra-API's
const API_PATH = /^\/(?:stalker_portal\/)?(?:player_api\.php|get\.php|xmltv\.php|panel_api\.php|portal\.php|server\/load\.php|c\/.*)$/i;
// streams, VOD, terugkijken, HLS, logo's en EPG op de server van het abonnement
const STREAM_PREFIX = /^\/(?:live|movie|movies|series|timeshift|streaming|hls|hlsr|play|stream|streams|vod|ch|channel|images|logo|logos|epg|xmltv|tv)\//i;
// korte Xtream-vorm /<gebruiker>/<wachtwoord>/<stream-id>[.ext], en M3U-streams als /<id> of /<map>/<id>
const XTREAM_SHORT = /^\/(?:[^/]+\/){0,3}\d+(?:\.[a-z0-9]{1,5})?$/i;
// bestandsextensies van media, afspeellijsten, ondertitels, EPG en afbeeldingen (ook .xml.gz)
const MEDIA_EXT = /\.(?:ts|m2ts|mts|m3u8?|mp4|m4v|m4s|m4a|mkv|avi|mov|webm|mpd|flv|mpg|mpeg|wmv|aac|mp3|ac3|eac3|ogg|opus|vtt|srt|ass|ssa|sub|key|xml|gz|jpe?g|png|webp|gif|svg|bmp|ico|avif)$/i;

export type PathCheck = { ok: true } | { ok: false; reason: "path_not_allowed" };
/** Mag dit pad op een host van het account? (trusted = door de proxy zelf ondertekend vanuit een afspeellijst) */
export function pathAllowed(u: URL, allow: Allow, trusted: boolean): PathCheck {
  if (trusted) return { ok: true };
  if (allow.exact.has(exactKey(u))) return { ok: true };
  const known = (p: string) => API_PATH.test(p) || STREAM_PREFIX.test(p) || XTREAM_SHORT.test(p) || MEDIA_EXT.test(p);
  if (known(u.pathname)) return { ok: true };
  const host = u.hostname.toLowerCase(), lp = u.pathname.toLowerCase();
  for (const pr of allow.prefixes ?? []) {
    const i = pr.indexOf("|"), h = pr.slice(0, i), pre = pr.slice(i + 1);
    if (h === host && lp.startsWith(pre + "/") && known(u.pathname.slice(pre.length))) return { ok: true };
  }
  return { ok: false, reason: "path_not_allowed" };
}

// poorten van bekende interne/beheerdiensten (ook boven 1024): nooit, ook al is de host publiek
const BAD_PORTS = new Set([
  1080, 1433, 1521, 2049, 2375, 2376, 2379, 2380, 3306, 3389, 4369, 5000, 5432, 5672, 5900, 5984, 6379, 6443, 7001, 8086,
  8200, 8500, 9000, 9042, 9092, 9100, 9200, 9300, 10250, 10255, 11211, 15672, 27017, 27018, 50070,
]);
export function portAllowed(u: URL): boolean {
  const port = u.port ? Number(u.port) : (u.protocol === "https:" ? 443 : 80);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return false;
  if (port === 80 || port === 443) return true;
  return port >= 1024 && !BAD_PORTS.has(port);
}

const MEDIA_TYPE = /^(?:video\/|audio\/|image\/|application\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl|octet-stream|mp4|dash\+xml|x-subrip|mp2t|vnd\.ms-sstr\+xml|pgp-keys)|binary\/octet-stream|text\/vtt)/i;
const PLAYLIST_TYPE = /^(?:application\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl)|audio\/(?:x-)?mpegurl|text\/plain)/i;
/** Antwoord van een door de proxy ondertekende URL (uit een afspeellijst): moet media of een afspeellijst zijn. */
export function mediaLike(ctype: string): boolean {
  const t = ctype.trim();
  return t === "" || MEDIA_TYPE.test(t) || PLAYLIST_TYPE.test(t);
}

// types die we ongewijzigd doorgeven (media, afspeellijsten, afbeeldingen, EPG/ondertitels, JSON van de API's)
const PASS_TYPE = /^(?:video\/|audio\/|image\/|application\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl|octet-stream|mp4|dash\+xml|x-subrip|mp2t|json|xml|gzip|x-gzip|x-xz|zip)|binary\/octet-stream|text\/(?:plain|vtt|xml|csv|x-mpegurl))/i;
/** Content-Type voor de browser: HTML, XHTML, JavaScript, CSS en onbekende types worden text/plain (de webspeler leest de
 *  tekst toch zelf, bv. player_api.php die als text/html binnenkomt). */
export function safeContentType(ctype: string | null | undefined): string {
  const t = String(ctype ?? "").trim();
  if (!t) return "application/octet-stream";
  if (/^[a-z0-9.+-]+\/[a-z0-9.+-]+/i.test(t) && PASS_TYPE.test(t) && !/(?:html|script|ecmascript)/i.test(t)) return t.slice(0, 200);
  return "text/plain; charset=utf-8";
}
const isMediaType = (t: string) => /^(?:video\/|audio\/|image\/|application\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl|mp4|dash\+xml|mp2t)|text\/vtt)/i.test(t);
/** Kopregels die op elk doorgegeven antwoord komen: nooit als pagina te openen (CSP sandbox), geen MIME-sniffen. */
export function safetyHeaders(ctype: string): Record<string, string> {
  return {
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "sandbox; default-src 'none'; frame-ancestors 'none'",
    "Cross-Origin-Resource-Policy": "cross-origin",
    "Referrer-Policy": "no-referrer",
    ...(isMediaType(ctype) ? {} : { "Content-Disposition": "attachment" }),
  };
}

// ---- gebruik per account (M1/L6): limieten per uur (aanvragen) en per dag (bytes), opgeslagen in de database ----
export type Quota = { requests_hour: number; bytes_day: number };
export type QuotaSettings = { enabled: boolean; free: Quota; lifetime: Quota };
export const QUOTA_DEFAULTS: QuotaSettings = {
  enabled: true,
  free: { requests_hour: 6000, bytes_day: 20 * 1024 ** 3 },
  lifetime: { requests_hour: 30000, bytes_day: 150 * 1024 ** 3 },
};
const num = (v: unknown, d: number, min: number, max: number) => {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) && n >= min && n <= max ? Math.floor(n) : d;
};
/** app_settings.proxy_limits ({enabled?, free?: {requests_hour?, bytes_day?}, lifetime?: …}) met grenzen; rest standaard. */
export function quotaSettings(v: unknown): QuotaSettings {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const q = (k: "free" | "lifetime") => {
    const x = o[k] && typeof o[k] === "object" ? o[k] as Record<string, unknown> : {};
    const d = QUOTA_DEFAULTS[k];
    return { requests_hour: num(x.requests_hour, d.requests_hour, 100, 1_000_000), bytes_day: num(x.bytes_day, d.bytes_day, 100 * 1024 ** 2, 10 * 1024 ** 4) };
  };
  return { enabled: o.enabled !== false, free: q("free"), lifetime: q("lifetime") };
}
export function overQuota(used: { requests_hour: number; bytes_day: number }, q: Quota): boolean {
  return used.requests_hour > q.requests_hour || used.bytes_day > q.bytes_day;
}

// ---- spoedfix 25-10-2026: foutsoorten en een logregel zonder host, IP, URL of inloggegevens ----
/** Fouten bij het ophalen bij de server van de gebruiker (502/504); de webspeler toont per soort een eigen melding. */
export const UPSTREAM_ERRORS = ["dns_failed", "connect_refused", "connect_reset", "connect_timeout", "connect_failed", "tls_failed", "tls_timeout",
  "no_response", "bad_response", "timeout", "upstream_failed"] as const;
export type UpstreamError = typeof UPSTREAM_ERRORS[number];
export function upstreamStatus(kind: string): number {
  return kind === "timeout" || kind === "connect_timeout" || kind === "tls_timeout" ? 504 : 502;
}
/** Soort pad (geen pad zelf): api, live, vod, series, playlist, epg, image, media of other. */
export function pathKind(u: URL): string {
  const p = u.pathname.toLowerCase();
  if (/\/(player_api|panel_api|get|portal)\.php$|\/server\/load\.php$/.test(p)) return "api";
  if (/\/xmltv\.php$|\.xml(\.gz)?$|^\/(epg|xmltv)\//.test(p)) return "epg";
  if (/^\/live\//.test(p)) return "live";
  if (/^\/movies?\//.test(p)) return "vod";
  if (/^\/series\//.test(p)) return "series";
  if (/\.m3u8?$/.test(p)) return "playlist";
  if (/\.(jpe?g|png|webp|gif|svg|bmp|ico|avif)$/.test(p)) return "image";
  if (MEDIA_EXT.test(p)) return "media";
  return "other";
}
/** Xtream-actie uit de query (alleen een bekende vorm, anders "-"); nooit username/password. */
export function actionName(u: URL): string {
  const a = u.searchParams.get("action") ?? "";
  if (!a) return pathKind(u) === "api" ? "login" : "-";
  return /^[a-z_]{1,40}$/i.test(a) ? a.toLowerCase() : "?";
}
/** Eén logregel voor een mislukte aanvraag: alleen soort, status, actie, protocol, duur, bytes en aantal doorverwijzingen. */
export function failLog(o: { error?: string; upstream?: number; target: URL; ms: number; redirects?: number; bytes?: number; form: "post" | "get" | "probe" }): string {
  const err = o.error && /^[a-z_]{1,40}$/.test(o.error) ? o.error : (o.error ? "?" : "-");
  return `web-proxy fout=${err} upstream=${Number.isFinite(o.upstream) ? o.upstream : "-"} vorm=${o.form} pad=${pathKind(o.target)} actie=${actionName(o.target)} ` +
    `https=${o.target.protocol === "https:" ? 1 : 0} ms=${Math.round(o.ms)} bytes=${Math.max(0, Math.round(o.bytes ?? 0))} doorverwijzingen=${o.redirects ?? 0}`;
}
