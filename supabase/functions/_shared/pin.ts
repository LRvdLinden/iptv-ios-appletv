// Build 146: pincode van een profiel als hash (docs/ACCOUNT.md, "Build 146" → "Pincode als hash").
// Referentie-implementatie voor alle apps (Swift, Kotlin, JavaScript in de browser en de Tizen-webview) en voor de server
// (device-auth put_state). Test met de testvectoren: deno test supabase/functions/_shared/pin_test.ts
//
// Formaat (veld `pinHash` in state-section `profile.<id>`):
//   {"alg":"pbkdf2-sha256","iter":100000,"salt":"<base64, 16 bytes>","hash":"<base64, 32 bytes>"}
// - wachtwoord = de pincode als ASCII-cijfers, precies zoals ingetypt (4 t/m 8 cijfers, voorloopnullen tellen mee);
// - salt = 16 willekeurige bytes per profiel, nieuw bij elke nieuwe pincode;
// - PBKDF2-HMAC-SHA256, `iter` iteraties (schrijven: altijd PIN_ITER), dkLen 32;
// - base64 = standaard-base64 (RFC 4648 §4, met `+` `/` en `=`-opvulling).
// Een 4-cijferige pincode blijft met de hash in de hand te raden (10.000 mogelijkheden); daarom staat de hash alleen in de
// versleutelde state (AES-GCM op de server) en nooit leesbaar in de database of in een log.

export const PIN_ALG = "pbkdf2-sha256";
export const PIN_ITER = 100_000;
export const PIN_SALT_BYTES = 16;
export const PIN_HASH_BYTES = 32;
/** Grenzen voor `iter` bij het lezen (een latere build mag het aantal verhogen; lager dan 10.000 wordt geweigerd). */
export const PIN_ITER_MIN = 10_000, PIN_ITER_MAX = 2_000_000;

export type PinHash = { alg: typeof PIN_ALG; iter: number; salt: string; hash: string };

export const validPin = (pin: unknown): pin is string => typeof pin === "string" && /^[0-9]{4,8}$/.test(pin);

export function b64encode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}
export function b64decode(s: string): Uint8Array | null {
  if (typeof s !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) return null;
  try { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); } catch { return null; }
}

/** Geldig pinHash-object (anders null). Onbekende extra velden worden genegeerd. */
export function parsePinHash(v: unknown): PinHash | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (o.alg !== PIN_ALG) return null;
  const iter = Number(o.iter);
  if (!Number.isInteger(iter) || iter < PIN_ITER_MIN || iter > PIN_ITER_MAX) return null;
  const salt = b64decode(String(o.salt ?? "")), hash = b64decode(String(o.hash ?? ""));
  if (!salt || salt.length < 8 || salt.length > 64 || !hash || hash.length !== PIN_HASH_BYTES) return null;
  return { alg: PIN_ALG, iter, salt: String(o.salt), hash: String(o.hash) };
}

/** PBKDF2-HMAC-SHA256 met WebCrypto (Deno, browsers, Tizen 5.5+ in een veilige context). */
export async function pbkdf2(pin: string, salt: Uint8Array, iter: number, dkLen = PIN_HASH_BYTES): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(pin), "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(salt), iterations: iter }, key, dkLen * 8));
}

/** Nieuwe hash voor een pincode (nieuwe salt, tenzij meegegeven voor een test). */
export async function makePinHash(pin: string, salt?: Uint8Array): Promise<PinHash> {
  if (!validPin(pin)) throw new Error("bad_pin");
  const s = salt ?? crypto.getRandomValues(new Uint8Array(PIN_SALT_BYTES));
  return { alg: PIN_ALG, iter: PIN_ITER, salt: b64encode(s), hash: b64encode(await pbkdf2(pin, s, PIN_ITER)) };
}

