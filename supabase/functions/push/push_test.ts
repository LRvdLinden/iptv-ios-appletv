// Unittests voor de functie push: deno test supabase/functions/push/push_test.ts
// Zonder netwerk: de pushdiensten worden nagebootst met een eigen fetch.
import {
  apnsJwt, b64u, type Bytes, concat, encryptWebPush, generateVapidKeys, googleAssertion, importEs256Pkcs8, importRs256Pkcs8, importVapidPrivate,
  sameSecret, unb64u, vapidAuthorization,
} from "./crypto.ts";
import {
  apnsOutcome, apnsPayload, checkRegister, checkTarget, fcmMessage, fcmOutcome, normLang, parseReminders, releaseKey, releaseText,
  reminderBody, reminderDue, reminderKey, reminderProfile, renderNotice, ttlFor, webPayload, webpushHostAllowed, webpushOutcome,
  supportKey, supportLinks, supportText, reminderDeadline, reminderDueFor, sportLead, sportReminderText,
  releaseReminderText, titleLinks, RELEASE_WINDOW_MS,
} from "./logic.ts";
import { Apns, apnsIat, apnsTokenUsable, Channels, type TokenStore } from "./channels.ts";
import { openJsonField, seal, sealJsonField, unseal } from "../_shared/sealed.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }
const te = new TextEncoder(), td = new TextDecoder();

async function pkcs8Pem(key: CryptoKey) {
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", key));
  return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
}
function decodeJwt(jwt: string) {
  const [h, c, s] = jwt.split(".");
  return { header: JSON.parse(td.decode(unb64u(h))), claims: JSON.parse(td.decode(unb64u(c))), sig: unb64u(s), input: te.encode(`${h}.${c}`) };
}

// ---------- RFC 8291 bijlage A ----------
const RFC = {
  plaintext: "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24",
  asPublic: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
  asPrivate: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
  uaPublic: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
  uaPrivate: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
  salt: "DGv6ra1nlYgDCS1FRnbzlw",
  auth: "BTBZMqHH6r4Tts7J_aSIgg",
  // header (salt, rs = 4096, idlen 65, as_public) gevolgd door de ciphertext
  message: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
};
async function ecdhPair(pub64: string, priv64: string): Promise<CryptoKeyPair> {
  const pub = unb64u(pub64);
  const jwk = { kty: "EC", crv: "P-256", d: priv64, x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33)) };
  return {
    privateKey: await crypto.subtle.importKey("jwk", jwk, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]),
    publicKey: await crypto.subtle.importKey("raw", pub, { name: "ECDH", namedCurve: "P-256" }, true, []),
  };
}
// Ontsleutelen zoals de browser het doet (alleen voor de test), om ook willekeurige versleutelingen te controleren.
async function decryptWebPush(body: Bytes, ua: CryptoKeyPair, uaPublic: Bytes, auth: Bytes) {
  const hmac = async (k: Bytes, d: Bytes) =>
    new Uint8Array(await crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", k, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), d));
  const hkdf = async (salt: Bytes, ikm: Bytes, info: Bytes, n: number) => (await hmac(await hmac(salt, ikm), concat(info, new Uint8Array([1])))).subarray(0, n);
  const salt = body.subarray(0, 16), idlen = body[20], asPublic = body.subarray(21, 21 + idlen), ct = body.subarray(21 + idlen);
  const asKey = await crypto.subtle.importKey("raw", asPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: asKey }, ua.privateKey, 256));
  const ikm = await hkdf(auth, ecdh, concat(te.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const pt = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]), ct));
  ok(pt[pt.length - 1] === 2, "laatste record eindigt op 0x02");
  return pt.subarray(0, pt.length - 1);
}

Deno.test("Web Push: testvector RFC 8291 bijlage A", async () => {
  const out = await encryptWebPush(unb64u(RFC.plaintext), unb64u(RFC.uaPublic), unb64u(RFC.auth),
    { asKeys: await ecdhPair(RFC.asPublic, RFC.asPrivate), salt: unb64u(RFC.salt) });
  eq(b64u(out), RFC.message, "aes128gcm-bericht");
});
Deno.test("Web Push: RFC-bericht ontsleutelt naar de tekst", async () => {
  const pt = await decryptWebPush(unb64u(RFC.message), await ecdhPair(RFC.uaPublic, RFC.uaPrivate), unb64u(RFC.uaPublic), unb64u(RFC.auth));
  eq(td.decode(pt), "When I grow up, I want to be a watermelon");
});
Deno.test("Web Push: willekeurige sleutel en salt, rondgang", async () => {
  const ua = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const uaPublic = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  const auth = crypto.getRandomValues(new Uint8Array(16));
  const msg = te.encode(JSON.stringify({ title: "Hallo", body: "Wereld ✓", data: { kind: "admin", msg_id: "7" } }));
  const a = await encryptWebPush(msg, uaPublic, auth), b = await encryptWebPush(msg, uaPublic, auth);
  ok(b64u(a) !== b64u(b), "elke versleuteling is anders");
  eq(new DataView(a.buffer).getUint32(16), 4096, "rs");
  eq(td.decode(await decryptWebPush(a, ua, uaPublic, auth)), td.decode(msg));
  let threw = false;
  try { await encryptWebPush(new Uint8Array(5000), uaPublic, auth); } catch { threw = true; }
  ok(threw, "te groot bericht geweigerd");
});

