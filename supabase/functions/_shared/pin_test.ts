// Tests voor de pincode-hash (build 146): deno test supabase/functions/_shared/pin_test.ts
// De testvectoren staan ook in docs/ACCOUNT.md ("Build 146" → "Pincode als hash") en zijn nagerekend met Python
// (hashlib.pbkdf2_hmac('sha256', pin, salt, 100000, 32)).
import {
  b64decode, b64encode, makePinHash, normalizePinSection, parsePinHash, pbkdf2, pbkdf2Js, PIN_ITER, validPin, verifyPin,
} from "./pin.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }

export const VECTORS = [
  { pin: "1234", salt: "AAECAwQFBgcICQoLDA0ODw==", hash: "hp5sg1DFvrCsw5n7qsO2DSIEM4lrJqZHc00NjxWG4fo=" },
  { pin: "0000", salt: "QmluZ3ItcGluLXRlc3QtMQ==", hash: "+fGTeA7fJpt28Rrq3DjQxUFemZFqDW4eAb85/ZRYHg8=" },
  { pin: "98765432", salt: "//79/Pv6+fj39vX08/Lx8A==", hash: "ZPbmm6a1FOjvmJWC0XNDHIDHyxK4739iaGZkx4Oid7c=" },
];

Deno.test("testvectoren: WebCrypto en pure JS geven dezelfde hash", async () => {
  eq(PIN_ITER, 100000, "iteraties");
  for (const v of VECTORS) {
    const salt = b64decode(v.salt)!;
    eq(b64encode(await pbkdf2(v.pin, salt, PIN_ITER)), v.hash, `WebCrypto ${v.pin}`);
    eq(b64encode(pbkdf2Js(v.pin, salt, PIN_ITER)), v.hash, `pure JS ${v.pin}`);
    ok(await verifyPin(v.pin, { alg: "pbkdf2-sha256", iter: 100000, salt: v.salt, hash: v.hash }), `verify ${v.pin}`);
  }
  // kleine aantallen (randgevallen van de lus)
  const s = b64decode(VECTORS[0].salt)!;
  eq(b64encode(pbkdf2Js("1234", s, 1)), "i/F57D1qcIBBiv5AzlKB8LqqXqCNwubIJuZH8P6K1uI=", "1 iteratie");
  eq(b64encode(pbkdf2Js("1234", s, 2)), "oNCs4eO5peWpZXM8MGUdRebd/Uv8TI0RC7CQ7Ngh0N4=", "2 iteraties");
});

Deno.test("verkeerde pincode, voorloopnullen en ongeldige objecten", async () => {
  const v = VECTORS[0], h = { alg: "pbkdf2-sha256", iter: 100000, salt: v.salt, hash: v.hash };
  ok(!(await verifyPin("1235", h)), "andere pin");
  ok(!(await verifyPin("01234", h)), "extra voorloopnul");
  ok(!(await verifyPin("12a4", h)), "geen cijfers");
  ok(!(await verifyPin("1234", { ...h, alg: "sha256" })), "ander alg");
  ok(!(await verifyPin("1234", { ...h, iter: 1000 })), "te weinig iteraties");
  ok(!(await verifyPin("1234", { ...h, hash: "AAAA" })), "hash te kort");
  ok(!(await verifyPin("1234", null)), "null");
  ok(validPin("0000") && validPin("12345678") && !validPin("123") && !validPin("123456789") && !validPin(1234), "validPin");
  eq(parsePinHash({ ...h, extra: 1 }), h, "extra velden genegeerd");
});

Deno.test("makePinHash: eigen salt per keer, formaat exact", async () => {
  const a = await makePinHash("4321"), b = await makePinHash("4321");
  eq(Object.keys(a), ["alg", "iter", "salt", "hash"]);
  eq(a.alg, "pbkdf2-sha256"); eq(a.iter, 100000);
  eq(b64decode(a.salt)!.length, 16); eq(b64decode(a.hash)!.length, 32);
  ok(a.salt !== b.salt && a.hash !== b.hash, "nieuwe salt");
  ok(await verifyPin("4321", a) && await verifyPin("4321", b), "beide kloppen");
  const fixed = await makePinHash("1234", b64decode(VECTORS[0].salt)!);
  eq(fixed.hash, VECTORS[0].hash, "vaste salt = testvector");
});

