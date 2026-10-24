// Build 146: diagnose-bijlage bij een supportticket uit de app (docs/ACCOUNT.md, "Build 146" → "Diagnose-bijlage").
// Build 147: schema 2 (docs/ACCOUNT.md, "Build 147"): `start` (samenvatting, app-tijd, wachten op de gebruiker, vorige
// start met hang/crash, voorgrond, taak en stack), `fetch` per server en soort, `network` en `storage` bovenaan.
// Schema 1 blijft geldig. De server houdt alleen bekende velden over, met vaste typen en lengtes; tekst die op een
// persoonsgegeven, adres of naam lijkt (URL, e-mailadres, IP-adres, pad met een gebruikersmap) gaat eruit, en in
// stack-regels en foutteksten wordt zo'n stuk vervangen ([url], [e-mail], [ip], [host], …/bestand). Pure logica,
// getest in diagnostics_test.ts.

export const DIAG_SCHEMA = 1;
export const DIAG_SCHEMAS = [1, 2] as const;
export const DIAG_MAX_IN = 48 * 1024;   // ruwe JSON van de app: groter = 413 diagnostics_too_large (build 146: 32 KB)
export const DIAG_MAX_OUT = 20 * 1024;  // na opschonen: groter wordt ingekort (stacks, mijlpalen, fetch) (build 146: 12 KB)

export const START_SUMMARY = ["good", "slow", "hung"] as const;
export const PREV_PROBLEMS = ["none", "hang", "crash", "not_finished"] as const;
export const FETCH_KINDS = ["live", "movie", "series"] as const;
export const FETCH_STATUS = ["ok", "empty", "failed", "hidden"] as const;

export const DIAG_KINDS = ["start", "app"] as const;
export const DIAG_PLATFORMS = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "tizen", "web", "windows", "webos"] as const;
export const DEVICE_TYPES = ["phone", "tablet", "tv", "desktop", "browser"] as const;
export const NET_TYPES = ["wifi", "ethernet", "cellular", "none", "other", "unknown"] as const;
export const CHECKS = ["ok", "slow", "fail", "skipped", "unknown"] as const;

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === "object" && !Array.isArray(v);

/** Lijkt deze tekst op iets persoonlijks of een adres? Dan niet bewaren. */
export function looksPersonal(s: string): boolean {
  return /[a-z][a-z0-9+.-]*:\/\//i.test(s) ||                       // URL (http://, rtmp://, file://)
    /\bwww\./i.test(s) ||
    /[^\s@]+@[^\s@]+\.[^\s@]+/.test(s) ||                          // e-mailadres
    /\b(?:\d{1,3}\.){3}\d{1,3}\b/.test(s) ||                       // IPv4
    /\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){4,7}\b/i.test(s) ||         // IPv6
    /(?:\/Users\/|\/home\/|\/var\/mobile\/|[A-Za-z]:\\Users\\|\/data\/user\/)/.test(s) || // gebruikersmappen
    /\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b/i.test(s) ||            // MAC-adres (Stalker-portals)
    /[?&](?:username|password|token|key|mac)=/i.test(s);
}
const CTRL = /[\u0000-\u001f\u007f​-‏‪-‮⁦-⁩]+/g;
/** Korte tekst: stuurtekens weg, getrimd, max. n tekens; leeg of persoonlijk = undefined. */
function str(v: unknown, n: number): string | undefined {
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  const s = String(v).replace(CTRL, " ").replace(/\s{2,}/g, " ").trim().slice(0, n);
  if (!s || looksPersonal(s)) return undefined;
  return s;
}