// ---------- JWT ----------
Deno.test("APNs-JWT: ES256 met kid/iss/iat en geldige handtekening", async () => {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pem = await pkcs8Pem(kp.privateKey);
  const jwt = await apnsJwt(await importEs256Pkcs8(pem.replace(/\n/g, "\\n")), "ABC123DEFG", "EU3UY476T6", 1700000000);
  const j = decodeJwt(jwt);
  eq(j.header, { alg: "ES256", kid: "ABC123DEFG" });
  eq(j.claims, { iss: "EU3UY476T6", iat: 1700000000 });
  eq(j.sig.length, 64, "r||s");
  ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, kp.publicKey, j.sig, j.input), "handtekening");
});
Deno.test("Google-bewering: RS256 voor oauth2.googleapis.com", async () => {
  const kp = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const jwt = await googleAssertion(await importRs256Pkcs8(await pkcs8Pem(kp.privateKey)), "sa@p.iam.gserviceaccount.com", "kid1", 1000);
  const j = decodeJwt(jwt);
  eq(j.header, { alg: "RS256", typ: "JWT", kid: "kid1" });
  eq(j.claims.aud, "https://oauth2.googleapis.com/token");
  eq(j.claims.scope, "https://www.googleapis.com/auth/firebase.messaging");
  eq([j.claims.iat, j.claims.exp], [1000, 4600]);
  ok(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", kp.publicKey, j.sig, j.input), "handtekening");
});
Deno.test("VAPID: header met t= en k=, aud = origin van het endpoint", async () => {
  const keys = await generateVapidKeys();
  eq(unb64u(keys.publicKey).length, 65);
  eq(unb64u(keys.privateKey).length, 32);
  const h = await vapidAuthorization("https://fcm.googleapis.com/fcm/send/abc?x=1", await importVapidPrivate(keys.privateKey, keys.publicKey),
    keys.publicKey, "mailto:support@bingr.online", 2000);
  const m = /^vapid t=([^,]+), k=(.+)$/.exec(h);
  ok(m, "formaat");
  eq(m![2], keys.publicKey);
  const j = decodeJwt(m![1]);
  eq(j.claims, { aud: "https://fcm.googleapis.com", exp: 2000 + 43200, sub: "mailto:support@bingr.online" });
  const pub = await crypto.subtle.importKey("raw", unb64u(keys.publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, j.sig, j.input), "handtekening");
});
Deno.test("geheimen vergelijken", () => {
  const s = "a".repeat(32);
  ok(sameSecret(s, s));
  ok(!sameSecret(s + "b", s));
  ok(!sameSecret("b" + s.slice(1), s));
  ok(!sameSecret(null, s));
  ok(!sameSecret("", ""), "leeg geheim nooit goed");
  ok(!sameSecret("kort", "kort"), "te kort geheim geweigerd");
});

// ---------- teksten en taal ----------
Deno.test("taal: normaliseren en terugvallen op en", () => {
  eq(["nl", "NL-be", "en_GB", "de", "zh", "zh-Hant", "zh-Hans", "pt-BR", "ar", "ja", "", null].map(normLang),
    ["nl", "nl", "en", "de", "zh-Hans", "zh-Hans", "zh-Hans", "pt", "ar", "en", "en", "en"]);
});
Deno.test("releasetekst per taal (contract)", () => {
  eq(releaseText("nl", "1.0.0", 105, "ios"), { title: "Bingr 1.0.0 (Build 105) is beschikbaar", body: "Nieuw voor iPhone. Tik om de wijzigingen te bekijken." });
  eq(releaseText("en", "1.0.0", 105, "macos"), { title: "Bingr 1.0.0 (Build 105) is available", body: "New for Mac. Tap to see what's changed." });
  eq(releaseText("ja", "1.0.0", 105, "android"), releaseText("en", "1.0.0", 105, "android"), "fallback en");
  for (const l of ["de", "fr", "es", "it", "pt", "tr", "pl", "ar", "zh-Hans"]) {
    const t = releaseText(l, "1.0.0", 105, "ipados");
    ok(t.title.includes("105") && t.body.includes("iPad") && t.title !== releaseText("en", "1.0.0", 105, "ipados").title, `vertaling ${l}`);
  }
});
Deno.test("herinnering: tekst met profiel en tijd in de tijdzone van het apparaat", () => {
  const start = Date.parse("2026-10-16T18:30:00Z");
  eq(reminderBody("nl", { profileName: "Emma", title: "Journaal", startMs: start }, "Europe/Amsterdam"), "Voor Emma: Journaal begint om 20:30");
  eq(reminderBody("en", { profileName: null, title: "News", startMs: start }, "Europe/London"), "News starts at 19:30");
  eq(reminderBody("de", { profileName: null, title: "X", startMs: start }, "Ongeldig/Zone"), "X beginnt um 20:30", "standaard Europe/Amsterdam");
});

// ---------- payloads ----------
Deno.test("payloads per kanaal", () => {
  const n = renderNotice({ id: 42, kind: "release", payload: { version: "1.0.0", build: 105 } }, { platform: "ios", lang: "nl" });
  eq(n.data, { kind: "release", msg_id: "42", url: "https://apps.apple.com/nl/app/bingr/id6821401598" });
  eq(renderNotice({ id: 43, kind: "release", payload: { version: "1.0.0", build: 105 } }, { platform: "android", lang: "nl" }).data,
    { kind: "release", msg_id: "43", url: "https://bingr.online/downloads" });
  eq(renderNotice({ id: 44, kind: "release", payload: { version: "1.0.0", build: 105 } }, { platform: "web", lang: "nl" }).data,
    { kind: "release", msg_id: "44", url: "https://bingr.online/changelog/?p=web#build-105", deeplink: "bingr://changelog?p=web&b=105" });
  const ap = apnsPayload(n) as Record<string, unknown> & ReturnType<typeof apnsPayload>;
  eq(ap.aps, { alert: { title: n.title, body: n.body }, sound: "default", "thread-id": "release" });
  eq(ap.data, n.data);
  eq([ap.kind, ap.msg_id, ap.url], ["release", "42", n.data.url], "ook plat naast aps");
  const f = fcmMessage("tok", n, 600);
  ok(!("notification" in f.message), "FCM data-only");
  eq(f.message.data, { title: n.title, body: n.body, ...n.data });
  ok(Object.values(f.message.data).every((v) => typeof v === "string"), "FCM-data alleen strings");
  eq(f.message.android.priority, "high");
  eq(f.message.android.ttl, "600s");
  eq(webPayload(n), { title: n.title, body: n.body, data: n.data });
  const a = renderNotice({ id: 7, kind: "admin", title_nl: "Hoi", body_nl: "Tekst", title_en: "Hi", body_en: "Text", url: null }, { platform: "web", lang: "de" });
  eq([a.title, a.body, a.data], ["Hi", "Text", { kind: "admin", msg_id: "7" }], "admin zonder link: geen url");
  const a2 = renderNotice({ id: 8, kind: "admin", title_nl: "Hoi", body_nl: "Tekst", url: "https://bingr.online/x" }, { platform: "android", lang: "en" });
  eq([a2.title, a2.data.url], ["Hoi", "https://bingr.online/x"], "zonder Engels: Nederlands");
  const start = Date.now() + 120_000;
  const r = renderNotice({ id: 9, kind: "reminder", payload: { title: "Journaal", channel_id: "npo 1", channel_name: "NPO 1", profile_id: "abc", profile_name: "Emma", start_ms: start } },
    { platform: "android", lang: "nl", tz: "Europe/Amsterdam" });
  eq(r.title, "NPO 1");
  ok(r.body.startsWith("Voor Emma: Journaal begint om "));
  eq(r.data.deeplink, "bingr://live?channel=npo%201&profile=abc");
  eq(r.data.url, "https://bingr.online/web/#/live?channel=npo%201&profile=abc");
  ok(ttlFor({ id: 9, kind: "reminder", payload: { start_ms: start } }, Date.now()) <= 120);
});

// ---------- registratie ----------
const sub = (endpoint: string) => JSON.stringify({ endpoint, keys: { p256dh: RFC.uaPublic, auth: RFC.auth } });
Deno.test("register: controle per platform en kanaal", () => {
  const base = { device_id: "D1", lang: "nl-NL", app_version: "1.0.0", app_build: "105" };
  const r = checkRegister({ ...base, platform: "ios", channel: "apns", token: "AB".repeat(32), sandbox: true, tz: "Europe/Amsterdam" });
  ok(!("error" in r));
  if (!("error" in r)) eq([r.token, r.lang, r.app_build, r.sandbox, r.tz], ["ab".repeat(32), "nl", 105, true, "Europe/Amsterdam"]);
  eq(checkRegister({ ...base, platform: "tvos", channel: "apns", token: "ab".repeat(32) }), { error: "no_push_platform" });
  eq(checkRegister({ ...base, platform: "androidtv", channel: "fcm", token: "x".repeat(40) }), { error: "no_push_platform" });
  eq(checkRegister({ ...base, platform: "ios", channel: "fcm", token: "x".repeat(40) }), { error: "bad_channel" });
  eq(checkRegister({ ...base, platform: "ios", channel: "apns", token: "nothex" }), { error: "bad_token" });
  const w = checkRegister({ ...base, platform: "web", channel: "webpush", token: sub("https://fcm.googleapis.com/fcm/send/abc"), sandbox: true });
  ok(!("error" in w) && w.sandbox === false, "sandbox alleen voor APNs");
  eq(checkRegister({ ...base, platform: "web", channel: "webpush", token: sub("https://169.254.169.254/latest") }), { error: "bad_token" });
  eq(checkRegister({ ...base, platform: "web", channel: "webpush", token: "{" }), { error: "bad_token" });
});
Deno.test("Web Push: alleen bekende pushdiensten (geen SSRF)", () => {
  ok(webpushHostAllowed("https://fcm.googleapis.com/fcm/send/x"));
  ok(webpushHostAllowed("https://updates.push.services.mozilla.com/wpush/v2/x"));
  ok(webpushHostAllowed("https://web.push.apple.com/QAB"));
  ok(webpushHostAllowed("https://wns2-db5p.notify.windows.com/w/?token=x"));
  ok(!webpushHostAllowed("http://fcm.googleapis.com/x"), "geen http");
  ok(!webpushHostAllowed("https://fcm.googleapis.com.evil.com/x"));
  ok(!webpushHostAllowed("https://evilpush.apple.com.example/x"));
  ok(!webpushHostAllowed("https://fcm.googleapis.com:8443/x"), "geen eigen poort");
  ok(!webpushHostAllowed("https://localhost/x"));
});
Deno.test("doelgroep beheerbericht", () => {
  eq(checkTarget({ all: true }), { all: true });
  eq(checkTarget({ platforms: ["ios", "tvos", "web", "ios"] }), { platforms: ["ios", "web"] });
  eq(checkTarget({ accounts: ["00000000-0000-0000-0000-00000000000A", "nope"] }), { accounts: ["00000000-0000-0000-0000-00000000000a"] });
  eq(checkTarget({ platforms: ["tizen"] }), null);
  eq(checkTarget({}), null);
  eq(checkTarget(null), null);
});

// ---------- herinneringen en dedup ----------
Deno.test("herinneringen lezen (items/reminders/list, removed, profiel uit id)", () => {
  const start = "2026-10-16T18:30:00Z";
  const s = {
    items: [
      { id: "npo1-1792175400", channelID: "npo1", channelName: "NPO 1", title: "Journaal", start },
      { id: "p:abc:rtl4-1", channelID: "rtl4", title: "Nieuws", start },
      { id: "p:def:x-1", profileID: "DEF", channelID: "x", title: "X", start: 1792175400 },
      { id: "weg", channelID: "y", title: "Y", start },
      { id: "kapot", title: "geen zender", start },
    ],
    reminders: [{ id: "oud", channelID: "z", start }],
    removed: { weg: "2026-10-16T10:00:00Z" },
  };
  const r = parseReminders(s);
  eq(r.map((x) => [x.id, x.profileId, x.channelId]), [["npo1-1792175400", null, "npo1"], ["p:abc:rtl4-1", "abc", "rtl4"], ["p:def:x-1", "def", "x"]]);
  eq(r[2].startMs, 1792175400000, "seconden -> ms");
  eq(parseReminders({ reminders: [{ id: "a", channelID: "c", start }] }).length, 1, "iOS: reminders");
  eq(parseReminders(null), []);
});
Deno.test("herinnering: 2 minuten van tevoren, één keer per minuut-venster", () => {
  const start = Date.parse("2026-10-16T18:30:00Z");
  ok(!reminderDue(start, start - 126_000));
  ok(reminderDue(start, start - 124_000));
  ok(reminderDue(start, start - 60_000));
  ok(!reminderDue(start, start), "na de start niet meer");
});
Deno.test("herinnering: profielnaam alleen bij meer dan één profiel", () => {
  const profiles = [{ id: "MAIN", name: "Léon", isMain: true }, { id: "abc", name: "Emma" }, { id: "old", name: "Weg", deleted: true }];
  eq(reminderProfile(profiles, "abc"), { id: "abc", name: "Emma" });
  eq(reminderProfile(profiles, null), { id: "main", name: "Léon" });
  eq(reminderProfile([{ id: "M", name: "Léon", isMain: true }], null), { id: "m", name: null });
  eq(reminderProfile(undefined, "x"), { id: "x", name: null });
});
Deno.test("dedup-sleutels", () => {
  eq(releaseKey("apple", 105), "release:apple:105");
  ok(releaseKey("apple", 105) !== releaseKey("android", 105));
  eq(reminderKey("u1", "p:abc:npo1-1"), "reminder:u1:p:abc:npo1-1");
});

// ---------- antwoorden ----------
Deno.test("antwoorden van APNs, FCM en Web Push", () => {
  eq(apnsOutcome(200, ""), { state: "sent" });
  eq(apnsOutcome(410, "Unregistered").state, "invalid");
  eq(apnsOutcome(400, "BadDeviceToken").state, "invalid");
  eq(apnsOutcome(403, "ExpiredProviderToken"), { state: "retry", error: "apns_ExpiredProviderToken", resetAuth: true });
  eq(apnsOutcome(429, "TooManyRequests").state, "retry");
  eq(apnsOutcome(400, "PayloadTooLarge").state, "failed");
  eq(fcmOutcome(404, { error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }).state, "invalid");
  eq(fcmOutcome(400, { error: { status: "INVALID_ARGUMENT", message: "The registration token is not a valid FCM registration token" } }).state, "invalid");
  eq(fcmOutcome(400, { error: { status: "INVALID_ARGUMENT", message: "Invalid JSON payload" } }).state, "failed");
  eq(fcmOutcome(503, null).state, "retry");
  eq(webpushOutcome(201).state, "sent");
  eq(webpushOutcome(410).state, "invalid");
  eq(webpushOutcome(404).state, "invalid");
  eq(webpushOutcome(413).state, "failed");
});

// ---------- kanalen met nagebootste pushdiensten ----------
Deno.test("kanalen: APNs, FCM en Web Push met nagebootste diensten", async () => {
  const ec = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]) as CryptoKeyPair;
  const rsa = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign"]) as CryptoKeyPair;
  const vapid = await generateVapidKeys();
  const secrets: Record<string, string> = {
    APNS_KEY_P8: await pkcs8Pem(ec.privateKey), APNS_KEY_ID: "KID", APNS_TEAM_ID: "EU3UY476T6", APNS_TOPIC: "nl.lrvdlinden.bingr",
    FCM_SERVICE_ACCOUNT: JSON.stringify({ client_email: "sa@x.iam.gserviceaccount.com", private_key: await pkcs8Pem(rsa.privateKey), project_id: "bingr-x" }),
    VAPID_PRIVATE_KEY: vapid.privateKey, VAPID_PUBLIC_KEY: vapid.publicKey,
  };
  const calls: { url: string; headers: Record<string, string>; body: unknown }[] = [];
  const reply: Record<string, Response | (() => Response)> = {};
  const fake = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, headers: Object.fromEntries(new Headers(init?.headers).entries()), body: init?.body });
    if (url.startsWith("https://oauth2.googleapis.com/")) return new Response(JSON.stringify({ access_token: "ya29.x", expires_in: 3599 }));
    for (const [k, v] of Object.entries(reply)) if (url.startsWith(k)) return typeof v === "function" ? v() : v;
    return new Response(null, { status: 200 });
  }) as typeof fetch;
  const ch = new Channels((k) => secrets[k], fake);
  const n = renderNotice({ id: 5, kind: "admin", title_nl: "T", body_nl: "B" }, { platform: "ios", lang: "nl" });

  eq(await ch.send({ id: 1, channel: "apns", token: "ab".repeat(32), sandbox: true, platform: "ios" }, n), { state: "sent" });
  const a = calls.at(-1)!;
  eq(a.url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  eq([a.headers["apns-topic"], a.headers["apns-push-type"], a.headers["apns-collapse-id"]], ["nl.lrvdlinden.bingr", "alert", "5"]);
  ok(a.headers.authorization.startsWith("bearer ey"));
  await ch.send({ id: 1, channel: "apns", token: "cd".repeat(32), sandbox: false, platform: "macos" }, n);
  eq(calls.at(-1)!.url.startsWith("https://api.push.apple.com/3/device/"), true, "productie");
  eq(calls.at(-1)!.headers.authorization, a.headers.authorization, "provider token uit de cache");
  reply["https://api.push.apple.com/"] = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
  eq((await ch.send({ id: 1, channel: "apns", token: "ef".repeat(32), sandbox: false, platform: "ios" }, n)).state, "invalid");

  calls.length = 0;
  eq(await ch.send({ id: 2, channel: "fcm", token: "fcmtoken", sandbox: false, platform: "android" }, n), { state: "sent" });
  await ch.send({ id: 2, channel: "fcm", token: "fcmtoken2", sandbox: false, platform: "android" }, n);
  eq(calls.filter((c) => c.url.startsWith("https://oauth2")).length, 1, "één OAuth-token voor twee berichten");
  const f = calls.at(-1)!;
  eq(f.url, "https://fcm.googleapis.com/v1/projects/bingr-x/messages:send");
  eq(f.headers.authorization, "Bearer ya29.x");
  eq(JSON.parse(String(f.body)).message.token, "fcmtoken2");
  reply["https://fcm.googleapis.com/"] = () => new Response(JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }), { status: 404 });
  eq((await ch.send({ id: 2, channel: "fcm", token: "t3", sandbox: false, platform: "android" }, n)).state, "invalid");

  calls.length = 0;
  const ua = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const uaPub = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  const auth = crypto.getRandomValues(new Uint8Array(16));
  const token = JSON.stringify({ endpoint: "https://fcm.googleapis.com/fcm/send/abc", keys: { p256dh: b64u(uaPub), auth: b64u(auth) } });
  delete reply["https://fcm.googleapis.com/"];
  reply["https://fcm.googleapis.com/fcm/"] = () => new Response(null, { status: 201 });
  eq(await ch.send({ id: 3, channel: "webpush", token, sandbox: false, platform: "web" }, n, 300), { state: "sent" });
  const w = calls.at(-1)!;
  eq([w.headers["content-encoding"], w.headers.ttl], ["aes128gcm", "300"]);
  ok(w.headers.authorization.startsWith("vapid t=") && w.headers.authorization.endsWith(`k=${vapid.publicKey}`));
  const pt = JSON.parse(td.decode(await decryptWebPush(w.body as Bytes, ua, uaPub, auth)));
  eq(pt, { title: "T", body: "B", data: { kind: "admin", msg_id: "5" } });
  reply["https://fcm.googleapis.com/fcm/"] = () => new Response(null, { status: 410 });
  eq((await ch.send({ id: 3, channel: "webpush", token, sandbox: false, platform: "web" }, n)).state, "invalid");

  // netwerkfout -> later opnieuw
  const broken = new Channels((k) => secrets[k], (() => Promise.reject(new TypeError("boom"))) as typeof fetch);
  eq((await broken.send({ id: 1, channel: "apns", token: "ab".repeat(32), sandbox: false, platform: "ios" }, n)).state, "retry");
});
Deno.test("APNs-providertoken: één per instantie tegelijk, gedeeld tussen instanties, iat per blok van 30 min", async () => {
  // oorzaak van de mislukte Apple-meldingen: elke instantie (en elke worker) maakte een eigen token -> 429 TooManyProviderTokenUpdates
  eq(apnsIat(3600 * 10 + 1799), 3600 * 10);
  eq(apnsIat(3600 * 10 + 1800), 3600 * 10 + 1800);
  eq(apnsIat(3600 * 10 + 5, true), 3600 * 10 + 5, "nieuw na Expired/InvalidProviderToken");
  ok(apnsTokenUsable(1000, 1000 + 49 * 60) && !apnsTokenUsable(1000, 1000 + 50 * 60), "max. 50 minuten");
  ok(!apnsTokenUsable(1000 + 120, 1000), "niet uit de toekomst");
  const ec = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]) as CryptoKeyPair;
  const secrets: Record<string, string> = { APNS_KEY_P8: await pkcs8Pem(ec.privateKey), APNS_KEY_ID: "KID", APNS_TEAM_ID: "EU3UY476T6" };
  const db = new Map<string, { token: string; iat: number }>();
  let saves = 0, loads = 0;
  const store: TokenStore = {
    load: (name) => { loads++; return Promise.resolve(db.get(name) ?? null); },
    save: (name, token, iat) => {
      saves++;
      const cur = db.get(name);
      if (!cur || cur.iat < iat) db.set(name, { token, iat });
      return Promise.resolve(db.get(name)!);
    },
  };
  const auths: string[] = [];
  const fake = ((_u: string, init?: RequestInit) => {
    auths.push(new Headers(init?.headers).get("authorization") ?? "");
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as typeof fetch;
  const env = (k: string) => secrets[k];
  const a = new Apns(env, fake, store), b = new Apns(env, fake, store);
  const n = renderNotice({ id: 7, kind: "admin", title_nl: "T", body_nl: "B" }, { platform: "ios", lang: "nl" });
  const dev = (i: number) => ({ id: i, channel: "apns", token: "ab".repeat(32), sandbox: false, platform: "ios" });
  // 20 workers tegelijk in instantie a, daarna instantie b (andere isolate): overal hetzelfde token
  await Promise.all(Array.from({ length: 20 }, (_, i) => a.send(dev(i), n)));
  await Promise.all(Array.from({ length: 5 }, (_, i) => b.send(dev(i), n)));
  eq(new Set(auths).size, 1, "één token voor alle meldingen");
  eq(saves, 1, "één keer opgeslagen");
  ok(loads <= 2, "hoogstens één keer laden per instantie");
  const claims = decodeJwt(auths[0].replace(/^bearer /, "")).claims;
  eq(claims.iat % 1800, 0, "iat op een blok van 30 minuten");
  // na 50 minuten een nieuw token (en weer gedeeld)
  const later = (claims.iat + 50 * 60) * 1000;
  const t2 = await a.token(later), t3 = await b.token(later);
  ok(t2 !== auths[0].replace(/^bearer /, "") && t2 === t3, "na 50 min vernieuwd en gedeeld");
  // Expired/InvalidProviderToken: één keer per 20 minuten een nieuw token met iat = nu
  a.reset(later);
  const t4 = await a.token(later + 1000);
  ok(t4 !== t2, "na reset nieuw");
  a.reset(later + 60_000);
  eq(await a.token(later + 61_000), t4, "tweede reset binnen 20 min doet niets");
  // TooManyProviderTokenUpdates is tijdelijk en maakt GEEN nieuw token (anders wordt het erger)
  eq(apnsOutcome(429, "TooManyProviderTokenUpdates"), { state: "retry", error: "apns_TooManyProviderTokenUpdates" });
  // zonder store werkt het ook (zelfde iat-blok)
  const c = new Apns(env, fake);
  const tc = await c.token(claims.iat * 1000 + 5000);
  eq(decodeJwt(tc).claims.iat, claims.iat, "zonder store hetzelfde iat-blok");
});
Deno.test("kanaal zonder geheimen: overgeslagen met een duidelijke fout", async () => {
  const ch = new Channels(() => undefined, (() => { throw new Error("mag niet"); }) as typeof fetch);
  const n = renderNotice({ id: 1, kind: "admin", title_nl: "T", body_nl: "B" }, { platform: "ios", lang: "nl" });
  eq(await ch.send({ id: 1, channel: "apns", token: "ab".repeat(32), sandbox: false, platform: "ios" }, n), { state: "failed", error: "apns_not_configured" });
  eq(await ch.send({ id: 1, channel: "fcm", token: "x", sandbox: false, platform: "android" }, n), { state: "failed", error: "fcm_not_configured" });
  eq(await ch.send({ id: 1, channel: "webpush", token: "{}", sandbox: false, platform: "web" }, n), { state: "failed", error: "webpush_not_configured" });
});
Deno.test("versleutelde state (zelfde formaat als device-auth)", async () => {
  const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
  const data = { items: [{ id: "a" }], updatedAt: "2026-10-16T00:00:00Z" };
  eq(await unseal(await seal(data, key), key), data);
});

