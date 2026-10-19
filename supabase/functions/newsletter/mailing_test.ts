// Unittests voor de eigen mailing vanuit het beheer: deno test supabase/functions/newsletter/mailing_test.ts
// Zonder netwerk en database: invoer, opmaak (escapen, links, koppen, opsommingen), de mail per doelgroep en taal,
// doelgroep (opt-out, geblokkeerd, onbevestigd, verwijderd, taal) en de verzendronde (idempotent, limiet, fouten).
// Alleen testadressen (example.invalid).
import {
  type AccountRow, bodyToHtml, bodyToText, budgetOf, cleanContent, cleanUrl, countAudience, eligible, inlineHtml, type MailingContent,
  mailingView, parseBlocks, type Recipient, recipientLang, renderMailing, runMailing, type Take,
} from "./mailing.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }

const content = (over: Partial<MailingContent> = {}): MailingContent => ({
  nl: { subject: "Nieuw in Bingr", body: "# Wat is nieuw\n\nDe app is **sneller**.\n\n- punt een\n- punt twee", button: "Lees meer" },
  en: { subject: "New in Bingr", body: "# What's new\n\nThe app is **faster**.", button: "Read more" },
  image: "https://bingr.online/assets/img/nl/tv_home.jpg", button_url: "https://bingr.online/", ...over,
});

// ---------- invoer ----------

Deno.test("invoer: geldige inhoud, opgeschoond", () => {
  const r = cleanContent({
    nl: { subject: "  Nieuw\n in  Bingr ", body: "Hallo\r\n\r\n\r\n\r\nwereld  ​", button: "Lees" },
    en: { subject: "New", body: "Hi", button: "Read" }, image: "", button_url: " https://bingr.online/x?a=1&b=2 ",
  });
  ok(r.ok, "ok");
  if (!r.ok) return;
  eq(r.content.nl.subject, "Nieuw in Bingr", "onderwerp op één regel");
  eq(r.content.nl.body, "Hallo\n\nwereld", "regeleinden en zero-width");
  eq(r.content.button_url, "https://bingr.online/x?a=1&b=2", "url getrimd");
  eq(r.content.image, "", "geen afbeelding");
});

Deno.test("invoer: verplichte velden per taal, grenzen en knop", () => {
  const base = { nl: { subject: "a", body: "b" }, en: { subject: "c", body: "d" } };
  eq(cleanContent({ ...base, en: { subject: "", body: "d" } }), { ok: false, error: "bad_subject_en" }, "EN onderwerp leeg");
  ok(cleanContent({ ...base, en: { subject: "", body: "" } }, ["nl"]).ok, "voorbeeld NL zonder EN mag");
  eq(cleanContent({ ...base, nl: { subject: "a", body: "" } }), { ok: false, error: "bad_body_nl" }, "NL tekst leeg");
  eq(cleanContent({ ...base, nl: { subject: "x".repeat(151), body: "b" } }), { ok: false, error: "bad_subject_nl" }, "onderwerp te lang");
  eq(cleanContent({ ...base, nl: { subject: "a", body: "x".repeat(8001) } }), { ok: false, error: "bad_body_nl" }, "tekst te lang");
  eq(cleanContent({ ...base, button_url: "https://bingr.online/" }), { ok: false, error: "bad_button_text_nl" }, "knop zonder tekst");
  eq(cleanContent({ ...base, nl: { subject: "a", body: "b", button: "Ga" } }), { ok: false, error: "bad_button_url" }, "knoptekst zonder url");
  eq(cleanContent({ ...base, image: "http://bingr.online/a.jpg" }), { ok: false, error: "bad_image_url" }, "http-afbeelding");
  eq(cleanContent({ ...base, button_url: "javascript:alert(1)" }), { ok: false, error: "bad_button_url" }, "javascript:");
  eq(cleanContent(null), { ok: false, error: "bad_content" }, "geen object");
  eq(cleanContent([]), { ok: false, error: "bad_content" }, "lijst");
});

