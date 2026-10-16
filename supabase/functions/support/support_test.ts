// Tests voor de supporttickets (geen database, geen netwerk, geen SMTP):
//   deno test supabase/functions/support/support_test.ts
import {
  addressOf, cleanText, compareVersionsDesc, deviceKind, deviceLabel, knownVersions, myDevices, langOf, parseNumber, safeSearch, sameText, statusAfter, ticketUrl, validateCreate, validateMessage,
  validEmail, validToken, randomToken,
} from "./logic.ts";
import { bodyHtml, esc, renderMail, subjectFor, type MailData } from "./templates.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }

const good = {
  name: "Léon", email: "Leon@Example.com", category: "afspelen", platform: "tvos", app_version: "1.0.0 (74)",
  subject: "Stream hapert", message: "Sinds gisteren hapert elke stream na een paar minuten.", lang: "nl", website: "", elapsed_ms: 12000,
};

Deno.test("geldig ticket: opgeschoond en e-mail in kleine letters", () => {
  const r = validateCreate({ ...good, subject: "  Stream \u0000 hapert  ", message: "Regel 1\r\n\r\n\r\n\r\n\r\nRegel 2 is lang genoeg" });
  ok(r.ok, JSON.stringify(r));
  if (!r.ok) return;
  eq(r.value.email, "leon@example.com");
  eq(r.value.subject, "Stream hapert");
  eq(r.value.message, "Regel 1\n\n\nRegel 2 is lang genoeg");
  eq(r.value.platform, "tvos");
  eq(r.value.lang, "nl");
});

Deno.test("ongeldige tickets", () => {
  const err = (patch: Record<string, unknown>) => { const r = validateCreate({ ...good, ...patch }); return r.ok ? "ok" : r.error; };
  eq(err({ website: "http://spam" }), "spam", "lokveld");
  eq(err({ elapsed_ms: 800 }), "spam", "te snel");
  eq(err({ name: "  " }), "name_missing");
  eq(err({ email: "geen-adres" }), "bad_email");
  eq(err({ email: "a@b" }), "bad_email");
  eq(err({ email: "a..b@x.nl" }), "bad_email");
  eq(err({ category: "betaling" }), "bad_category");
  eq(err({ platform: "windows" }), "bad_platform");
  eq(err({ platform: "" }), "ok", "platform leeg mag");
  eq(err({ subject: "Hi" }), "subject_missing");
  eq(err({ subject: "x".repeat(121) }), "subject_too_long");
  eq(err({ message: "kort" }), "message_too_short");
  eq(err({ message: "x".repeat(5001) }), "message_too_long");
  eq(err({ message: "zie " + "https://a.nl ".repeat(7) }), "too_many_links");
  eq(err({ elapsed_ms: undefined }), "ok", "zonder tijd mag");
});

Deno.test("apparaat bij een ticket: device_id opgeschoond of genegeerd", () => {
  const dev = (v: unknown) => { const r = validateCreate({ ...good, device_id: v }); return r.ok ? r.value.device_id : "fout"; };
  eq(dev(undefined), null);
  eq(dev(""), null);
  eq(dev("  6F1C-ABC  "), "6F1C-ABC");
  eq(dev("met spatie"), null, "geen spaties");
  eq(dev("x".repeat(129)), null, "te lang");
  eq(dev(42), null, "geen tekst");
});

Deno.test("apparaten van het account: platform, labels, volgorde en versies", () => {
  eq(deviceKind("Apple TV"), "tvos");
  eq(deviceKind("iPad"), "ios");
  eq(deviceKind("iPhone"), "ios");
  eq(deviceKind("Mac"), "macos");
  eq(deviceKind("Google TV"), "androidtv");
  eq(deviceKind("Fire TV"), "androidtv");
  eq(deviceKind("Android tablet"), "android");
  eq(deviceKind("tizen"), "tizen");
  eq(deviceKind("browser"), "web");
  eq(deviceKind("Windows"), null);
  eq(deviceLabel("tizen"), "Samsung TV");
  eq(deviceLabel("browser"), "Browser");
  eq(deviceLabel("Apple TV"), "Apple TV");
  eq(["1.0.0 (9)", "1.0.0 (74)", "0.9 (100)", "1.0.1 (2)", "1.0.0 (75)"].sort(compareVersionsDesc), ["1.0.1 (2)", "1.0.0 (75)", "1.0.0 (74)", "1.0.0 (9)", "0.9 (100)"]);
  const r = myDevices([
    { device_id: "a", name: "Woonkamer", platform: "tizen", app_version: "1.0.0 (75)", os_version: "Tizen 6.5", last_seen_at: "2026-10-01T10:00:00Z" },
    { device_id: "b", name: "Apple TV Serre", platform: "Apple TV", app_version: "1.0.0 (74)", os_version: "tvOS 26.0", last_seen_at: "2026-10-14T08:00:00Z" },
    { device_id: "c", name: "", platform: "browser", app_version: "1.0.0 (74)", os_version: null, last_seen_at: null },
    { device_id: "", name: "kapot", platform: "iPhone", app_version: null, os_version: null, last_seen_at: null },
  ]);
  eq(r.devices.map((d) => d.id), ["b", "a", "c"], "laatst gebruikt eerst, zonder id weg");
  eq(r.devices[0].kind, "tvos");
  eq(r.devices[1].label, "Samsung TV");
  eq(r.devices[2].name, "Browser", "naam leeg: platform");
  eq(r.versions, ["1.0.0 (75)", "1.0.0 (74)"], "uniek, nieuwste eerst");
});

