// Build 167: JWS van Apple controleren (StoreKit 2 `Transaction.jwsRepresentation` en App Store Server Notifications V2
// `signedPayload`). Contract in docs/ACCOUNT.md, "Build 167: alleen Lifetime" → "Apple-aankoop verwerken".
// Pure WebCrypto, geen afhankelijkheden en geen netwerk (getest in apple_test.ts met een zelfgemaakte test-CA):
//   1. JWS = header.payload.handtekening (base64url); header {alg:"ES256", x5c:[leaf, tussen, root]} (DER in base64).
//   2. Keten: de root in x5c moet byte voor byte gelijk zijn aan een vertrouwde root (standaard Apple Root CA - G3, zie
//      apple_root.ts); het tussencertificaat is ondertekend door die root, de leaf door het tussencertificaat (ECDSA met
//      SHA-256 of SHA-384, P-256 of P-384), uitgever = onderwerp van de ouder, alle drie geldig op het moment van
//      ondertekenen (`signedDate` uit de payload, niet in de toekomst; anders nu), tussencertificaat is een CA met de
//      Apple-markering 1.2.840.113635.100.6.2.1, leaf is geen CA, heeft 1.2.840.113635.100.6.11.1 en een P-256-sleutel.
//      Onbekende kritieke extensies = geweigerd.
//   3. Handtekening ES256 (P-256, SHA-256, r||s van 64 bytes) over "header.payload" met de sleutel van de leaf.
// Geen OCSP/CRL (online intrekking): Apple's eigen bibliotheek doet dat ook alleen optioneel.

import { APPLE_ROOT_CA_G3_B64 } from "./apple_root.ts";

export const OID_APPLE_LEAF = "1.2.840.113635.100.6.11.1";
export const OID_APPLE_INTERMEDIATE = "1.2.840.113635.100.6.2.1";
const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";
const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_KEY_USAGE = "2.5.29.15";
const KNOWN_CRITICAL = new Set([OID_BASIC_CONSTRAINTS, OID_KEY_USAGE]);
/** Klokverschil dat we toestaan voor `signedDate` in de toekomst. */
export const FUTURE_SKEW_MS = 5 * 60_000;
/** Max. lengte van een JWS (Apple's zijn ±3–5 KB; een notificatie met transactie erin ±10 KB). */
export const MAX_JWS = 64 * 1024;

export type JwsError =
  | "bad_format" | "bad_header" | "bad_alg" | "bad_chain" | "untrusted_root" | "cert_expired" | "not_apple"
  | "bad_signature" | "bad_payload" | "future_date";
// deno-lint-ignore no-explicit-any
export type JwsResult = { ok: true; payload: Record<string, any>; header: Record<string, unknown> } | { ok: false; error: JwsError };

