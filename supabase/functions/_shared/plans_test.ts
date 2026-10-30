// deno test supabase/functions/_shared/plans_test.ts
import {
  DEFAULT_UPGRADE_LINK, entitlements, PLAN_DEFAULTS, featuresFor, limitsFor, normalizePlan, normalizePlatform, normalizeUpgradeLink,
  override, platformFromDevice, upgradeLinkFor,
} from "./plans.ts";
function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("abonnement: geen rij of onbekend = gratis", () => {
  eq(normalizePlan(undefined), "free");
  eq(normalizePlan("pro"), "free");
  eq(normalizePlan("lifetime"), "lifetime");
  eq(limitsFor(null), { streams: 1, devices: 2, servers: 1 });
  eq(limitsFor({ plan: "free" }), { streams: 1, devices: 2, servers: 1 });
});

Deno.test("abonnement: lifetime-standaard en eigen limieten", () => {
  eq(limitsFor({ plan: "lifetime" }), { streams: 3, devices: 15, servers: null });
  eq(limitsFor({ plan: "lifetime", max_streams: 10, max_devices: 25 }), { streams: 10, devices: 25, servers: null });
  eq(limitsFor({ plan: "free", max_streams: 4, max_devices: null }), { streams: 4, devices: 2, servers: 1 }, "gratis met meer streams");
  eq(limitsFor({ plan: "lifetime", max_streams: 0, max_devices: -3 }), { streams: 3, devices: 15, servers: null }, "ongeldig = standaard");
  eq(limitsFor({ plan: "lifetime", max_streams: "8" }), { streams: 8, devices: 15, servers: null }, "getal als tekst");
});

Deno.test("standaard: gratis 1 en lifetime 3 gelijktijdige kijkers", () => {
  eq(PLAN_DEFAULTS.free.streams, 1);
  eq(PLAN_DEFAULTS.lifetime.streams, 3);
  eq(limitsFor({ plan: "lifetime", max_streams: null }).streams, 3, "geen eigen limiet = standaard");
});

Deno.test("eigen limiet: alleen hele getallen binnen de grens", () => {
  eq(override(null, 50), null);
  eq(override("", 50), null);
  eq(override(3, 50), 3);
  eq(override(2.5, 50), null);
  eq(override(51, 50), null);
  eq(override("abc", 50), null);
});

Deno.test("functies per abonnement", () => {
  eq(featuresFor("free"), {
    stats: false, now_watching: false, trakt: false, multi_server: false, themes: false,
    continue_watching: false, kids_profiles: false, opensubtitles: false,
  });
  eq(featuresFor("lifetime"), {
    stats: true, now_watching: true, trakt: true, multi_server: true, themes: true,
    continue_watching: true, kids_profiles: true, opensubtitles: true,
  });
});

Deno.test("platform uit de aanvraag of van het apparaat", () => {
  eq(normalizePlatform("IOS"), "ios");
  eq(normalizePlatform("androidtv"), "androidtv");
  eq(normalizePlatform(""), null);
  eq(normalizePlatform("onbekend"), null);
  eq(platformFromDevice("Apple TV"), "tvos");
  eq(platformFromDevice("appletv"), "tvos");
  eq(platformFromDevice("iPhone"), "ios");
  eq(platformFromDevice("iPad"), "ipados");
  eq(platformFromDevice("Mac"), "macos");
  eq(platformFromDevice("Android"), "android");
  eq(platformFromDevice("Android tablet"), "android");
  eq(platformFromDevice("Android TV"), "androidtv");
  eq(platformFromDevice("Google TV"), "androidtv");
  eq(platformFromDevice("Fire TV"), "androidtv");
  eq(platformFromDevice("tizen"), "tizen");
  eq(platformFromDevice("Samsung TV"), "tizen");
  eq(platformFromDevice("browser"), "web");
  eq(platformFromDevice("windows"), "web");
  eq(normalizePlatform("Windows"), "web");
  // build 147: LG webOS
  eq(platformFromDevice("webos"), "webos"); eq(platformFromDevice("LG TV"), "webos"); eq(platformFromDevice("LG webOS"), "webos");
  eq(normalizePlatform("webOS"), "webos");
});