/** Klopt de pincode? Vergelijkt in vaste tijd; een ongeldig object = false. */
export async function verifyPin(pin: string, h: unknown, derive: typeof pbkdf2 = pbkdf2): Promise<boolean> {
  const p = parsePinHash(h);
  if (!p || !validPin(pin)) return false;
  const got = await derive(pin, b64decode(p.salt)!, p.iter), want = b64decode(p.hash)!;
  let d = got.length ^ want.length;
  for (let i = 0; i < Math.min(got.length, want.length); i++) d |= got[i] ^ want[i];
  return d === 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Pure JavaScript (zonder crypto.subtle): voor de Tizen-webview of een browser zonder veilige context. Zelfde uitkomst
// (zie de testvectoren). Gebruikt de HMAC-tussenstand (ipad/opad één keer), dus 2 SHA-256-compressies per iteratie.
// Mag 1-op-1 gekopieerd worden (ES5-compatibel als je `const`/`let` vervangt door `var`).
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
const IV = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
const W = new Uint32Array(64);
/** Eén SHA-256-compressie: state (8 woorden) wordt bijgewerkt met blok m (16 woorden, big-endian). */
function compress(state: Uint32Array, m: Uint32Array) {
  for (let i = 0; i < 16; i++) W[i] = m[i];
  for (let i = 16; i < 64; i++) {
    const a = W[i - 15], b = W[i - 2];
    const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
    const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
    W[i] = (W[i - 16] + s0 + W[i - 7] + s1) | 0;
  }
  let a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7];
  for (let i = 0; i < 64; i++) {
    const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
    const t1 = (h + S1 + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0;
    const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
    const t2 = (S0 + ((a & b) ^ (a & c) ^ (b & c))) | 0;
    h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
  }
  state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}
function words(bytes: Uint8Array): Uint32Array {
  const w = new Uint32Array(Math.ceil(bytes.length / 4));
  for (let i = 0; i < bytes.length; i++) w[i >> 2] |= bytes[i] << (24 - (i & 3) * 8);
  return w;
}
/** SHA-256 van een willekeurig bericht (voor een te lange HMAC-sleutel en de eerste HMAC met de salt). */
function sha256Js(msg: Uint8Array, state0?: Uint32Array, prefixLen = 0): Uint32Array {
  const st = state0 ? Uint32Array.from(state0) : Uint32Array.from(IV);
  const total = prefixLen + msg.length;
  const padLen = ((msg.length + 9 + 63) >> 6) << 6;
  const buf = new Uint8Array(padLen);
  buf.set(msg); buf[msg.length] = 0x80;
  const bits = total * 8;
  buf[padLen - 4] = (bits >>> 24) & 255; buf[padLen - 3] = (bits >>> 16) & 255; buf[padLen - 2] = (bits >>> 8) & 255; buf[padLen - 1] = bits & 255;
  buf[padLen - 5] = Math.floor(bits / 2 ** 32) & 255;
  const w = words(buf);
  for (let i = 0; i < w.length; i += 16) compress(st, w.subarray(i, i + 16));
  return st;
}
/** PBKDF2-HMAC-SHA256 in pure JavaScript; dkLen max. 32 (één blok, genoeg voor pinHash). */
export function pbkdf2Js(pin: string, salt: Uint8Array, iter: number, dkLen = PIN_HASH_BYTES): Uint8Array {
  if (dkLen > 32) throw new Error("dkLen > 32");
  let key = new TextEncoder().encode(pin);
  if (key.length > 64) {
    const h = sha256Js(key), kb = new Uint8Array(32);
    for (let i = 0; i < 32; i++) kb[i] = (h[i >> 2] >>> (24 - (i & 3) * 8)) & 255;
    key = kb;
  }
  const ipad = new Uint8Array(64).fill(0x36), opad = new Uint8Array(64).fill(0x5c);
  for (let i = 0; i < key.length; i++) { ipad[i] ^= key[i]; opad[i] ^= key[i]; }
  const inner = Uint32Array.from(IV), outer = Uint32Array.from(IV);
  compress(inner, words(ipad)); compress(outer, words(opad));
  // U1 = HMAC(P, salt || INT(1))
  const first = new Uint8Array(salt.length + 4); first.set(salt); first[salt.length + 3] = 1;
  const ih = sha256Js(first, inner, 64);
  // vaste blokken voor een bericht van 32 bytes na een sleutelblok van 64: lengte 96 bytes = 768 bits
  const blk = new Uint32Array(16); blk[8] = 0x80000000; blk[15] = 768;
  const st = new Uint32Array(8);
  const hmac32 = (msg: Uint32Array, out: Uint32Array) => {
    for (let i = 0; i < 8; i++) blk[i] = msg[i];
    st.set(inner); compress(st, blk);
    for (let i = 0; i < 8; i++) blk[i] = st[i];
    out.set(outer); compress(out, blk);
  };
  const u = new Uint32Array(8), t = new Uint32Array(8);
  // outer van U1
  for (let i = 0; i < 8; i++) blk[i] = ih[i];
  u.set(outer); compress(u, blk);
  t.set(u);
  for (let n = 1; n < iter; n++) { hmac32(u, u); for (let i = 0; i < 8; i++) t[i] ^= u[i]; }
  const out = new Uint8Array(dkLen);
  for (let i = 0; i < dkLen; i++) out[i] = (t[i >> 2] >>> (24 - (i & 3) * 8)) & 255;
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// Server: state-section `profile.<id>` bij put_state (device-auth). Regels (docs/ACCOUNT.md, "Build 146"):
// - Zodra er voor een profiel een geldige `pinHash` is (opgeslagen of binnenkomend), staat `pin` nooit meer leesbaar
//   op de server: `pin` wordt null.
// - Binnenkomend zonder sleutel `pinHash` (oude app, of een app die de pincode niet aanraakte) terwijl de server er al
//   een heeft: de opgeslagen `pinHash` blijft staan (een oude app kan hem niet wissen). Stuurt zo'n oude app een andere
//   pincode met een nieuwere `pinUpdatedAt`, dan hasht de server die zelf; `pin: null` met een nieuwere `pinUpdatedAt`
//   betekent: pincode verwijderd.
// - Binnenkomend `pinHash: null` = pincode verwijderd (pin wordt ook null); een ongeldige `pinHash` = fout bad_pin_hash.
// - Zonder `pinHash` aan beide kanten (alleen oude apps tot nu toe): niets veranderen (oude gedrag).
const ms = (v: unknown) => { const t = Date.parse(String(v ?? "")); return Number.isFinite(t) ? t : 0; };
export type PinNormalized = { data: Record<string, unknown>; changed: boolean } | { error: "bad_pin_hash" };
export async function normalizePinSection(stored: unknown, incoming: unknown, hash: (pin: string) => Promise<PinHash> = makePinHash): Promise<PinNormalized> {
  if (!incoming || typeof incoming !== "object" || Array.isArray(incoming)) return { data: incoming as Record<string, unknown>, changed: false };
  const inc = { ...(incoming as Record<string, unknown>) };
  const st = stored && typeof stored === "object" && !Array.isArray(stored) ? stored as Record<string, unknown> : {};
  const storedHash = parsePinHash(st.pinHash);
  if ("pinHash" in inc) {
    if (inc.pinHash === null) {
      // pincode verwijderd, of (nieuwe app) een nieuwe pincode die toch als pin binnenkwam: hashen
      if (validPin(inc.pin)) { inc.pinHash = await hash(inc.pin); inc.pin = null; return { data: inc, changed: true }; }
      const had = inc.pin != null;
      inc.pin = null;
      return { data: inc, changed: had };
    }
    const h = parsePinHash(inc.pinHash);
    if (!h) return { error: "bad_pin_hash" };
    const had = inc.pin != null;
    inc.pinHash = h; inc.pin = null;
    return { data: inc, changed: had };
  }
  if (!storedHash) return { data: inc, changed: false }; // alleen oude apps: oude gedrag
  const newer = ms(inc.pinUpdatedAt) > ms(st.pinUpdatedAt);
  if (newer && validPin(inc.pin)) { inc.pinHash = await hash(inc.pin); inc.pin = null; return { data: inc, changed: true }; }
  if (newer && inc.pin === null) { inc.pinHash = null; return { data: inc, changed: true }; }
  inc.pinHash = storedHash; inc.pin = null;
  if (st.pinUpdatedAt != null) inc.pinUpdatedAt = st.pinUpdatedAt;
  return { data: inc, changed: true };
}