// ---------------- base64 ----------------
export function b64decode(s: string): Uint8Array {
  const clean = s.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(clean)) throw new Error("base64");
  const pad = clean + "===".slice((clean.length + 3) % 4);
  const bin = atob(pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function b64urlEncode(b: Uint8Array | string): string {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : b;
  let s = "";
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const sameBytes = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);

// ---------------- DER (alleen wat X.509 nodig heeft) ----------------
type Node = { tag: number; start: number; body: number; end: number };
function node(b: Uint8Array, off: number, limit = b.length): Node {
  if (off + 2 > limit) throw new Error("der");
  const tag = b[off];
  if ((tag & 0x1f) === 0x1f) throw new Error("der"); // lange tags komen in X.509 niet voor
  let len = b[off + 1], p = off + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || p + n > limit) throw new Error("der");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[p + i];
    p += n;
  }
  if (p + len > limit) throw new Error("der");
  return { tag, start: off, body: p, end: p + len };
}
function kids(b: Uint8Array, n: Node): Node[] {
  const out: Node[] = [];
  for (let p = n.body; p < n.end;) { const c = node(b, p, n.end); out.push(c); p = c.end; }
  return out;
}
const bytesOf = (b: Uint8Array, n: Node) => b.subarray(n.start, n.end);
const bodyOf = (b: Uint8Array, n: Node) => b.subarray(n.body, n.end);
function oid(b: Uint8Array, n: Node): string {
  if (n.tag !== 0x06) throw new Error("der");
  const v = bodyOf(b, n);
  if (!v.length) throw new Error("der");
  const parts: number[] = [Math.floor(v[0] / 40), v[0] % 40];
  let x = 0;
  for (let i = 1; i < v.length; i++) {
    x = x * 128 + (v[i] & 0x7f);
    if (!(v[i] & 0x80)) { parts.push(x); x = 0; }
  }
  return parts.join(".");
}
function time(b: Uint8Array, n: Node): number {
  const s = new TextDecoder().decode(bodyOf(b, n));
  let m: RegExpMatchArray | null;
  if (n.tag === 0x17 && (m = s.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    const y = Number(m[1]);
    return Date.UTC(y >= 50 ? 1900 + y : 2000 + y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
  }
  if (n.tag === 0x18 && (m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
  }
  throw new Error("der");
}

export type Cert = {
  der: Uint8Array; tbs: Uint8Array; sigAlg: string; sig: Uint8Array; issuer: Uint8Array; subject: Uint8Array;
  notBefore: number; notAfter: number; spki: Uint8Array; curve: "P-256" | "P-384" | null; isCA: boolean; extensions: Set<string>;
  unknownCritical: boolean;
};
/** Leest een X.509-certificaat (DER). Gooit bij een kapotte opbouw. */
export function parseCert(der: Uint8Array): Cert {
  const top = node(der, 0);
  if (top.tag !== 0x30 || top.end !== der.length) throw new Error("der");
  const [tbsN, algN, sigN] = kids(der, top);
  if (!tbsN || !algN || !sigN || tbsN.tag !== 0x30 || algN.tag !== 0x30 || sigN.tag !== 0x03) throw new Error("der");
  const sigAlg = oid(der, kids(der, algN)[0]);
  const sigBits = bodyOf(der, sigN);
  if (sigBits[0] !== 0) throw new Error("der");
  const t = kids(der, tbsN);
  let i = 0;
  if (t[i]?.tag === 0xa0) i++; // versie
  i++; // serienummer
  const innerAlg = oid(der, kids(der, t[i++])[0]);
  if (innerAlg !== sigAlg) throw new Error("der");
  const issuer = bytesOf(der, t[i++]);
  const validity = kids(der, t[i++]);
  const subject = bytesOf(der, t[i++]);
  const spkiN = t[i++];
  if (!spkiN || spkiN.tag !== 0x30 || validity.length !== 2) throw new Error("der");
  const [keyAlg] = kids(der, spkiN);
  const ka = kids(der, keyAlg);
  const curveOid = ka[0] && oid(der, ka[0]) === OID_EC_PUBLIC_KEY && ka[1]?.tag === 0x06 ? oid(der, ka[1]) : "";
  const extensions = new Set<string>();
  let isCA = false, unknownCritical = false;
  for (; i < t.length; i++) {
    if (t[i].tag !== 0xa3) continue;
    const seq = kids(der, t[i])[0];
    for (const e of kids(der, seq)) {
      const f = kids(der, e);
      const id = oid(der, f[0]);
      const critical = f.length === 3 && f[1].tag === 0x01 && der[f[1].body] !== 0;
      const val = f[f.length - 1];
      extensions.add(id);
      if (critical && !KNOWN_CRITICAL.has(id)) unknownCritical = true;
      if (id === OID_BASIC_CONSTRAINTS && val.tag === 0x04) {
        const bc = node(der, val.body, val.end);
        const first = kids(der, bc)[0];
        isCA = !!first && first.tag === 0x01 && der[first.body] !== 0;
      }
    }
  }
  return {
    der, tbs: bytesOf(der, tbsN), sigAlg, sig: sigBits.subarray(1), issuer, subject,
    notBefore: time(der, validity[0]), notAfter: time(der, validity[1]), spki: bytesOf(der, spkiN),
    curve: curveOid === OID_P256 ? "P-256" : curveOid === OID_P384 ? "P-384" : null, isCA, extensions, unknownCritical,
  };
}

/** ECDSA-handtekening uit DER (SEQUENCE {r, s}) naar r||s van vaste lengte (WebCrypto-vorm). */
export function derSigToRaw(sig: Uint8Array, size: number): Uint8Array {
  const top = node(sig, 0);
  if (top.tag !== 0x30 || top.end !== sig.length) throw new Error("der");
  const [r, s] = kids(sig, top);
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new Error("der");
  const out = new Uint8Array(size * 2);
  for (const [j, n] of [[0, r], [1, s]] as const) {
    let v = bodyOf(sig, n);
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new Error("der");
    out.set(v, j * size + size - v.length);
  }
  return out;
}

async function keyOf(c: Cert): Promise<CryptoKey> {
  if (!c.curve) throw new Error("curve");
  return await crypto.subtle.importKey("spki", c.spki as BufferSource, { name: "ECDSA", namedCurve: c.curve }, false, ["verify"]);
}
/** Is `child` ondertekend door `parent`? */
export async function signedBy(child: Cert, parent: Cert): Promise<boolean> {
  const hash = child.sigAlg === OID_ECDSA_SHA256 ? "SHA-256" : child.sigAlg === OID_ECDSA_SHA384 ? "SHA-384" : null;
  if (!hash || !parent.curve || !sameBytes(child.issuer, parent.subject)) return false;
  try {
    const raw = derSigToRaw(child.sig, parent.curve === "P-256" ? 32 : 48);
    return await crypto.subtle.verify({ name: "ECDSA", hash }, await keyOf(parent), raw as BufferSource, child.tbs as BufferSource);
  } catch { return false; }
}

const defaultRoots = () => [b64decode(APPLE_ROOT_CA_G3_B64)];
const validAt = (c: Cert, t: number) => t >= c.notBefore && t <= c.notAfter;

/**
 * Controleert een JWS van Apple. opts.roots: vertrouwde roots (DER; standaard Apple Root CA - G3, alleen tests geven
 * een eigen test-CA mee). opts.now: huidige tijd in ms.
 */
export async function verifyAppleJws(jws: unknown, opts: { roots?: Uint8Array[]; now?: number } = {}): Promise<JwsResult> {
  const now = opts.now ?? Date.now();
  if (typeof jws !== "string" || jws.length > MAX_JWS) return { ok: false, error: "bad_format" };
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((p) => !/^[A-Za-z0-9_-]+$/.test(p))) return { ok: false, error: "bad_format" };
  let header: Record<string, unknown>, payload: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64decode(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64decode(parts[1])));
  } catch { return { ok: false, error: "bad_format" }; }
  if (!header || typeof header !== "object" || Array.isArray(header)) return { ok: false, error: "bad_header" };
  if (header.alg !== "ES256") return { ok: false, error: "bad_alg" };
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string" && c.length < 8192)) return { ok: false, error: "bad_header" };
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return { ok: false, error: "bad_payload" };

  let leaf: Cert, inter: Cert, root: Cert;
  try { [leaf, inter, root] = (x5c as string[]).map((c) => parseCert(b64decode(c))); } catch { return { ok: false, error: "bad_chain" }; }
  const roots = opts.roots ?? defaultRoots();
  if (!roots.some((r) => sameBytes(r, root.der))) return { ok: false, error: "untrusted_root" };
  // moment van ondertekenen (ms); later dan nu (+ klokverschil) = vervalst of kapot
  const sd = Number(payload.signedDate);
  const at = Number.isFinite(sd) && sd > 0 ? sd : now;
  if (at > now + FUTURE_SKEW_MS) return { ok: false, error: "future_date" };
  if (![leaf, inter, root].every((c) => validAt(c, at))) return { ok: false, error: "cert_expired" };
  if ([leaf, inter, root].some((c) => c.unknownCritical)) return { ok: false, error: "bad_chain" };
  if (!root.isCA || !inter.isCA || leaf.isCA) return { ok: false, error: "bad_chain" };
  if (!inter.extensions.has(OID_APPLE_INTERMEDIATE) || !leaf.extensions.has(OID_APPLE_LEAF)) return { ok: false, error: "not_apple" };
  if (leaf.curve !== "P-256") return { ok: false, error: "bad_chain" };
  if (!(await signedBy(inter, root)) || !(await signedBy(leaf, inter))) return { ok: false, error: "bad_chain" };

  let sig: Uint8Array;
  try { sig = b64decode(parts[2]); } catch { return { ok: false, error: "bad_format" }; }
  if (sig.length !== 64) return { ok: false, error: "bad_signature" };
  try {
    const okSig = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, await keyOf(leaf), sig as BufferSource,
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`) as BufferSource);
    if (!okSig) return { ok: false, error: "bad_signature" };
  } catch { return { ok: false, error: "bad_signature" }; }
  return { ok: true, payload, header };
}