Deno.test("build 146: antwoord van support (support_reply): tekst, links, data en ttl", () => {
  const nl = renderNotice({ id: 77, kind: "support_reply", payload: { number: 1007, subject: "  Stream   hapert  " } }, { platform: "ios", lang: "nl" });
  eq(nl.title, "Nieuw antwoord op je supportvraag");
  eq(nl.body, "#1007 · Stream hapert");
  eq(nl.data, { kind: "support_reply", msg_id: "77", url: "https://support.bingr.online/ticket/?n=1007", deeplink: "bingr://support/ticket?n=1007", ticket: "1007" });
  const en = renderNotice({ id: 78, kind: "support_reply", payload: { number: 1008, subject: "x".repeat(300) } }, { platform: "web", lang: "de" });
  eq(en.title, "New reply to your support request");
  eq(en.body.length, "#1008 · ".length + 100, "onderwerp max. 100 tekens");
  eq(en.data.url, "https://bingr.online/web/#/support/ticket?n=1008", "webspeler opent zijn eigen tab Support");
  eq(supportText("nl", 9, "").body, "#9", "zonder onderwerp");
  eq(supportKey(5), "support:5");
  eq(ttlFor({ id: 1, kind: "support_reply" }, 0), 3 * 86400);
  const ap = apnsPayload(nl) as Record<string, unknown>;
  eq((ap.aps as { "thread-id": string })["thread-id"], "support_reply");
  eq(ap.ticket, "1007", "plat naast aps");
  eq((fcmMessage("t".repeat(30), nl).message.data as Record<string, string>).ticket, "1007");
  eq(supportLinks(1, "android").deeplink, "bingr://support/ticket?n=1");
});

