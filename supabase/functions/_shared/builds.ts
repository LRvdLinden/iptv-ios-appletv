// Bingr: buildpakketten in de afgesloten opslag van beheer.bingr.online (map builds/, alleen via dl.php).
// Gedeeld door de functies status (controle "build") en push (melding "nieuwe build" naar de beheer-app).
// dl.php accepteert een kortgeldige, ondertekende link: HMAC-SHA256 met het function-secret BINGR_BUILDS_KEY, zelfde formaat
// als de functie admin in bingr-beheer. Sleutel, tokens en links komen nooit in een log of resultaat.
export const BUILDS_DL = "https://beheer.bingr.online/dl.php";
export const BUILD_PLATFORMS = ["android", "tizen", "apple", "beheer"] as const;
export type BuildEntry = { build?: number; date?: string; file?: string; path?: string; size?: number };
export type BuildManifest = { platforms?: Record<string, BuildEntry> };

const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
/** Token voor dl.php: base64url(JSON {f, e}) + "." + base64url(HMAC-SHA256(key, payload)). */
export async function signBuildToken(key: string, path: string, ttlSeconds: number, nowSec = Math.floor(Date.now() / 1000)): Promise<string> {
  const enc = new TextEncoder();
  const payload = b64url(enc.encode(JSON.stringify({ f: path, e: nowSec + ttlSeconds })));
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(payload)));
  return `${payload}.${b64url(sig)}`;
}

/** manifest.json uit de opslag ophalen. Gooit een fout zonder link of sleutel erin ("manifest HTTP 403"). */
export async function fetchBuildManifest(key: string, opts: { fetch?: typeof fetch; signal?: AbortSignal; ua?: string } = {}): Promise<BuildManifest> {
  const f = opts.fetch ?? fetch;
  const res = await f(`${BUILDS_DL}?t=${await signBuildToken(key, "manifest.json", 60)}`,
    { signal: opts.signal, headers: { "User-Agent": opts.ua ?? "Bingr/1.0" }, redirect: "error" });
  if (!res.ok) { await res.body?.cancel(); throw new Error(`manifest HTTP ${res.status}`); }
  return await res.json();
}