Deno.test("my_devices: versies van de apparaten, lege versie telt niet mee", () => {
  const r = myDevices([
    { device_id: "x", name: "Apple TV - Woonkamer", platform: "Apple TV", app_version: "  ", os_version: null, last_seen_at: "2026-10-14T08:00:00Z" },
    { device_id: "y", name: "Android TV", platform: "Android TV", app_version: null, os_version: null, last_seen_at: "2026-10-13T08:00:00Z" },
  ]);
  eq(r.versions, [], "geen versies: de site valt terug op de bekende builds");
  eq(r.devices.map((d) => [d.kind, d.app_version]), [["tvos", null], ["androidtv", null]]);
});

Deno.test("bekende builds: nieuwste build per platform uit de changelog", () => {
  const log = [
    { build: 81, version: "1.0.0", items: [{ platforms: ["web"] }] },
    { build: 80, version: "1.0.0", items: [{ platforms: ["server"] }] },
    { build: 78, version: "1.0.0", items: [{ platforms: ["ios", "ipados", "tvos"] }, { platforms: ["macos"] }] },
    { build: 75, version: "1.0.0", items: [{ platforms: ["android", "androidtv", "tizen"] }, { platforms: ["ios"] }] },
    { build: 60, version: "1.0.0", items: [{ platforms: ["tvos", "android"] }] },
    { build: "kapot", items: [{ platforms: ["ios"] }] }, null,
  ];
  eq(knownVersions(log), [
    { version: "1.0.0 (81)", build: 81, platforms: ["web"] },
    { version: "1.0.0 (78)", build: 78, platforms: ["ios", "tvos", "macos"] },
    { version: "1.0.0 (75)", build: 75, platforms: ["android", "androidtv", "tizen"] },
  ]);
  eq(knownVersions({}), [], "geen lijst");
  eq(knownVersions(null), []);
});

Deno.test("berichten, nummers, zoeken, taal", () => {
  eq(validateMessage("  ").ok, false);
  eq(validateMessage("Dank je!").ok, true);
  eq(parseNumber("#1001"), 1001);
  eq(parseNumber(" 1002 "), 1002);
  eq(parseNumber("10a"), null);
  eq(parseNumber("0"), null);
  eq(safeSearch("a,b(c)*%d"), "a b c d");
  eq(langOf("en-GB"), "en");
  eq(langOf("de"), "nl");
  eq(cleanText("a‮b\nc", 10), "ab c");
  ok(validEmail("support+test@bingr.online"));
});

Deno.test("statusovergangen", () => {
  eq(statusAfter("pending", "customer"), "open");
  eq(statusAfter("resolved", "customer"), "open");
  eq(statusAfter("new", "customer"), "new");
  eq(statusAfter("new", "support"), "pending");
  eq(statusAfter("open", "support", "resolved"), "resolved");
});

Deno.test("tokens en links", () => {
  const t = randomToken();
  ok(validToken(t), t);
  ok(!validToken("kort"));
  ok(!validToken("a".repeat(30) + "<"));
  ok(sameText(t, t));
  ok(!sameText(t, t.slice(0, -1) + (t.endsWith("A") ? "B" : "A")));
  eq(ticketUrl("https://support.bingr.online/", 1001, "abc_-"), "https://support.bingr.online/ticket/?n=1001&t=abc_-");
  eq(addressOf("Bingr Support <support@bingr.online>"), "support@bingr.online");
  eq(addressOf("support@bingr.online"), "support@bingr.online");
});