Deno.test("build 146: versleutelde payload (herinnering) ontsleutelt naar hetzelfde", async () => {
  const k = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
  const sealed = await sealJsonField({ title: "Journaal", channel_name: "NPO 1" }, k);
  ok(sealed.startsWith("enc1:"), "voorvoegsel");
  eq(await openJsonField(sealed, k), { title: "Journaal", channel_name: "NPO 1" });
  eq(await openJsonField("geen", k), null);
});

// ---------- build 172: sportherinneringen ----------
Deno.test("sport: herinneringen lezen (leadMin, competitie, matchKey)", () => {
  const start = Date.parse("2026-11-21T19:30:00Z");
  const r = parseReminders({ items: [
    { id: "sport:ajax~psv:20261121", channelID: "espn1", channelName: "ESPN 1", title: "Ajax - PSV", start: new Date(start).toISOString(),
      leadMin: 15, competition: "Eredivisie", matchKey: "sport:ajax~psv:20261121", auto: true },
    { id: "p:abc:sport:az~twente:20261121", channelID: "z", title: "AZ - FC Twente", start, leadMin: 7, matchKey: "sport:az~twente:20261121" },
    { id: "z-1", channelID: "z", title: "Journaal", start },
  ] });
  eq(r.length, 3);
  eq([r[0].matchKey, r[0].lead, r[0].competition], ["sport:ajax~psv:20261121", 15, "Eredivisie"]);
  eq([r[1].profileId, r[1].lead, r[1].competition], ["abc", 5, null], "onbekende leadMin = 5; profiel uit de id");
  eq(r[2].matchKey, undefined, "gewone herinnering");
  eq([sportLead(0), sportLead(5), sportLead(15), sportLead(3), sportLead(undefined)], [0, 5, 15, 5, 5]);
});