Deno.test("invoer: https-URL", () => {
  eq(cleanUrl("https://bingr.online/a.png"), "https://bingr.online/a.png");
  eq(cleanUrl(""), ""); eq(cleanUrl(undefined), "");
  for (const bad of ["http://bingr.online", "https://user:pw@bingr.online/", "https://localhost/x", "https://127.0.0.1/x", "https://bingr.online/a b",
    'https://bingr.online/"onerror=x', "https://bingr.online/<x>", "data:image/png;base64,AA", "https://x.local/a", 42, `https://bingr.online/${"a".repeat(500)}`]) {
    eq(cleanUrl(bad), null, `ongeldig: ${String(bad).slice(0, 40)}`);
  }
});

// ---------- opmaak ----------

Deno.test("opmaak: blokken (koppen, alinea's, opsommingen)", () => {
  const b = parseBlocks("# Kop\nregel een\nregel twee\n\n- a\n- b\nvervolg b\n\n1. een\n2) twee\n\n## Kleiner");
  eq(b.map((x) => x.t), ["h", "p", "ul", "ol", "h"], "soorten");
  eq(b[1], { t: "p", lines: ["regel een", "regel twee"] }, "alinea met regeleinde");
  eq(b[2], { t: "ul", items: ["a", "b\nvervolg b"] }, "opsomming met vervolgregel");
  eq((b[4] as { level: number }).level, 3, "## = kleinere kop");
});

