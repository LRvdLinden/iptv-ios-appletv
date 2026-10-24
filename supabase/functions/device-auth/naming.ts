// Eigen apparaatnaam bij het koppelen (bingr.online/koppelen): de naam die de gebruiker kiest voordat de tv inlogt.
// Pure functies, getest in naming_test.ts.

export const NAME_MAX = 40;

// Soort apparaat. `device` bij start ("Apple TV", "Mac", "iPhone", "Android TV", "Fire TV", "Android", "Samsung TV") en
// `platform` bij register_device ("Apple TV", "iPhone", "iPad", "Mac", "Android", "Android tablet", "Android TV",
// "Google TV", "Fire TV", "tizen", "browser", "windows") komen zo op dezelfde soort uit. De Windows-app is de webspeler.
const KIND: Record<string, string> = {
  "apple tv": "tvos", tvos: "tvos", iphone: "ios", ipad: "ios", ios: "ios", ipados: "ios", mac: "macos", macos: "macos",
  android: "android", "android tablet": "android", "android tv": "androidtv", "google tv": "androidtv", "fire tv": "androidtv",
  androidtv: "androidtv", tizen: "tizen", "samsung tv": "tizen", browser: "web", web: "web", windows: "web",
  // build 147: LG-tv-app (bingr-webos): platform "webos", device "LG TV" of "LG webOS"
  webos: "webos", "lg tv": "webos", "lg webos": "webos", lgtv: "webos",
};
// De webspeler start met zijn weergavenaam ("Chrome op Mac", "Safari on iPad") en meldt zich aan met platform "browser".
const BROWSER = /\b(browser|chrome|chromium|safari|firefox|edge|opera|brave|vivaldi|samsung internet)\b/i;
export const deviceKind = (v: unknown): string => {
  const s = String(v ?? "").trim().toLowerCase();
  return KIND[s] ?? (BROWSER.test(s) ? "web" : "other");
};

/** Leesbare soort voor het naamveld ("Samsung TV - …"); onbekend: "TV". */
export function deviceTypeLabel(v: unknown): string {
  const s = String(v ?? "").trim().slice(0, 40);
  const l = s.toLowerCase();
  if (l === "tizen") return "Samsung TV";
  if (l === "webos") return "LG TV";
  if (l === "browser") return "Browser";
  return s || "TV";
}

/**
 * Naam uit het koppelformulier: opgeschoond (geen stuurtekens of richting-tekens, spaties samengevoegd, scheidingsteken
 * aan het eind weg: "Apple TV - " -> "Apple TV"). Leeg, of alleen de soort zelf: null (dan geen eigen naam).
 * Te lang (> 40 tekens): {error:"name_too_long"}.
 */
export function cleanDeviceName(raw: unknown, typeLabel = ""): { name: string | null } | { error: "name_too_long" } {
  if (raw == null) return { name: null };
  let s = String(raw).replace(/[​-‏‪-‮⁦-⁩﻿]/g, "").replace(/[\u0000-\u001f\u007f]+/g, " ");
  s = s.replace(/\s+/g, " ").trim().replace(/[\s\-–—:·|,]+$/u, "").trim();
  if (!s) return { name: null };
  if ([...s].length > NAME_MAX) return { error: "name_too_long" };
  if (typeLabel && s.toLowerCase() === typeLabel.trim().toLowerCase()) return { name: null };
  return { name: s };
}