Deno.test("sport: moment van de melding (0, 5, 15 min) en daarna niet meer", () => {
  const s = Date.parse("2026-11-21T19:30:00Z");
  const r = (lead: number) => ({ startMs: s, matchKey: "k", lead });
  ok(!reminderDueFor(r(5), s - 6 * 60_000));
  ok(reminderDueFor(r(5), s - 5 * 60_000 - 4_000), "5 min vooraf (marge 5 s)");
  ok(reminderDueFor(r(5), s - 60_000));
  ok(!reminderDueFor(r(5), s), "na de start niet meer");
  ok(!reminderDueFor(r(15), s - 16 * 60_000));
  ok(reminderDueFor(r(15), s - 15 * 60_000));
  ok(!reminderDueFor(r(0), s - 60_000), "bij de start: niet eerder");
  ok(reminderDueFor(r(0), s));
  ok(reminderDueFor(r(0), s + 110_000), "bij de start: tot 2 min erna");
  ok(!reminderDueFor(r(0), s + 120_000));
  ok(reminderDueFor({ startMs: s }, s - 60_000), "gewone herinnering: 2 min vooraf");
  ok(!reminderDueFor({ startMs: s }, s - 3 * 60_000));
  eq(reminderDeadline({ start_ms: s }), s);
  eq(reminderDeadline({ start_ms: s, deadline_ms: s + 120_000 }), s + 120_000);
});

