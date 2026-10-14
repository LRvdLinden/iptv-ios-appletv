// build 95: captcha zonder derde partij voor nieuwe tickets (proof-of-work in de stijl van ALTCHA). Pure functies (alleen
// WebCrypto), getest in support_test.ts.
//   challenge: {algorithm:"SHA-256", salt, difficulty, expires, signature}; signature = HMAC-SHA256(salt|difficulty|expires)
//              met een servergeheim (afgeleid van een bestaand geheim, zie powKey).
//   oplossing: de browser zoekt een nonce (getal als tekst) waarbij SHA-256(salt + nonce) begint met `difficulty` nul-bits.
//   create stuurt pow {salt, difficulty, expires, signature, nonce}; de functie controleert handtekening, vervaltijd en
//   hash, en dat de salt nog niet gebruikt is (tabel support_pow_used).
export const POW_ALGORITHM = "SHA-256";
export const POW_DIFFICULTY = 18; // gemiddeld 2^18 ≈ 262.000 pogingen: op een telefoon ongeveer 0,5–2 s
export const POW_TTL_MS = 10 * 60 * 1000;
export const POW_LABEL = "bingr-support-pow-v1";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer | Uint8Array) => Array.from(b instanceof Uint8Array ? b : new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");

/** HMAC-sleutel voor de challenges: HMAC-SHA256(basisgeheim, vast label), zodat het basisgeheim zelf nergens anders voor
 *  gebruikt wordt. Leeg basisgeheim: null (dan geen captcha mogelijk). */
export async function powKey(base: string): Promise<CryptoKey | null> {
  if (!base) return null;
  const k0 = await crypto.subtle.importKey("raw", enc.encode(base), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const derived = await crypto.subtle.sign("HMAC", k0, enc.encode(POW_LABEL));
  return crypto.subtle.importKey("raw", derived, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}
async function sign(key: CryptoKey, salt: string, difficulty: number, expires: number) {
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${salt}|${difficulty}|${expires}`)));
}

export type Challenge = { algorithm: string; salt: string; difficulty: number; expires: number; signature: string };
export async function makeChallenge(key: CryptoKey, now = Date.now(), difficulty = POW_DIFFICULTY): Promise<Challenge> {
  const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
  const expires = now + POW_TTL_MS;
  return { algorithm: POW_ALGORITHM, salt, difficulty, expires, signature: await sign(key, salt, difficulty, expires) };
}

/** Aantal nul-bits aan het begin van een hash. */
export function leadingZeroBits(b: Uint8Array): number {
  let n = 0;
  for (const x of b) {
    if (x === 0) { n += 8; continue; }
    return n + Math.clz32(x) - 24;
  }
  return n;
}
export async function powHash(salt: string, nonce: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(salt + nonce)));
}

/** Tijdsveilig vergelijken (hex-strings). */
function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export type PowCheck = { ok: true; salt: string } | { ok: false; reason: "missing" | "malformed" | "signature" | "expired" | "difficulty" | "hash" };
/** Controleert een opgeloste challenge (zonder de eenmaligheid van de salt: dat doet de functie in de database). */
export async function verifyPow(key: CryptoKey, pow: unknown, now = Date.now(), minDifficulty = POW_DIFFICULTY): Promise<PowCheck> {
  if (!pow || typeof pow !== "object") return { ok: false, reason: "missing" };
  const p = pow as Record<string, unknown>;
  const salt = p.salt, sig = p.signature, nonce = p.nonce;
  const difficulty = Number(p.difficulty), expires = Number(p.expires);
  if (typeof salt !== "string" || !/^[0-9a-f]{32}$/.test(salt) || typeof sig !== "string" || !/^[0-9a-f]{64}$/.test(sig) ||
    !Number.isInteger(difficulty) || !Number.isInteger(expires) || (typeof nonce !== "string" && typeof nonce !== "number") ||
    !/^\d{1,12}$/.test(String(nonce))) return { ok: false, reason: "malformed" };
  if (!same(await sign(key, salt, difficulty, expires), sig)) return { ok: false, reason: "signature" };
  if (expires < now || expires > now + POW_TTL_MS + 60_000) return { ok: false, reason: "expired" };
  if (difficulty < minDifficulty || difficulty > 32) return { ok: false, reason: "difficulty" };
  if (leadingZeroBits(await powHash(salt, String(nonce))) < difficulty) return { ok: false, reason: "hash" };
  return { ok: true, salt };
}