Deno.test("opmaak: escapen, vet en links (alleen https)", () => {
  const h = inlineHtml(`<script>alert("x")</script> **vet** [klik](https://bingr.online/?a=1&b=2) en https://support.bingr.online.`);
  ok(!h.includes("<script"), "geen script");
  ok(h.includes("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"), "ge-escaped");
  ok(h.includes("<strong>vet</strong>"), "vet");
  ok(h.includes('<a href="https://bingr.online/?a=1&amp;b=2" style="color:#ffffff;text-decoration:underline">klik</a>'), "markdown-link");
  ok(h.includes('<a href="https://support.bingr.online"'), "losse link zonder punt aan het eind");
  const j = inlineHtml("[x](javascript:alert(1)) [y](http://a.nl) [z](https://a.nl/\"onmouseover=1)");
  ok(!/href="(javascript|http:)/.test(j), "geen javascript:/http-link");
  ok(!j.includes('"onmouseover'), "geen attribuut-injectie");
  eq(inlineHtml("[**vet**](https://a.nl/)"), '<a href="https://a.nl/" style="color:#ffffff;text-decoration:underline"><strong>vet</strong></a>', "vet in linktekst");
});

Deno.test("opmaak: HTML en platte tekst van de hele tekst", () => {
  const src = "# Kop\n\nTekst met [link](https://bingr.online/).\n\n- een\n- **twee**\n\n1. eerste";
  const h = bodyToHtml(src);
  ok(h.includes("<h2 ") && h.includes(">Kop</h2>"), "kop");
  ok(h.includes("<ul ") && h.includes("<li ") && h.includes("<strong>twee</strong>"), "opsomming");
  ok(h.includes("<ol "), "genummerd");
  ok(!/style="[^"]*(expression|url\()/.test(h), "geen gevaarlijke stijl");
  eq(bodyToText(src), "KOP\n\nTekst met link (https://bingr.online/).\n\n- een\n- twee\n\n1. eerste", "platte tekst");
});

// ---------- de mail ----------

Deno.test("mail: nieuwsbrief-abonnees met afmeldlink, aanhef, knop en afbeelding", () => {
  const m = renderMailing({ lang: "nl", content: content(), audience: "newsletter", firstName: "Léon <b>", unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=abc", year: 2026 });
  eq(m.subject, "Nieuw in Bingr", "onderwerp NL");
  ok(m.html.startsWith("<!doctype html>") && m.html.includes('<html lang="nl">'), "huisstijl-layout, taal nl");
  ok(m.html.includes(">BINGR<") && m.html.includes("#E50914"), "logo met rode streep");
  ok(m.html.includes("Hoi Léon b,"), "aanhef met opgeschoonde naam (< > weg)");
  ok(m.html.includes('src="https://bingr.online/assets/img/nl/tv_home.jpg"'), "afbeelding");
  ok(m.html.includes(">Lees meer</a>"), "knop");
  ok(m.html.includes("https://bingr.online/unsubscribe/?k=news&amp;t=abc") && m.html.includes(">Afmelden</a>"), "afmeldlink");
  ok(m.html.includes("ingeschreven voor de nieuwsbrief"), "reden");
  ok(!m.html.includes("Servicebericht"), "geen servicelabel");
  ok(m.text.includes("Hoi Léon b,") && m.text.includes("Lees meer: https://bingr.online/") && m.text.includes("Afmelden: https://bingr.online/unsubscribe/"), "tekstversie");
  ok(!m.text.includes("<"), "tekst zonder HTML");
});

Deno.test("mail: servicebericht zonder afmeldlink, met reden; EN-versie; test-onderwerp", () => {
  const m = renderMailing({ lang: "en", content: content(), audience: "service", unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=abc" });
  eq(m.subject, "New in Bingr", "onderwerp EN");
  ok(m.html.includes('<html lang="en">'), "taal en");
  ok(m.html.includes("Service message") && m.html.includes("because you have a Bingr account"), "label en reden");
  ok(!m.html.includes("/unsubscribe/") && !m.text.includes("/unsubscribe/") && !m.html.includes(">Unsubscribe<"), "geen afmeldlink");
  ok(!m.html.includes("Hi "), "geen aanhef zonder naam");
  const t = renderMailing({ lang: "nl", content: content({ image: "", button_url: "" }), audience: "newsletter", test: true });
  eq(t.subject, "[Test] Nieuw in Bingr", "testonderwerp");
  ok(!t.html.includes("<img"), "geen afbeelding");
  ok(!t.html.includes("Lees meer"), "geen knop zonder url");
});

Deno.test("mail: onderwerp en tekst van de beheerder worden ge-escaped", () => {
  const c = content({ nl: { subject: '<img src=x onerror="a">', body: "<a href=\"javascript:x\">x</a>", button: "<b>" } });
  const m = renderMailing({ lang: "nl", content: c, audience: "newsletter" });
  ok(!m.html.includes("<img src=x") && !m.html.includes('<a href="javascript') && !m.html.includes("<b>"), "niets onge-escaped");
});

// ---------- doelgroep ----------

const now = Date.parse("2026-10-19T12:00:00Z");
const acc = (o: Partial<AccountRow> = {}): AccountRow => ({ email: "a@example.invalid", email_confirmed_at: "2026-01-01T00:00:00Z", ...o });

Deno.test("doelgroep: opt-out, geblokkeerd, onbevestigd, verwijderd", () => {
  ok(eligible(acc(), "newsletter", now) && eligible(acc(), "service", now), "gewoon lid: beide");
  ok(!eligible(acc({ newsletter_opt_out: true }), "newsletter", now), "afgemeld nieuwsbrief: geen nieuwsbrief");
  ok(eligible(acc({ newsletter_opt_out: true }), "service", now), "afgemeld nieuwsbrief: wel servicebericht");
  ok(!eligible(acc({ email_opt_out: true }), "newsletter", now), "alle mail uit: geen nieuwsbrief");
  ok(eligible(acc({ email_opt_out: true }), "service", now), "alle mail uit: wel servicebericht");
  for (const a of ["newsletter", "service"] as const) {
    ok(!eligible(acc({ banned_until: "2027-01-01T00:00:00Z" }), a, now), `geblokkeerd (${a})`);
    ok(eligible(acc({ banned_until: "2026-01-01T00:00:00Z" }), a, now), `blokkade verlopen (${a})`);
    ok(!eligible(acc({ email_confirmed_at: null }), a, now), `onbevestigd (${a})`);
    ok(!eligible(acc({ deleted_at: "2026-10-01T00:00:00Z" }), a, now), `verwijderd (${a})`);
    ok(!eligible(acc({ email: null }), a, now), `zonder adres (${a})`);
  }
});

Deno.test("doelgroep: taal per ontvanger (nl -> NL, al het andere -> EN) en aantallen", () => {
  eq(["nl", "NL", "nl-BE", "", null, "en", "de", "fr-FR"].map(recipientLang), ["nl", "nl", "nl", "nl", "nl", "en", "en", "en"]);
  const rows = [acc({ lang: "nl" }), acc({ lang: "de" }), acc({ lang: "en", newsletter_opt_out: true }), acc({ lang: "nl", email_confirmed_at: null })];
  eq(countAudience(rows, "newsletter", now), { nl: 1, en: 1, total: 2 }, "nieuwsbrief");
  eq(countAudience(rows, "service", now), { nl: 1, en: 2, total: 3 }, "service");
});

// ---------- versturen ----------

/** Nep-wachtrij met dezelfde regels als bingr_mailing_take / _mark: per account één rij, alleen 'queued' wordt geclaimd. */
function fakeQueue(ids: string[]) {
  const rows = new Map(ids.map((id) => [id, { state: "queued", attempts: 0 }]));
  const deliveries: string[] = [];
  const take = (batch: number): Promise<Take> => {
    const items: Recipient[] = [];
    for (const [id, r] of rows) {
      if (items.length >= batch) break;
      if (r.state === "queued") { r.state = "sending"; r.attempts++; items.push({ id, email: `${id}@example.invalid`, lang: id.startsWith("e") ? "en" : "nl", first_name: null }); }
    }
    const open = [...rows.values()].some((r) => r.state === "queued" || r.state === "sending");
    return Promise.resolve({ items, done: !items.length && !open });
  };
  const mark = (m: { sent: string[]; failed: string[]; retry: string[]; release: string[] }) => {
    for (const id of m.release) { const r = rows.get(id)!; if (r.state === "sending") { r.state = "queued"; r.attempts--; } }
    for (const id of m.sent) { const r = rows.get(id)!; if (r.state === "sending") r.state = "sent"; }
    for (const id of m.failed) { const r = rows.get(id)!; if (r.state === "sending") r.state = "failed"; }
    for (const id of m.retry) { const r = rows.get(id)!; if (r.state === "sending") r.state = r.attempts >= 3 ? "failed" : "queued"; }
    return Promise.resolve();
  };
  return { rows, deliveries, take, mark };
}
const tempErr = Object.assign(new Error("421"), { responseCode: 421 });
const permErr = Object.assign(new Error("550"), { responseCode: 550 });
const deps = (q: ReturnType<typeof fakeQueue>, fail: (u: Recipient) => Error | null = () => null) => ({
  take: q.take, mark: q.mark, now: () => 0,
  send: (u: Recipient, lang: string) => { const e = fail(u); if (e) return Promise.reject(e); q.deliveries.push(`${u.id}:${lang}`); return Promise.resolve(); },
  temporary: (e: unknown) => Number((e as { responseCode?: number }).responseCode) < 500,
  code: (e: unknown) => `smtp_${(e as { responseCode?: number }).responseCode}`,
});

Deno.test("versturen: in rondes met limiet, iedereen precies één keer, juiste taal", async () => {
  const ids = Array.from({ length: 25 }, (_, i) => `${i % 3 ? "n" : "e"}${i}`);
  const q = fakeQueue(ids);
  const r1 = await runMailing(deps(q), { budget: 10, until: 1, batch: 4 });
  eq([r1.sent, r1.done], [10, false], "ronde 1: limiet 10");
  const r2 = await runMailing(deps(q), { budget: 10, until: 1, batch: 4 });
  eq([r2.sent, r2.done], [10, false], "ronde 2");
  const r3 = await runMailing(deps(q), { budget: 10, until: 1, batch: 4 });
  eq(r3.sent, 5, "ronde 3: de rest");
  const r4 = await runMailing(deps(q), { budget: 10, until: 1, batch: 4 });
  eq([r4.sent, r4.done], [0, true], "daarna klaar, niets meer");
  eq(q.deliveries.length, 25, "25 mails");
  eq(new Set(q.deliveries).size, 25, "niemand dubbel");
  ok(q.deliveries.every((d) => d.endsWith(d.startsWith("e") ? ":en" : ":nl")), "taal per ontvanger");
});

Deno.test("versturen: tijdelijke fout stopt de ronde (later opnieuw), blijvende fout niet opnieuw", async () => {
  const q = fakeQueue(["n1", "n2", "n3", "n4"]);
  let tries = 0;
  const r = await runMailing(deps(q, (u) => (u.id === "n2" && tries++ < 1 ? tempErr : u.id === "n3" ? permErr : null)), { budget: 50, until: 1, batch: 10 });
  eq([r.sent, r.retry, r.failed], [1, 1, 0], "stopt na de tijdelijke fout");
  eq(q.rows.get("n3")!.state, "queued", "niet aan toegekomen: terug in de wachtrij");
  eq(q.rows.get("n3")!.attempts, 0, "telt niet als poging");
  const r2 = await runMailing(deps(q, (u) => (u.id === "n3" ? permErr : null)), { budget: 50, until: 1, batch: 10 });
  eq([r2.sent, r2.failed, r2.errors], [2, 1, { smtp_550: 1 }], "tweede ronde: n2 en n4 verstuurd, n3 mislukt");
  const r3 = await runMailing(deps(q), { budget: 50, until: 1, batch: 10 });
  eq([r3.sent, r3.done], [0, true], "mislukte niet opnieuw");
  eq(q.deliveries.sort(), ["n1:nl", "n2:nl", "n4:nl"], "elk één keer");
});

Deno.test("versturen: tijd op -> rest terug in de wachtrij", async () => {
  const q = fakeQueue(["n1", "n2", "n3"]);
  let t = 0;
  const d = { ...deps(q), now: () => t, pause: () => { t += 10; return Promise.resolve(); } };
  const r = await runMailing(d, { budget: 50, until: 15, batch: 10 });
  eq(r.sent, 2, "twee binnen de tijd");
  eq([...q.rows.values()].filter((x) => x.state === "queued").length, 1, "derde terug in de wachtrij");
});

Deno.test("versturen: budget per uur", () => {
  eq(budgetOf(200, 0, 50), 50, "batch");
  eq(budgetOf(200, 180, 50), 20, "rest van het uur");
  eq(budgetOf(200, 250, 50), 0, "uur vol");
});

Deno.test("beheer: weergave van een mailing (alleen aantallen en onderwerpen)", () => {
  const v = mailingView({
    id: 7, created_at: "2026-10-19T10:00:00Z", finished_at: null, audience: "service", status: "sending",
    content: { nl: { subject: "Storing", body: "x", button: "" }, en: { subject: "Outage", body: "y", button: "" } },
    recipients: 10, recipients_nl: 6, recipients_en: 4, sent: 3, failed: 1, skipped: 1, cancelled: 0,
  });
  eq(v, {
    id: 7, created_at: "2026-10-19T10:00:00Z", finished_at: null, audience: "service", status: "sending", subject: { nl: "Storing", en: "Outage" },
    recipients: { nl: 6, en: 4, total: 10 }, sent: 3, failed: 1, skipped: 1, cancelled: 0, left: 5,
  });
  ok(!JSON.stringify(v).includes("@"), "geen adressen");
});