Deno.test("sport: tekst van de melding", () => {
  eq(sportReminderText("nl", { title: "AZ - FC Twente", lead: 5, competition: "Eredivisie", channelName: "Sport 1" }),
    { title: "AZ - FC Twente begint over 5 minuten", body: "Eredivisie · Sport 1. Tik om live te kijken." });
  eq(sportReminderText("en", { title: "AZ - FC Twente", lead: 0, competition: null, channelName: "Sport 1" }),
    { title: "AZ - FC Twente starts now", body: "Sport 1. Tap to watch live." });
  eq(sportReminderText("nl", { profileName: "Emma", title: "Ajax - PSV", lead: 15, competition: "", channelName: "" }).title,
    "Voor Emma: Ajax - PSV begint over 15 minuten");
  eq(sportReminderText("nl", { title: "X", lead: 5 }).body, "Tik om live te kijken.", "zonder competitie en zender");
  const start = Date.now() + 60_000;
  const n = renderNotice({ id: 11, kind: "reminder", payload: { title: "Ajax - PSV", channel_id: "espn 1", channel_name: "ESPN 1",
    profile_id: null, profile_name: null, start_ms: start, sport: true, lead: 5, competition: "Eredivisie" } }, { platform: "ios", lang: "nl" });
  eq([n.title, n.body, n.data.kind, n.data.deeplink], ["Ajax - PSV begint over 5 minuten", "Eredivisie · ESPN 1. Tik om live te kijken.", "reminder", "bingr://live?channel=espn%201"]);
  ok(ttlFor({ id: 11, kind: "reminder", payload: { start_ms: start, deadline_ms: start + 120_000 } }, Date.now()) > 150, "bij de start: ttl tot 2 min erna");
});

