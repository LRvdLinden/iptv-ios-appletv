// Build 146: diagnose-bijlage bij een supportticket uit de app (docs/ACCOUNT.md, "Build 146" → "Diagnose-bijlage").
// Vast schema (versie 1). De server houdt alleen bekende velden over, met vaste typen en lengtes; alles wat op een
// persoonsgegeven, adres of naam lijkt (URL, e-mailadres, IP-adres, pad met een gebruikersmap) gaat eruit. Pure logica,
// getest in diagnostics_test.ts.

export const DIAG_SCHEMA = 1;
export const DIAG_MAX_IN = 32 * 1024;   // ruwe JSON van de app: groter = 413 diagnostics_too_large
export const DIAG_MAX_OUT = 12 * 1024;  // na opschonen: groter wordt ingekort (stack, mijlpalen)

export const DIAG_KINDS = ["start", "app"] as const;
export const DIAG_PLATFORMS = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "tizen", "web", "windows"] as const;
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
/** Korte tekst: stuurtekens weg, getrimd, max. n tekens; leeg of persoonlijk = undefined. */
function str(v: unknown, n: number): string | undefined {
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  const s = String(v).replace(/[\u0000-\u001f\u007f​-‏‪-‮⁦-⁩]+/g, " ").replace(/\s{2,}/g, " ").trim().slice(0, n);
  if (!s || looksPersonal(s)) return undefined;
  return s;
}
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
    .map((x: Obj) => compact({ name: x.name, ms: num(x.ms, 0, 600_000, true), ok: bool(x.ok) }))
    .filter((x: Obj | undefined) => x && x.ms !== undefined)
    .slice(0, 40);
  const stack = c && Array.isArray(c.stack)
    ? c.stack.slice(0, 80).map((f: unknown) => str(f, 200)).filter((f: string | undefined): f is string => !!f).slice(0, 50)
    : [];

  const value = compact({
    schema: DIAG_SCHEMA,
    kind,
    createdAt: iso(input.createdAt),
    app: compact({ platform, version: str(a.version, 20), build: num(a.build, 1, 9_999_999, true), engine: str(a.engine, 30) }),
    device: compact({
      type: oneOf(d.type, DEVICE_TYPES), model: str(d.model, 80), manufacturer: str(d.manufacturer, 40), os: str(d.os, 20),
      osVersion: str(d.osVersion, 30), language: typeof d.language === "string" && /^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}$/.test(d.language) ? d.language.slice(0, 20) : undefined,
      browser: str(d.browser, 40), screen: str(d.screen, 20),
    }),
    milestones,
    memory: compact({ usedMB: num(m.usedMB, 0, 1e6), totalMB: num(m.totalMB, 0, 1e6), appMB: num(m.appMB, 0, 1e6), lowMemory: bool(m.lowMemory) }),
    crash: c ? compact({ at: iso(c.at), type: str(c.type, 80), reason: str(c.reason, 300), stack, build: num(c.build, 1, 9_999_999, true) }) : undefined,
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
  // te groot na opschonen: eerst de stack, dan de mijlpalen inkorten
  while (JSON.stringify(value).length > DIAG_MAX_OUT) {
    if (value.crash?.stack?.length > 5) value.crash.stack = value.crash.stack.slice(0, Math.floor(value.crash.stack.length / 2));
    else if (value.milestones?.length > 5) value.milestones = value.milestones.slice(0, Math.floor(value.milestones.length / 2));
    else { delete value.crash; delete value.milestones; break; }
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
