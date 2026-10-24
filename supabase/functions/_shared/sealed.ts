// Versleuteling at rest van accountgegevens (account_state, account_sources, sinds build 146 ook account_data.sealed):
// AES-256-GCM met BINGR_SOURCES_KEY (32 bytes, base64; eenmalig aangemaakt door de Backend-workflow).
// Formaat: base64(nonce(12) || ciphertext+tag). device-auth, push en support gebruiken allemaal deze functies.
//
// Build 146: losse tekstvelden (titels en profielnamen in de kijkgegevens, supportberichten, diagnose-bijlagen,
// pushpayloads) worden per veld versleuteld: `enc1:` + base64(nonce || ciphertext+tag) van de UTF-8-tekst. Een waarde
// zonder dat voorvoegsel is nog niet versleuteld (van vóór build 146) en wordt ongewijzigd gelezen; zo kan alles
// geleidelijk en zonder downtime over. Lukt ontsleutelen niet (bv. een klant typte zelf "enc1:"), dan blijft de tekst
// zoals hij is.
let keyPromise: Promise<CryptoKey> | null = null;
let keyFor = "";
function rawKey(raw64: string): Uint8Array<ArrayBuffer> {
  const raw = Uint8Array.from(atob(raw64), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("sources_key_missing");
  return raw;
}
function sourcesKey(raw64 = Deno.env.get("BINGR_SOURCES_KEY") ?? ""): Promise<CryptoKey> {
  if (!keyPromise || keyFor !== raw64) {
    keyFor = raw64;
    keyPromise = (async () => crypto.subtle.importKey("raw", rawKey(raw64), "AES-GCM", false, ["encrypt", "decrypt"]))();
    keyPromise.catch(() => { keyPromise = null; });
  }
  return keyPromise;
}
function b64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(s);
}
async function encrypt(plain: Uint8Array, key64?: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await sourcesKey(key64), new Uint8Array(plain)));
  const out = new Uint8Array(iv.length + ct.length); out.set(iv); out.set(ct, iv.length);
  return b64(out);
}
async function decrypt(data: string, key64?: string): Promise<Uint8Array> {
  const all = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12) }, await sourcesKey(key64), all.subarray(12)));
}
export async function seal(obj: unknown, key64?: string): Promise<string> {
  return encrypt(new TextEncoder().encode(JSON.stringify(obj)), key64);
}
// deno-lint-ignore no-explicit-any
export async function unseal(data: string, key64?: string): Promise<any> {
  return JSON.parse(new TextDecoder().decode(await decrypt(data, key64)));
}

// ---- per veld (build 146) ----
export const FIELD_PREFIX = "enc1:";
export const isSealedField = (v: unknown): v is string => typeof v === "string" && v.startsWith(FIELD_PREFIX);
/** Tekst versleutelen voor één kolom; null/leeg blijft null (dan valt er niets te lezen). */
export async function sealField(v: unknown, key64?: string): Promise<string | null> {
  if (v == null) return null;
  const s = String(v);
  if (s === "") return null;
  return FIELD_PREFIX + await encrypt(new TextEncoder().encode(s), key64);
}
/** Kolom lezen: `enc1:…` ontsleutelen, anders (oude, onversleutelde waarde) ongewijzigd. Nooit een fout. */
export async function openField(v: unknown, key64?: string): Promise<string | null> {
  if (v == null) return null;
  const s = String(v);
  if (!s.startsWith(FIELD_PREFIX)) return s;
  try { return new TextDecoder().decode(await decrypt(s.slice(FIELD_PREFIX.length), key64)); } catch { return s; }
}
/** JSON-waarde als één versleuteld veld (diagnose-bijlage, pushpayload). */
export async function sealJsonField(obj: unknown, key64?: string): Promise<string> {
  return FIELD_PREFIX + await seal(obj, key64);
}
// deno-lint-ignore no-explicit-any
export async function openJsonField(v: unknown, key64?: string): Promise<any> {
  if (!isSealedField(v)) return null;
  try { return await unseal(v.slice(FIELD_PREFIX.length), key64); } catch { return null; }
}

// ---- afgeleide sleutels (nooit de AES-sleutel zelf) ----
const hmacCache = new Map<string, Promise<CryptoKey>>();
/** HMAC-SHA256-sleutel = HMAC(BINGR_SOURCES_KEY, label); voor vaste, niet terug te rekenen sleutels (bv. titelsleutels in
 *  de statistieken). Zelfde opbouw als web-proxy (labels verschillen). */
function derivedKey(label: string, key64 = Deno.env.get("BINGR_SOURCES_KEY") ?? ""): Promise<CryptoKey> {
  const id = `${label}|${key64}`;
  let p = hmacCache.get(id);
  if (!p) {
    p = (async () => {
      const base = await crypto.subtle.importKey("raw", rawKey(key64), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
      const sub = new Uint8Array(await crypto.subtle.sign("HMAC", base, new TextEncoder().encode(label)));
      return crypto.subtle.importKey("raw", sub, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    })();
    p.catch(() => hmacCache.delete(id));
    hmacCache.set(id, p);
  }
  return p;
}
/** Vaste, korte sleutel (32 hex) voor een tekst, per label; zelfde invoer = zelfde sleutel, niet terug te rekenen. */
export async function keyedHash(label: string, text: string, key64?: string): Promise<string> {
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await derivedKey(label, key64), new TextEncoder().encode(text)));
  return Array.from(sig.subarray(0, 16), (x) => x.toString(16).padStart(2, "0")).join("");
}
