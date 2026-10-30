// Versies per platform voor de downloadknoppen op bingr.online (app_settings.release_channels; in te stellen in het
// beheer, functie admin, acties releases_get / releases_set). Openbaar via de functie status: GET ?action=releases.
// Vorm (alleen deze velden gaan naar buiten; al het andere in de rij wordt genegeerd):
//   {apple:   {live: {version, build, date?} | null, beta: {version, build, date?, label: "TestFlight"|"Beta"} | null},
//    android: {live: …, beta: …},   (android = ook Android TV, Google TV en Fire TV)
//    updatedAt}
// Een kanaal zonder geldige versie én build is null (dan toont de site er geen badge voor).

export const RELEASE_PLATFORMS = ["apple", "android"] as const;
export type ReleasePlatform = typeof RELEASE_PLATFORMS[number];
export const BETA_LABELS = ["TestFlight", "Beta"] as const;
export interface Channel { version: string; build: number; date?: string }
export interface BetaChannel extends Channel { label: typeof BETA_LABELS[number] }
export interface PlatformReleases { live: Channel | null; beta: BetaChannel | null }
export type Releases = Record<ReleasePlatform, PlatformReleases> & { updatedAt: string | null };

const VERSION_RE = /^\d{1,3}(\.\d{1,3}){1,3}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function cleanVersion(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return VERSION_RE.test(s) ? s : null;
}
export function cleanBuild(v: unknown): number | null {
  const n = typeof v === "string" && /^\d{1,7}$/.test(v.trim()) ? Number(v.trim()) : v;
  return typeof n === "number" && Number.isInteger(n) && n >= 1 && n <= 9_999_999 ? n : null;
}
export function cleanDate(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim().slice(0, 10) : "";
  if (!DATE_RE.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return !isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s ? s : null;
}

function channel(v: unknown): Channel | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const version = cleanVersion(o.version), build = cleanBuild(o.build);
  if (!version || !build) return null;
  const date = cleanDate(o.date);
  return date ? { version, build, date } : { version, build };
}

/** Openbare weergave van app_settings.release_channels (onbekende of ongeldige velden vallen weg). */
export function releasesView(v: unknown): Releases {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const out: Partial<Releases> = {};
  for (const p of RELEASE_PLATFORMS) {
    const po = o[p] && typeof o[p] === "object" && !Array.isArray(o[p]) ? o[p] as Record<string, unknown> : {};
    const live = channel(po.live);
    const b = channel(po.beta);
    const lbl = (po.beta as Record<string, unknown> | undefined)?.label;
    const label = (BETA_LABELS as readonly unknown[]).includes(lbl) ? lbl as BetaChannel["label"] : p === "apple" ? "TestFlight" : "Beta";
    out[p] = { live, beta: b ? { ...b, label } : null };
  }
  const u = typeof o.updatedAt === "string" ? new Date(o.updatedAt) : null;
  out.updatedAt = u && !isNaN(u.getTime()) ? u.toISOString() : null;
  return out as Releases;
}