// servernamen: kleine letters met een gangbare topleveldomeinnaam aan het eind (geen Swift-/Kotlin-symbolen zoals
// "Bingr.PlayerView" of "nl.lrvdlinden.bingr.Main", die niet op zo'n domein eindigen)
const TLDS = "com|net|org|info|biz|io|tv|me|cc|co|xyz|online|site|live|stream|top|club|pro|app|dev|nl|be|de|uk|fr|eu|us|ru|es|it|pl|ch|at|se|no|dk|fi|pt|tr|ca|au|br|vip|link|cloud|host|space|fun|world|store|shop|tech|ws|to|ly|gg|ai|one|icu|lol|watch|media|network|server|cdn|tk|ml|ga|cf|gq|su|ua|ro|gr|hu|cz|sk|bg|rs|hr|al|ma|dz|tn|eg|sa|ae|ir|pk|in|id|my|sg|ph|vn|th|cn|hk|tw|jp|kr|mx|ar|cl|pe|ve|za|ng|ke|nz|lan|local|internal|example|test|invalid|localhost";
const HOST = new RegExp(`(?<![\\w.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+(?:${TLDS})(?![\\w-]|\\.[a-z0-9])(?::\\d{1,5})?`, "g");
/**
 * Stack-regel of fouttekst opschonen: URL's, e-mailadressen, IP-/MAC-adressen, servernamen, gebruikersmappen en
 * `username=`/`password=`/`token=` worden vervangen; een pad houdt alleen de bestandsnaam. Leeg = undefined.
 */
