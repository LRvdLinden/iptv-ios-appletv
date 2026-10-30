// Bingr-abonnementen: Gratis en Lifetime (docs/ACCOUNT.md, "Abonnementen"). Pure logica zonder database, zodat
// device-auth (limieten, functies, upgrade-link) en de unittests (plans_test.ts) precies hetzelfde rekenen.
//   free     -> 1 stream (gelijktijdige kijker), 2 apparaten (build 157, was 8), 1 server, geen statistieken / nu aan het kijken /
//               Trakt / meerdere servers / thema's / Verder kijken / kinderprofielen / OpenSubtitles
//   lifetime -> 3 streams, 15 apparaten, onbeperkt servers, alles aan
// Build 157: continue_watching, kids_profiles en opensubtitles erbij. Oudere apps kennen die sleutels niet en negeren ze; een app
// die een sleutel mist (oudere server) behandelt hem als false (= Gratis). De server dwingt af: de apparatenlimiet (ook voor
// accounts die er al boven zaten: bingr_enforce_free_devices houdt de 2 laatst actieve), de OpenSubtitles-sleutel in config
// en nieuwe kinderprofielen in put_profiles (docs/ACCOUNT.md, "Build 157").
// De streamlimiet is Bingr's eigen telling (account_streams), los van de limiet van de IPTV-provider
// (Xtream max_connections); die controleren de apps apart bij het afspelen.
// Per account kan het beheer max_streams / max_devices verhogen (null = standaard van het abonnement).

export type Plan = "free" | "lifetime";
export type Limits = { streams: number; devices: number; servers: number | null };
export type Features = {
  stats: boolean; now_watching: boolean; trakt: boolean; multi_server: boolean; themes: boolean;
  // build 157
  continue_watching: boolean; kids_profiles: boolean; opensubtitles: boolean;
};
export type PlanRow = { plan?: unknown; max_streams?: unknown; max_devices?: unknown } | null | undefined;
export type UpgradeLink = { apple: boolean; android: boolean; androidtv: boolean; tizen: boolean; web: boolean; webos: boolean };
export type Platform = "ios" | "ipados" | "tvos" | "macos" | "android" | "androidtv" | "tizen" | "web" | "webos";
export type Entitlements = {
  plan: Plan;
  limits: Limits;
  features: Features;
  upgrade: { url: string; link: boolean; price: string; price_en: string };
  // build 128: de standaardlimieten van beide abonnementen, zodat de apps de vergelijking niet hardcoderen
  plans: Record<Plan, Limits>;
};

export const PLAN_DEFAULTS: Record<Plan, Limits> = {
  free: { streams: 1, devices: 2, servers: 1 }, // build 157: 2 apparaten (was 8)
  lifetime: { streams: 3, devices: 15, servers: null },
};
export const UPGRADE_URL = "https://bingr.online/upgrade/";
export const PRICE_NL = "€ 4,99";
export const PRICE_EN = "€4.99";
// build 133: betalen via Stripe op bingr.online/upgrade/ (functie billing, _shared/billing.ts): eenmalig 499 cent in euro
export const PRICE_CENTS = 499;
export const PRICE_CURRENCY = "eur";
export const PRODUCT_NAME = "Bingr Lifetime";
// standaard: in de Apple-apps geen link naar de betaalpagina (alleen de vergelijking), elders wel
// build 147: webos = de LG-tv-app (bingr-webos)
export const DEFAULT_UPGRADE_LINK: UpgradeLink = { apple: false, android: true, androidtv: true, tizen: true, web: true, webos: true };
export const PLATFORMS: Platform[] = ["ios", "ipados", "tvos", "macos", "android", "androidtv", "tizen", "web", "webos"];
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
  return {
    stats: on, now_watching: on, trakt: on, multi_server: on, themes: on,
    continue_watching: on, kids_profiles: on, opensubtitles: on,
  };
}

// platform uit de aanvraag (ios, ipados, tvos, macos, android, androidtv, tizen, web), hoofdletterongevoelig; anders null
export function normalizePlatform(v: unknown): Platform | null {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s) return null;
  if ((PLATFORMS as string[]).includes(s)) return s as Platform;
  return platformFromDevice(s);
}

// platform van een geregistreerd apparaat (account_devices.platform: "iPhone", "iPad", "Mac", "Apple TV", "Android",
// "Android tablet", "Android TV", "Google TV", "Fire TV", "tizen", "browser", "windows", …)
export function platformFromDevice(v: unknown): Platform | null {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s) return null;
  if (/^(apple ?tv|tvos)$/.test(s)) return "tvos";
  if (/^(iphone|ios)$/.test(s)) return "ios";
  if (/^(ipad|ipados)$/.test(s)) return "ipados";
  if (/^(mac|macos|mac catalyst)$/.test(s)) return "macos";
  if (/^(tizen|samsung tv)$/.test(s)) return "tizen";
  // build 147: de LG-tv-app meldt zich aan als "webos" (of "LG TV" / "LG webOS")
  if (/^(webos|lg ?tv|lg ?webos)$/.test(s)) return "webos";
  // de Windows-app (bingr-windows) is de webspeler in een eigen venster: upgrade-link en functies zoals web
  if (/^(browser|web|windows)$/.test(s)) return "web";
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
    plans: { free: { ...PLAN_DEFAULTS.free }, lifetime: { ...PLAN_DEFAULTS.lifetime } },
  };
}

// 403-antwoord voor een functie die alleen bij Lifetime hoort
export const featureLocked = (feature: "stats" | "now_watching" | "kids_profiles", plan: Plan) => ({ error: "feature_locked", feature, plan });