// snelle nep-hash voor de regels (de echte afleiding is hierboven getest)
const fake = async (pin: string) => ({ alg: "pbkdf2-sha256" as const, iter: 100000, salt: "AAECAwQFBgcICQoLDA0ODw==", hash: b64encode(new Uint8Array(32).fill(Number(pin[0]))) });
const H = { alg: "pbkdf2-sha256", iter: 100000, salt: VECTORS[0].salt, hash: VECTORS[0].hash };

Deno.test("server: alleen oude apps (geen pinHash) = oud gedrag", async () => {
  const r = await normalizePinSection({ pin: "1111", pinUpdatedAt: "2026-01-01T00:00:00Z" }, { pin: "2222", pinUpdatedAt: "2026-02-01T00:00:00Z", myList: [] }, fake);
  ok(!("error" in r) && !r.changed, "niet veranderd");
  if (!("error" in r)) eq(r.data.pin, "2222");
});

Deno.test("server: nieuwe app met pinHash -> pin altijd null", async () => {
  const r = await normalizePinSection({}, { pin: "1234", pinHash: H, pinUpdatedAt: "2026-03-01T00:00:00Z" }, fake);
  if ("error" in r) throw new Error(r.error);
  eq(r.data.pin, null); eq(r.data.pinHash, H); ok(r.changed);
  const bad = await normalizePinSection({}, { pinHash: { alg: "md5" } }, fake);
  ok("error" in bad && bad.error === "bad_pin_hash", "ongeldig");
  const removed = await normalizePinSection({ pinHash: H }, { pinHash: null, pin: null, pinUpdatedAt: "2026-04-01T00:00:00Z" }, fake);
  if ("error" in removed) throw new Error(removed.error);
  eq(removed.data.pinHash, null); eq(removed.data.pin, null);
  const viaPin = await normalizePinSection({}, { pinHash: null, pin: "5678" }, fake);
  if ("error" in viaPin) throw new Error(viaPin.error);
  eq(viaPin.data.pin, null); eq((viaPin.data.pinHash as { hash: string }).hash, (await fake("5678")).hash, "toch gehasht");
});

Deno.test("server: oude app zonder pinHash-sleutel kan de hash niet wissen", async () => {
  const stored = { pinHash: H, pin: null, pinUpdatedAt: "2026-03-01T00:00:00Z" };
  // oude app stuurt zijn oude lokale pincode (ouder) of null zonder nieuwere tijd: hash blijft
  for (const pin of ["9999", null]) {
    const r = await normalizePinSection(stored, { pin, pinUpdatedAt: "2026-02-01T00:00:00Z", myList: [1] }, fake);
    if ("error" in r) throw new Error(r.error);
    eq(r.data.pinHash, H, `hash blijft (${pin})`); eq(r.data.pin, null); eq(r.data.pinUpdatedAt, stored.pinUpdatedAt); eq(r.data.myList, [1]);
  }
  // geen pin-velden: hash blijft
  const none = await normalizePinSection(stored, { myList: [] }, fake);
  if ("error" in none) throw new Error(none.error);
  eq(none.data.pinHash, H); eq(none.data.pin, null);
  // oude app zet een NIEUWE pincode (nieuwere tijd): de server hasht hem
  const set = await normalizePinSection(stored, { pin: "4444", pinUpdatedAt: "2026-05-01T00:00:00Z" }, fake);
  if ("error" in set) throw new Error(set.error);
  eq(set.data.pin, null); eq((set.data.pinHash as { hash: string }).hash, (await fake("4444")).hash);
  // oude app verwijdert de pincode (null, nieuwere tijd)
  const del = await normalizePinSection(stored, { pin: null, pinUpdatedAt: "2026-05-01T00:00:00Z" }, fake);
  if ("error" in del) throw new Error(del.error);
  eq(del.data.pinHash, null); eq(del.data.pin, null);
});