Deno.test("build 176: herinnering op de releasedatum (parse, moment, tekst en link)", () => {
  const start = "2026-12-04T08:00:00Z", s = Date.parse(start);
  const r = parseReminders({ items: [
    { id: "release:movie:550", kind: "release", tmdb: 550, mediaType: "movie", playlistID: "00000000-0000-0000-0000-000000000000",
      channelID: "release:movie:550", channelName: "Bingr", title: "Fight Club", start },
    { id: "p:abc:release:tv:1399:s9", kind: "release", tmdb: 1399, mediaType: "tv", season: 9, channelID: "release:tv:1399:s9",
      channelName: "Bingr", title: "Game of Thrones seizoen 9", start },
    { id: "release:movie:0", kind: "release", tmdb: 0, channelID: "release:movie:0", title: "Fout", start },
  ] });
  eq(r.length, 3);
  eq(r[0].release, { tmdb: 550, mediaType: "movie" });
  eq([r[1].release, r[1].profileId], [{ tmdb: 1399, mediaType: "tv" }, "abc"]);
  eq(r[2].release, undefined, "zonder geldig TMDB-id een gewone herinnering");
  ok(!reminderDueFor(r[0], s - 60_000), "niet 2 minuten vooraf");
  ok(reminderDueFor(r[0], s - 4_000), "op 09:00 (marge 5 s)");
  ok(reminderDueFor(r[0], s + RELEASE_WINDOW_MS - 1), "tot 30 minuten erna");
  ok(!reminderDueFor(r[0], s + RELEASE_WINDOW_MS));
  eq(releaseReminderText("nl", { title: "Fight Club" }), { title: "Nu te zien: Fight Club", body: "Vandaag verschenen. Tik om te bekijken." });
  eq(releaseReminderText("en-GB", { title: "Dune", profileName: "Emma" }).title, "For Emma: Out now: Dune");
  eq(titleLinks("tv", 1399, "Game of Thrones").deeplink, "bingr://title?type=tv&id=1399&q=Game%20of%20Thrones");
  eq(titleLinks("x", 550, "").url, "https://bingr.online/titel/?type=movie&id=550");
  const n = renderNotice({ id: 9, kind: "reminder", payload: { release: true, tmdb: 550, media_type: "movie", title: "Fight Club", start_ms: s } },
    { platform: "ios", lang: "nl" });
  eq([n.title, n.data.deeplink], ["Nu te zien: Fight Club", "bingr://title?type=movie&id=550&q=Fight%20Club"]);
});
