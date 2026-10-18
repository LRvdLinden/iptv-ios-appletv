// Bingr-abonnementen: Gratis en Lifetime (docs/ACCOUNT.md, "Abonnementen"). Pure logica zonder database, zodat
// device-auth (limieten, functies, upgrade-link) en de unittests (plans_test.ts) precies hetzelfde rekenen.
//   free     -> 1 stream (gelijktijdige kijker), 8 apparaten, 1 server, geen statistieken / nu aan het kijken / Trakt / meerdere servers / thema's
//   lifetime -> 3 streams, 15 apparaten, onbeperkt servers, alles aan
// De streamlimiet is Bingr's eigen telling (account_streams), los van de limiet van de IPTV-provider
// (Xtream max_connections); die controleren de apps apart bij het afspelen.
// Per account kan het beheer max_streams / max_devices verhogen (null = standaard van het abonnement).

export type Plan = "free" | "lifetime";
export type Limits = { streams: number; devices: number; servers: number | null };
export type Features = { stats: boolean; now_watching: boolean; trakt: boolean; multi_server: boolean; themes: boolean };
export type PlanRow = { plan?: unknown; max_streams?: unknown; max_devices?: unknown } | null | undefined;
export type UpgradeLink = { apple: boolean; android: boolean; androidtv: boolean; tizen: boolean; web: boolean };
export type Platform = "ios" | "ipados" | "tvos" | "macos" | "android" | "androidtv" | "tizen" | "web";
export type Entitlements = {
  plan: Plan;
  limits: Limits;
  features: Features;
  upgrade: { url: string; link: boolean; price: string; price_en: string };
};

export const PLAN_DEFAULTS: Record<Plan, Limits> = {
  free: { streams: 1, devices: 8, servers: 1 },
  lifetime: { streams: 3, devices: 15, servers: null },
};
export const UPGRADE_URL = "https://bingr.online/upgrade/";
export const PRICE_NL = "€ 4,99";
export const PRICE_EN = "€4.99";
// standaard: in de Apple-apps geen link naar de betaalpagina (alleen de vergelijking), elders wel
export const DEFAULT_UPGRADE_LINK: UpgradeLink = { apple: false, android: true, androidtv: true, tizen: true, web: true };
export const PLATFORMS: Platform[] = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "tizen", "web"];
// grenzen voor een eigen limiet uit het beheer
export const MAX_STREAMS_CAP = 50;
export const MAX_DEVICES_CAP = 200;

export const normalizePlan = (v: unknown): Plan => (v === "lifetime" ? "lifetime" : "free");

// geheel getal binnen [1, cap], anders null (= standaard van het abonnement)
export function override(v: unknown, cap: number): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(String(v).trim());
  if (!Number.isFinite(n) || !Number.isInteger(n) || n < 1 || n > cap) return null;
  return n;
}

export function limitsFor(row: PlanRow): Limits {
  const plan = normalizePlan(row?.plan);
  const d = PLAN_DEFAULTS[plan];
  return {
    streams: override(row?.max_streams, MAX_STREAMS_CAP) ?? d.streams,
    devices: override(row?.max_devices, MAX_DEVICES_CAP) ?? d.devices,
    servers: d.servers,
  };
}

export function featuresFor(plan: Plan): Features {
  const on = plan === "lifetime";
  return { stats: on, now_watching: on, trakt: on, multi_server: on, themes: on };
}

// platform uit de aanvraag (ios, ipados, tvos, macos, android, androidtv, tizen, web), hoofdletterongevoelig; anders null
export function normalizePlatform(v: unknown): Platform | null {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s) return null;
  if ((PLATFORMS as string[]).includes(s)) return s as Platform;
  return platformFromDevice(s);
}

// platform van een geregistreerd apparaat (account_devices.platform: "iPhone", "iPad", "Mac", "Apple TV", "Android",
// "Android tablet", "Android TV", "Google TV", "Fire TV", "tizen", "browser", …)
export function platformFromDevice(v: unknown): Platform | null {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s) return null;
  if (/^(apple ?tv|tvos)$/.test(s)) return "tvos";
  if (/^(iphone|ios)$/.test(s)) return "ios";
  if (/^(ipad|ipados)$/.test(s)) return "ipados";
  if (/^(mac|macos|mac catalyst)$/.test(s)) return "macos";
  if (/^(tizen|samsung tv)$/.test(s)) return "tizen";
  if (/^(browser|web)$/.test(s)) return "web";
  if (/(android ?tv|google ?tv|fire ?tv|androidtv)/.test(s)) return "androidtv";
  if (/^android/.test(s)) return "android";
  return null;
}

export function linkGroup(p: Platform): keyof UpgradeLink {
  return p === "ios" || p === "ipados" || p === "tvos" || p === "macos" ? "apple" : p;
}

// instelling app_settings.upgrade_link (jsonb) lezen; ontbrekende of ongeldige sleutels krijgen de standaard
export function normalizeUpgradeLink(v: unknown): UpgradeLink {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const out = { ...DEFAULT_UPGRADE_LINK };
  for (const k of Object.keys(out) as (keyof UpgradeLink)[]) if (typeof o[k] === "boolean") out[k] = o[k] as boolean;
  return out;
}

// onbekend platform: geen link (veilig voor de Apple-apps)
export function upgradeLinkFor(settings: UpgradeLink, platform: Platform | null): boolean {
  return platform ? settings[linkGroup(platform)] === true : false;
}

export function entitlements(row: PlanRow, settings: UpgradeLink, platform: Platform | null): Entitlements {
  const plan = normalizePlan(row?.plan);
  return {
    plan,
    limits: limitsFor(row),
    features: featuresFor(plan),
    upgrade: { url: UPGRADE_URL, link: upgradeLinkFor(settings, platform), price: PRICE_NL, price_en: PRICE_EN },
  };
}

// 403-antwoord voor een functie die alleen bij Lifetime hoort
export const featureLocked = (feature: "stats" | "now_watching", plan: Plan) => ({ error: "feature_locked", feature, plan });