Deno.test("upgrade-link per platform", () => {
  const s = DEFAULT_UPGRADE_LINK;
  for (const p of ["ios", "ipados", "tvos", "macos"] as const) eq(upgradeLinkFor(s, p), false, p);
  for (const p of ["android", "androidtv", "tizen", "web", "webos"] as const) eq(upgradeLinkFor(s, p), true, p);
  eq(upgradeLinkFor(s, null), false, "onbekend platform");
  const on = normalizeUpgradeLink({ apple: true, web: false, android: "ja" });
  eq(on, { apple: true, android: true, androidtv: true, tizen: true, web: false, webos: true }, "ongeldige waarde = standaard");
  eq(upgradeLinkFor(on, "tvos"), true);
  eq(normalizeUpgradeLink(null), DEFAULT_UPGRADE_LINK);
  eq(normalizeUpgradeLink([true]), DEFAULT_UPGRADE_LINK);
});

Deno.test("entitlements: volledig antwoord", () => {
  eq(entitlements(null, DEFAULT_UPGRADE_LINK, "web"), {
    plan: "free", limits: { streams: 1, devices: 2, servers: 1 },
    features: {
      stats: false, now_watching: false, trakt: false, multi_server: false, themes: false,
      continue_watching: false, kids_profiles: false, opensubtitles: false,
    },
    upgrade: { url: "https://bingr.online/upgrade/", link: true, price: "€ 4,99", price_en: "€4.99" },
    plans: { free: { streams: 1, devices: 2, servers: 1 }, lifetime: { streams: 3, devices: 15, servers: null } },
  });
  const e = entitlements({ plan: "lifetime", max_devices: 20 }, DEFAULT_UPGRADE_LINK, "ios");
  eq(e.plan, "lifetime");
  eq(e.limits, { streams: 3, devices: 20, servers: null });
  eq(e.features.trakt, true);
  eq(e.upgrade.link, false, "Apple standaard zonder link");
  eq(e.plans.lifetime, { streams: 3, devices: 15, servers: null }, "build 128: standaard, niet de eigen limiet");
});

Deno.test("build 157: gratis 2 apparaten, eigen limiet uit het beheer gaat voor", () => {
  eq(PLAN_DEFAULTS.free.devices, 2);
  eq(PLAN_DEFAULTS.lifetime.devices, 15);
  eq(limitsFor({ plan: "free", max_devices: 8 }).devices, 8, "beheer gaf dit Gratis-account 8 apparaten");
  eq(limitsFor({ plan: "free", max_devices: 0 }).devices, 2, "ongeldige eigen limiet = standaard");
  eq(entitlements({ plan: "free", max_devices: 5 }, DEFAULT_UPGRADE_LINK, "web").plans.free.devices, 2, "vergelijking = standaard");
});

Deno.test("build 157: Verder kijken, kinderprofielen en OpenSubtitles alleen bij Lifetime", () => {
  for (const k of ["continue_watching", "kids_profiles", "opensubtitles"] as const) {
    eq(entitlements(null, DEFAULT_UPGRADE_LINK, "ios").features[k], false, `geen rij: ${k}`);
    eq(entitlements({ plan: "free" }, DEFAULT_UPGRADE_LINK, "android").features[k], false, `gratis: ${k}`);
    eq(entitlements({ plan: "pro" }, DEFAULT_UPGRADE_LINK, "web").features[k], false, `onbekend abonnement: ${k}`);
    eq(entitlements({ plan: "lifetime" }, DEFAULT_UPGRADE_LINK, "tvos").features[k], true, `lifetime: ${k}`);
  }
  // bestaande functies ongewijzigd
  eq(featuresFor("free").stats, false);
  eq(featuresFor("lifetime").themes, true);
});

Deno.test("build 157: oude server zonder de nieuwe vlaggen = Gratis voor die functies", () => {
  // zo lezen de apps het (sleutel ontbreekt of is niet true = Gratis); het antwoord van een server van vóór build 157:
  const old = { stats: true, now_watching: true, trakt: true, multi_server: true, themes: true } as Record<string, unknown>;
  const allowed = (f: Record<string, unknown>, k: string) => f[k] === true;
  for (const k of ["continue_watching", "kids_profiles", "opensubtitles"]) eq(allowed(old, k), false, `oude server: ${k}`);
  eq(allowed(featuresFor("lifetime") as unknown as Record<string, unknown>, "kids_profiles"), true);
});