const base: MailData = {
  kind: "customer_created", lang: "nl", number: 1001, subject: "Stream <b>hapert</b>", status: "new",
  body: "Hallo <script>alert(1)</script>\n\nZie https://bingr.online/support.html.", url: "https://support.bingr.online/ticket/?n=1001&t=abc",
  name: "Léon", email: "leon@example.com", category: "afspelen", platform: "tvos", appVersion: "1.0.0 (74)",
};

Deno.test("e-mail: escapen en links", () => {
  eq(esc(`<a href="x">'&`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;");
  const h = bodyHtml("a<b>\nc\n\nhttps://x.nl/pad?q=1.");
  ok(h.includes("a&lt;b&gt;<br>c"), h);
  ok(h.includes('<a href="https://x.nl/pad?q=1"'), "link zonder punt");
  ok(!bodyHtml("javascript:alert(1) http://x.nl").includes("<a"), "alleen https wordt een link");
  const m = renderMail(base);
  ok(!m.html.includes("<script>"), "geen script");
  ok(m.html.includes("&lt;script&gt;"), "script ge-escaped");
  ok(!m.html.includes("<b>hapert"), "onderwerp ge-escaped");
  ok(m.html.includes("#1001"), "nummer in html");
  ok(m.html.includes("BINGR") && m.html.includes("#E50914"), "huisstijl");
  ok(m.html.includes("support.bingr.online") && m.html.includes("supportticket hebt aangemaakt"), "footer");
  ok(m.text.includes("#1001") && m.text.includes("<script>alert(1)</script>"), "platte tekst onveranderd");
  ok(!/<[a-z]/i.test(m.text.replace(/<script>alert\(1\)<\/script>|<b>hapert<\/b>/g, "")), "geen html in platte tekst");
});

Deno.test("e-mail: onderwerpen per soort en taal", () => {
  eq(subjectFor(base), "[#1001] We hebben je vraag ontvangen: Stream <b>hapert</b>");
  eq(subjectFor({ ...base, lang: "en" }), "[#1001] We've received your request: Stream <b>hapert</b>");
  eq(subjectFor({ ...base, kind: "customer_reply", lang: "en" }), "[#1001] New reply: Stream <b>hapert</b>");
  eq(subjectFor({ ...base, kind: "customer_status", status: "resolved" }), "[#1001] Opgelost: Stream <b>hapert</b>");
  eq(subjectFor({ ...base, kind: "support_created", lang: "en" }), "[#1001] Nieuw ticket: Stream <b>hapert</b>");
  eq(subjectFor({ ...base, subject: "a\r\nBcc: x@y.z" }), "[#1001] We hebben je vraag ontvangen: a Bcc: x@y.z", "geen header-injectie");
});

Deno.test("e-mail: taal en inhoud", () => {
  const en = renderMail({ ...base, lang: "en" });
  ok(en.html.includes('lang="en"') && en.html.includes("View your ticket") && en.html.includes("Playback and streams"), "Engels");
  const sup = renderMail({ ...base, kind: "support_created", lang: "en", url: "https://beheer.bingr.online/#support/1001", customerUrl: base.url });
  ok(sup.html.includes('lang="nl"') && sup.html.includes("Openen in beheer") && sup.html.includes("leon@example.com"), "support@ in het Nederlands");
  ok(sup.html.includes("Engels"), "taal van de klant genoemd");
  const res = renderMail({ ...base, kind: "customer_status", status: "resolved", body: undefined });
  ok(res.html.includes("Je ticket is opgelost") && res.html.includes("Opgelost"), "opgelost");
  const rep = renderMail({ ...base, kind: "customer_reply", status: "pending", body: "Probeer de VLC-speler." });
  ok(rep.html.includes("Antwoord van Bingr Support") && rep.html.includes("Wacht op jouw reactie"), "antwoord");
});

// ---- build 95 ----
Deno.test("build 95: bevestiging aan gast of uit een mail zonder onderwerp, bericht en links", () => {
  const m = renderMail({ ...base, minimal: true });
  eq(m.subject, "[#1001] We hebben je vraag ontvangen");
  ok(!m.html.includes("hapert") && !m.text.includes("hapert"), "geen onderwerp");
  ok(!m.html.includes("alert(1)") && !m.text.includes("alert(1)"), "geen bericht");
  ok(!m.html.includes("bingr.online/support.html") && !m.text.includes("bingr.online/support.html"), "geen links uit het bericht");
  ok(!m.html.includes("1.0.0 (74)") && !m.text.includes("1.0.0 (74)"), "geen ingevulde app-versie");
  ok(m.html.includes("#1001") && m.html.includes(base.url.replace(/&/g, "&amp;")) && m.text.includes(base.url), "nummer en ticketlink");
  // ingelogd: met citaat; melding aan support altijd volledig
  ok(renderMail(base).text.includes("Sinds") || renderMail(base).text.includes("alert(1)"), "ingelogd met bericht");
  ok(renderMail({ ...base, kind: "support_created", minimal: true }).text.includes("alert(1)"), "support@ volledig");
});

Deno.test("build 95: antwoord met status gesloten: geen 'beantwoord', wel link voor een nieuwe vraag", () => {
  const d: MailData = { ...base, kind: "customer_reply", status: "closed", body: "Opgelost, we sluiten het ticket.", replyByMail: true };
  const nl = renderMail(d), en = renderMail({ ...d, lang: "en" });
  ok(!nl.html.includes("Bekijk en beantwoord") && !nl.text.includes("Reageren?"), "geen beantwoord/reageren");
  ok(nl.html.includes("https://support.bingr.online/nieuw/") && nl.text.includes("https://support.bingr.online/nieuw/"), "link nieuw ticket");
  ok(nl.text.includes("Dit ticket is gesloten") && en.text.includes("This ticket is closed"), "sluittekst NL/EN");
  ok(!en.html.includes("View and reply") && en.html.includes("Ask a new question"), "Engels");
  ok(!nl.text.includes("Antwoord boven deze lijn"), "geen markeringsregel");
  const open = renderMail({ ...d, status: "pending" });
  ok(open.html.includes("Bekijk en beantwoord") && open.text.includes("Antwoord boven deze lijn"), "open ticket ongewijzigd");
});

import { leadingZeroBits, makeChallenge, powHash, powKey, verifyPow } from "./pow.ts";
async function solve(salt: string, difficulty: number) {
  for (let n = 0; ; n++) if (leadingZeroBits(await powHash(salt, String(n))) >= difficulty) return String(n);
}
Deno.test("build 95: captcha (proof-of-work): opgave, oplossing, handtekening, vervaltijd", async () => {
  eq(leadingZeroBits(new Uint8Array([0, 0x0f, 0xff])), 12);
  eq(leadingZeroBits(new Uint8Array([0x80])), 0);
  eq(await powKey(""), null);
  const key = (await powKey("geheim"))!, other = (await powKey("ander"))!;
  const now = Date.now();
  const c = await makeChallenge(key, now, 8);
  eq([c.algorithm, c.difficulty, c.expires - now], ["SHA-256", 8, 600000]);
  ok(/^[0-9a-f]{32}$/.test(c.salt) && /^[0-9a-f]{64}$/.test(c.signature), "salt en handtekening");
  const nonce = await solve(c.salt, 8);
  eq(await verifyPow(key, { ...c, nonce }, now, 8), { ok: true, salt: c.salt });
  eq((await verifyPow(key, null, now, 8)), { ok: false, reason: "missing" });
  eq((await verifyPow(key, { ...c }, now, 8)), { ok: false, reason: "malformed" });
  eq((await verifyPow(other, { ...c, nonce }, now, 8)), { ok: false, reason: "signature" });
  eq((await verifyPow(key, { ...c, difficulty: 1, nonce }, now, 8)), { ok: false, reason: "signature" }, "moeilijkheid aanpassen");
  eq((await verifyPow(key, { ...c, nonce }, now + 11 * 60000, 8)), { ok: false, reason: "expired" });
  eq((await verifyPow(key, { ...c, nonce }, now, 18)), { ok: false, reason: "difficulty" }, "te makkelijke opgave");
  let bad = Number(nonce) + 1;
  while (leadingZeroBits(await powHash(c.salt, String(bad))) >= 8) bad++;
  eq((await verifyPow(key, { ...c, nonce: String(bad) }, now, 8)), { ok: false, reason: "hash" });
});

Deno.test("aanhef met de voornaam van het account: alleen in klantmails en alleen als die bekend is", () => {
  ok(!/>Hoi |>Hi /.test(renderMail(base).html) && !renderMail(base).text.includes("Hoi "), "zonder naam geen aanhef");
  const m = renderMail({ ...base, firstName: "Léon" });
  ok(m.html.includes(">Hoi Léon,</p>") && m.text.includes("Hoi Léon,"), "NL");
  ok(renderMail({ ...base, lang: "en", kind: "customer_reply", body: "x", firstName: "Ann" }).html.includes(">Hi Ann,</p>"), "EN");
  ok(renderMail({ ...base, firstName: "<b>Jo</b>" }).html.includes(">Hoi bJo/b,</p>"), "opgeschoond, geen HTML");
  ok(!renderMail({ ...base, kind: "support_created", firstName: "Léon" }).html.includes("Hoi Léon"), "niet in mails aan support@");
});
