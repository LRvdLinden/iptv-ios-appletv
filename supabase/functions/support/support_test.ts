// Tests voor de supporttickets (geen database, geen netwerk, geen SMTP):
//   deno test supabase/functions/support/support_test.ts
import {
  addressOf, cleanText, langOf, parseNumber, safeSearch, sameText, statusAfter, ticketUrl, validateCreate, validateMessage,
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