export function scrubText(v: unknown, n: number): string | undefined {
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  let s = String(v).replace(CTRL, " ");
  s = s.replace(/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>)\]]*/gi, "[url]")
    .replace(/\bwww\.[^\s"'<>)\]]+/gi, "[url]")
    .replace(/[^\s@"'<>()[\]]+@[^\s@"'<>()[\]]+\.[^\s@"'<>()[\]]+/g, "[e-mail]")
    .replace(/\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b/gi, "[mac]")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b/g, "[ip]")
    .replace(/(?<![\w:])[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){4,7}(?![\w:])/gi, "[ip]")
    .replace(/((?:username|user|password|pass|pwd|token|key|mac|auth)=)[^&\s"']*/gi, "$1[x]")
    // paden (Unix en Windows): alleen de laatste naam (bestand + regelnummer) blijft
    .replace(/(?:[A-Za-z]:)?(?:[\\/][^\s\\/:"'<>|()]+){2,}[\\/]?/g, (p) => {
      const last = p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "";
      return `…/${last}`;
    })
    .replace(HOST, "[host]");
  s = s.replace(/\s{2,}/g, " ").trim().slice(0, n);
  return s || undefined;
}
const scrubList = (v: unknown, take: number, n: number): string[] =>
  (Array.isArray(v) ? v : []).slice(0, take * 2).map((f) => scrubText(f, n)).filter((f): f is string => !!f).slice(0, take);
function oneOf<T extends string>(v: unknown, list: readonly T[]): T | undefined {
  return typeof v === "string" && (list as readonly string[]).includes(v) ? v as T : undefined;
}
function num(v: unknown, min: number, max: number, int = false): number | undefined {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  if (!Number.isFinite(n) || n < min || n > max) return undefined;
  return int ? Math.round(n) : Math.round(n * 10) / 10;
}
const bool = (v: unknown) => (typeof v === "boolean" ? v : undefined);
function iso(v: unknown): string | undefined {
  if (typeof v !== "string" || v.length > 40) return undefined;
  const t = Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : undefined;
}
const NAME = /^[a-z][a-z0-9_.-]{0,39}$/;
/** Lege objecten en undefined weglaten. */
function compact(o: Obj): Obj | undefined {
  const out: Obj = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined) continue;
    if (isObj(v) && !Object.keys(v).length) continue;
    if (Array.isArray(v) && !v.length) continue;
    out[k] = v;
  }
  return Object.keys(out).length ? out : undefined;
}

export type DiagResult = { ok: true; value: Obj; stripped: boolean } | { ok: false; error: "bad_diagnostics" | "diagnostics_too_large"; field?: string };

/**
 * Bijlage controleren en opschonen. Verplicht: kind, app.platform. Alles buiten het schema verdwijnt (stripped = true).
 * Antwoord van de server bij een ongeldige kern: 400 bad_diagnostics; te groot: 413 diagnostics_too_large.
 */
export function cleanDiagnostics(input: unknown): DiagResult {
  if (!isObj(input)) return { ok: false, error: "bad_diagnostics" };
  let raw: string;
  try { raw = JSON.stringify(input); } catch { return { ok: false, error: "bad_diagnostics" }; }
  if (raw.length > DIAG_MAX_IN) return { ok: false, error: "diagnostics_too_large" };
  const kind = oneOf(input.kind, DIAG_KINDS);
  if (!kind) return { ok: false, error: "bad_diagnostics", field: "kind" };
  const a = isObj(input.app) ? input.app : {};
  const platform = oneOf(a.platform, DIAG_PLATFORMS);
  if (!platform) return { ok: false, error: "bad_diagnostics", field: "app.platform" };
  const d = isObj(input.device) ? input.device : {};
  const m = isObj(input.memory) ? input.memory : {};
  const c = isObj(input.crash) ? input.crash : null;
  const s = isObj(input.state) ? input.state : {};
  const net = isObj(s.network) ? s.network : {};
  const sto = isObj(s.storage) ? s.storage : {};

  const milestones = (Array.isArray(input.milestones) ? input.milestones : []).slice(0, 60)
    .filter((x: unknown) => isObj(x) && typeof x.name === "string" && NAME.test(x.name))
    .map((x: Obj) => compact({ name: x.name, ms: num(x.ms, 0, 3_600_000, true), ok: bool(x.ok) }))
    .filter((x: Obj | undefined) => x && x.ms !== undefined)
    .slice(0, 40);
  const stack = c ? scrubList(c.stack, 50, 200) : [];
  // schema 2 (of nieuwer: dan alleen wat schema 2 kent); zonder of 1 = schema 1
  const schema = typeof input.schema === "number" && input.schema >= 2 ? 2 : DIAG_SCHEMA;
  const v2 = schema === 2;
  const st = v2 && isObj(input.start) ? input.start : null;
  const prev = st && isObj(st.previous) ? st.previous : null;
  const net2 = v2 && isObj(input.network) ? input.network : {};
  const sto2 = v2 && isObj(input.storage) ? input.storage : {};
  const fetch = v2 && Array.isArray(input.fetch)
    ? input.fetch.slice(0, 60).filter(isObj).map((x: Obj) => {
      const server = typeof x.server === "string" && /^s[1-9][0-9]?$/.test(x.server) ? x.server : undefined;
      const kind = oneOf(x.kind, FETCH_KINDS), status = oneOf(x.status, FETCH_STATUS);
      if (!server || !kind || !status) return undefined;
      return compact({ server, kind, status, count: num(x.count, 0, 10_000_000, true), error: scrubText(x.error, 60) });
    }).filter((x: Obj | undefined): x is Obj => !!x).slice(0, 30)
    : [];

  const value = compact({
    schema,
    kind,
    createdAt: iso(input.createdAt),
    app: compact({ platform, version: str(a.version, 20), build: num(a.build, 1, 9_999_999, true), engine: str(a.engine, 30) }),
    device: compact({
      type: oneOf(d.type, DEVICE_TYPES), model: str(d.model, 80), manufacturer: str(d.manufacturer, 40), os: str(d.os, 20),
      osVersion: str(d.osVersion, 30), language: typeof d.language === "string" && /^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}$/.test(d.language) ? d.language.slice(0, 20) : undefined,
      browser: str(d.browser, 40), screen: str(d.screen, 20),
    }),
    start: st ? compact({
      summary: oneOf(st.summary, START_SUMMARY), appMs: num(st.appMs, 0, 3_600_000, true), userWaitMs: num(st.userWaitMs, 0, 86_400_000, true),
      maxHangMs: num(st.maxHangMs, 0, 86_400_000, true),
      previous: prev ? compact({
        problem: oneOf(prev.problem, PREV_PROBLEMS), milestone: typeof prev.milestone === "string" && NAME.test(prev.milestone) ? prev.milestone : undefined,
        seconds: num(prev.seconds, 0, 86_400), foreground: bool(prev.foreground), task: scrubText(prev.task, 60),
        at: iso(prev.at), build: num(prev.build, 1, 9_999_999, true), stack: scrubList(prev.stack, 30, 200),
      }) : undefined,
    }) : undefined,
    milestones,
    fetch,
    network: v2 ? compact({
      type: oneOf(net2.type, NET_TYPES), online: bool(net2.online), backend: oneOf(net2.backend, CHECKS), backendMs: num(net2.backendMs, 0, 600_000, true),
      provider: oneOf(net2.provider, CHECKS), providerMs: num(net2.providerMs, 0, 600_000, true), vpn: bool(net2.vpn),
    }) : undefined,
    storage: v2 ? compact({
      totalMB: num(sto2.totalMB, 0, 1e7), cacheMB: num(sto2.cacheMB, 0, 1e7), catalogMB: num(sto2.catalogMB, 0, 1e7),
      downloadsMB: num(sto2.downloadsMB, 0, 1e7), freeMB: num(sto2.freeMB, 0, 1e8),
    }) : undefined,
    memory: compact({ usedMB: num(m.usedMB, 0, 1e6), totalMB: num(m.totalMB, 0, 1e6), appMB: num(m.appMB, 0, 1e6), lowMemory: bool(m.lowMemory) }),
    crash: c ? compact({ at: iso(c.at), type: scrubText(c.type, 80), reason: scrubText(c.reason, 300), stack, build: num(c.build, 1, 9_999_999, true) }) : undefined,
    state: compact({
      signedIn: bool(s.signedIn), profiles: num(s.profiles, 0, 1000, true), servers: num(s.servers, 0, 1000, true),
      serverKinds: (Array.isArray(s.serverKinds) ? s.serverKinds : []).slice(0, 10).map((k: unknown) => str(k, 20)).filter(Boolean),
      lastSync: iso(s.lastSync), lastSyncOk: bool(s.lastSyncOk), plan: oneOf(s.plan, ["free", "lifetime"] as const),
      pushEnabled: bool(s.pushEnabled), channels: num(s.channels, 0, 10_000_000, true), movies: num(s.movies, 0, 10_000_000, true),
      series: num(s.series, 0, 10_000_000, true), uptimeS: num(s.uptimeS, 0, 1e9, true),
      network: compact({
        online: bool(net.online), type: oneOf(net.type, NET_TYPES), backend: oneOf(net.backend, CHECKS), backendMs: num(net.backendMs, 0, 600_000, true),
        provider: oneOf(net.provider, CHECKS), providerMs: num(net.providerMs, 0, 600_000, true), vpn: bool(net.vpn),
      }),
      storage: compact({ usedMB: num(sto.usedMB, 0, 1e7), freeMB: num(sto.freeMB, 0, 1e8), cacheMB: num(sto.cacheMB, 0, 1e7), dbMB: num(sto.dbMB, 0, 1e7) }),
    }),
  })!;
  // te groot na opschonen: eerst de stacks, dan de mijlpalen en fetch inkorten
  const half = (a: unknown[]) => a.slice(0, Math.floor(a.length / 2));
  while (JSON.stringify(value).length > DIAG_MAX_OUT) {
    if (value.crash?.stack?.length > 5) value.crash.stack = half(value.crash.stack);
    else if (value.start?.previous?.stack?.length > 5) value.start.previous.stack = half(value.start.previous.stack);
    else if (value.milestones?.length > 5) value.milestones = half(value.milestones);
    else if (value.fetch?.length > 6) value.fetch = half(value.fetch);
    else { delete value.crash; delete value.milestones; if (value.start?.previous) delete value.start.previous.stack; break; }
  }
  return { ok: true, value, stripped: !covered(input, value) };
}
/** Staat elk blad van het origineel ongewijzigd in het resultaat? Zo niet, dan is er iets weggelaten of aangepast. */
function covered(src: unknown, out: unknown): boolean {
  if (Array.isArray(src)) return Array.isArray(out) && src.length === out.length && src.every((x, i) => covered(x, out[i]));
  if (isObj(src)) return isObj(out) && Object.entries(src).every(([k, v]) => covered(v, out[k]));
  return src === out;
}

/** Platform van een ticket (support_tickets.platform) bij het platform uit de bijlage. */
export function ticketPlatform(p: string | undefined): string | null {
  if (!p) return null;
  return p === "ipados" ? "ios" : p;
}
