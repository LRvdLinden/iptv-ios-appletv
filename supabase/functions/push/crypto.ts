// Bingr push: cryptografie zonder externe pakketten (alleen WebCrypto).
// - base64url
// - JWT ES256 (APNs provider token, VAPID) en RS256 (Google OAuth2 voor FCM)
// - Web Push-versleuteling: RFC 8291 (aes128gcm, RFC 8188) en VAPID (RFC 8292)

const te = new TextEncoder();
export type Bytes = Uint8Array<ArrayBuffer>;

export function b64u(bytes: Bytes | ArrayBuffer): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode(...b.subarray(i, i + 8192));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function unb64u(s: string): Bytes {
  const t = String(s ?? "").trim().replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  if (!/^[A-Za-z0-9+/]*$/.test(t)) throw new Error("bad_base64");
  const bin = atob(t + "===".slice((t.length + 3) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}
export function concat(...parts: Bytes[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// PEM (PKCS#8, "-----BEGIN PRIVATE KEY-----") naar DER. Ook een sleutel met letterlijke "\n" (uit een env/JSON) werkt.
export function pemToDer(pem: string): Bytes {
  const body = String(pem ?? "").replace(/\\n/g, "\n").replace(/-----(BEGIN|END)[^-]+-----/g, "").replace(/\s+/g, "");
  if (!body) throw new Error("empty_key");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

export function importEs256Pkcs8(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToDer(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}
export function importRs256Pkcs8(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToDer(pem), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

// JWT ondertekenen. ES256: WebCrypto geeft de handtekening al als r||s (64 bytes), precies wat JWS (RFC 7518) vraagt.
export async function signJwt(header: Record<string, unknown>, claims: Record<string, unknown>, key: CryptoKey): Promise<string> {
  const input = `${b64u(te.encode(JSON.stringify(header)))}.${b64u(te.encode(JSON.stringify(claims)))}`;
  const alg = header.alg === "RS256" ? { name: "RSASSA-PKCS1-v1_5" } : { name: "ECDSA", hash: "SHA-256" };
  const sig = await crypto.subtle.sign(alg, key, te.encode(input));
  return `${input}.${b64u(sig)}`;
}

// APNs provider token: {alg:ES256, kid} + {iss: team-id, iat}. Apple accepteert hem 60 minuten; wij vernieuwen na 50.
export function apnsJwt(key: CryptoKey, keyId: string, teamId: string, nowS = Math.floor(Date.now() / 1000)) {
  return signJwt({ alg: "ES256", kid: keyId }, { iss: teamId, iat: nowS }, key);
}

// Google OAuth2 (serviceaccount, RFC 7523): bewering voor https://oauth2.googleapis.com/token.
export function googleAssertion(key: CryptoKey, clientEmail: string, keyId: string | undefined, nowS = Math.floor(Date.now() / 1000)) {
  const header: Record<string, unknown> = { alg: "RS256", typ: "JWT" };
  if (keyId) header.kid = keyId;
  return signJwt(header, {
    iss: clientEmail, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: nowS, exp: nowS + 3600,
  }, key);
}

// VAPID-sleutel: privé als base64url d (32 bytes), publiek als base64url ongecomprimeerd punt (65 bytes, 0x04||x||y).
export function importVapidPrivate(privB64u: string, pubB64u: string): Promise<CryptoKey> {
  const pub = unb64u(pubB64u), d = unb64u(privB64u);
  if (pub.length !== 65 || pub[0] !== 4 || d.length !== 32) throw new Error("bad_vapid_key");
  return crypto.subtle.importKey("jwk", {
    kty: "EC", crv: "P-256", d: b64u(d), x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33, 65)), ext: true,
  }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

// VAPID (RFC 8292): Authorization: vapid t=<jwt>, k=<publieke sleutel>. aud = origin van het abonnement-endpoint.
export async function vapidAuthorization(endpoint: string, key: CryptoKey, pubB64u: string, subject: string, nowS = Math.floor(Date.now() / 1000)) {
  const aud = new URL(endpoint).origin;
  const jwt = await signJwt({ typ: "JWT", alg: "ES256" }, { aud, exp: nowS + 12 * 3600, sub: subject }, key);
  return `vapid t=${jwt}, k=${pubB64u}`;
}

async function hmac(key: Bytes, data: Bytes): Promise<Bytes> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}
// HKDF (RFC 5869) met één blok uitvoer (<= 32 bytes), zoals RFC 8291 het beschrijft.
async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, len: number): Promise<Bytes> {
  const prk = await hmac(salt, ikm);
  return (await hmac(prk, concat(info, new Uint8Array([1])))).subarray(0, len);
}

export type WebPushOpts = { asKeys?: CryptoKeyPair; salt?: Bytes; rs?: number };

// RFC 8291: versleutel `plaintext` voor een abonnement (p256dh = publieke sleutel van de browser, 65 bytes; auth = 16 bytes).
// Eén record (aes128gcm): header salt(16) || rs(4) || idlen(1)=65 || as_public(65), dan ciphertext van plaintext||0x02.
// asKeys/salt alleen voor tests (testvector uit RFC 8291 bijlage A); anders elke keer nieuw en willekeurig.
export async function encryptWebPush(plaintext: Bytes, p256dh: Bytes, auth: Bytes, opts: WebPushOpts = {}): Promise<Bytes> {
  if (p256dh.length !== 65 || p256dh[0] !== 4) throw new Error("bad_p256dh");
  if (auth.length !== 16) throw new Error("bad_auth");
  const rs = opts.rs ?? 4096;
  if (plaintext.length + 1 + 16 > rs) throw new Error("payload_too_large");
  const as = opts.asKeys ?? await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", p256dh, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  // IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0x00 || ua_public || as_public, 32)
  const keyInfo = concat(te.encode("WebPush: info\0"), p256dh, asPublic);
  const ikm = await hkdf(auth, ecdh, keyInfo, 32);
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  // laatste (en enige) record: scheidingsteken 0x02, geen extra opvulling
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, concat(plaintext, new Uint8Array([2]))));
  const header = new Uint8Array(21);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, rs);
  header[20] = asPublic.length;
  return concat(header, asPublic, ct);
}

// Nieuw VAPID-sleutelpaar (voor de Backend-workflow): {privateKey, publicKey} als base64url.
export async function generateVapidKeys() {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return { privateKey: jwk.d as string, publicKey: b64u(pub) };
}

// Geheimen vergelijken in constante tijd (lengte telt mee, maar lekt niets over de inhoud).
export function sameSecret(given: string | null, expected: string | undefined): boolean {
  if (!given || !expected || expected.length < 16) return false;
  const a = te.encode(given), b = te.encode(expected);
  let d = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) d |= (a[i % (a.length || 1)] ?? 0) ^ b[i];
  return d === 0;
}
