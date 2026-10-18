
 // Unittests voor de welkomstmail: deno test supabase/functions/newsletter/welcome_test.ts
// Zonder netwerk en database: opbouw, escapen, aanhef, links, nieuwsbriefalinea, selectie en eerste uitrol.
import { esc } from "../_shared/layout.ts";
import {
  initialMarks, LINKS, renderWelcome, SAMPLE_NAME, showNewsletter, WELCOME, WELCOME_BATCH, WELCOME_DAYS, welcomeEligible,
  welcomeSubject,
} from "./welcome.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }
const UNSUB = "https://bingr.online/unsubscribe/?k=news&t=a.b";

Deno.test("welkomstmail: opbouw, huisstijl, links en voettekst (nl en en)", () => {
  for (const lang of ["nl", "en"] as const) {
    const m = renderWelcome({ lang, firstName: "Léon", unsubscribeUrl: UNSUB, newsletter: true, year: 2026 });
    ok(m.html.includes("BINGR") && m.html.includes("#E50914") && m.html.includes("background:#000000") && m.html.includes("#141414"), `${lang}: huisstijl`);
    ok(m.html.includes(`lang="${lang}"`), `${lang}: taal`);
    for (const u of [LINKS.source, LINKS.web, LINKS.pair, LINKS.testflight, LINKS.android, LINKS.support]) {
      ok(m.html.includes(`href="${u}"`), `${lang}: knop ${u}`);
      ok(m.text.includes(u), `${lang}: platte tekst ${u}`);
    }
    eq(LINKS.source, "https://support.bingr.online/hulp/afspeellijst/");
    eq(LINKS.testflight, "https://testflight.apple.com/join/JW915fdA");
    ok(m.html.includes("Xtream Codes") && m.html.includes("M3U"), `${lang}: bron`);
    ok(m.html.includes("Samsung TV") && m.html.includes(lang === "nl" ? "binnenkort" : "coming soon"), `${lang}: Samsung binnenkort`);
    ok(m.html.includes("k=news&amp;t=a.b") && m.text.includes(UNSUB), `${lang}: uitschrijflink nieuwsbrief`);
    ok(m.html.includes("/privacy.html") && m.html.includes("support.bingr.online") && m.html.includes("© 2026 Bingr"), `${lang}: voettekst`);
    ok(m.html.includes(esc(WELCOME[lang].honest)) && m.text.includes(WELCOME[lang].honest), `${lang}: eerlijke zin`);
    ok(m.html.includes(lang === "nl" ? "zondag en woensdag" : "Sunday and Wednesday"), `${lang}: nieuwsbrief`);
    ok(!/app-?icon|apple-touch-icon|favicon/i.test(m.html), `${lang}: geen app-icoon`);
    ok(!/€|\$\d|prijs|price|supabase|tmdb/i.test(m.html + m.text), `${lang}: geen prijzen of leveranciers`);
    eq(m.subject, WELCOME[lang].subject, `${lang}: onderwerp`);
  }
  eq(welcomeSubject("nl"), "Welkom bij Bingr: zo begin je");
  eq(welcomeSubject("en", true), "[Voorbeeld] Welcome to Bingr: here's how to start");
  eq([WELCOME_DAYS, WELCOME_BATCH], [7, 50]);
});

Deno.test("welkomstmail: aanhef met voornaam, ge-escaped; zonder naam geen aanhef", () => {
  const nl = renderWelcome({ lang: "nl", firstName: "Léon", unsubscribeUrl: UNSUB });
  ok(nl.html.includes("Hoi Léon,") && nl.text.startsWith("Hoi Léon,"), "nl aanhef");
  const en = renderWelcome({ lang: "en", firstName: "Léon", unsubscribeUrl: UNSUB });
  ok(en.html.includes("Hi Léon,") && en.text.startsWith("Hi Léon,"), "en aanhef");
  const evil = renderWelcome({ lang: "nl", firstName: `"><script>alert(1)</script>&Jan'`, unsubscribeUrl: UNSUB });
  ok(!evil.html.includes("<script>"), "geen HTML uit de naam");
  ok(evil.html.includes(">Hoi &quot;scriptalert(1)/script&amp;Jan&#39;,</p>"), "naam opgeschoond en ge-escaped");
  const none = renderWelcome({ lang: "nl", unsubscribeUrl: UNSUB });
  ok(!none.html.includes("Hoi ") && !none.text.startsWith("Hoi"), "zonder naam geen aanhef");
  const url = renderWelcome({ lang: "nl", firstName: "www.spam.example", unsubscribeUrl: UNSUB });
  ok(!url.html.includes("spam.example"), "naam met link telt niet");
  const sample = renderWelcome({ lang: "nl", firstName: SAMPLE_NAME, unsubscribeUrl: UNSUB, preview: true });
  ok(sample.html.includes(`Hoi ${SAMPLE_NAME},`) && sample.subject.startsWith("[Voorbeeld] "), "voorbeeld met voorbeeldnaam");
  ok(sample.html.includes("Voorbeeld uit het beheer"), "voorbeeldnotitie");
  ok(!renderWelcome({ lang: "nl", unsubscribeUrl: UNSUB }).html.includes("Voorbeeld uit het beheer"), "geen notitie in de echte mail");
});

Deno.test("welkomstmail: uitschrijflink ge-escaped, nieuwsbriefalinea alleen als die van toepassing is", () => {
  const m = renderWelcome({ lang: "nl", unsubscribeUrl: `https://bingr.online/unsubscribe/?k=news&t="><x`, newsletter: true });
  ok(!m.html.includes(`"><x`) && m.html.includes("t=&quot;&gt;&lt;x"), "url ge-escaped");
  const off = renderWelcome({ lang: "nl", unsubscribeUrl: UNSUB, newsletter: false });
  ok(!off.html.includes("zondag en woensdag") && !off.html.includes("k=news") && !off.text.includes("k=news"), "zonder nieuwsbriefalinea");
  ok(off.html.includes(LINKS.source) && off.html.includes(esc(WELCOME.nl.honest)), "rest blijft");
  eq([showNewsletter(true, true), showNewsletter(false, true), showNewsletter(true, false)], [true, false, false], "alinea alleen bij aan + ingeschreven");
});

Deno.test("welkomstmail: selectie (zelfde regels als bingr_welcome_take)", () => {
  const now = Date.parse("2026-10-17T12:00:00Z");
  const base = { email: "a@example.com", email_confirmed_at: "2026-10-17T11:00:00Z", banned_until: null, deleted_at: null, has_row: false };
  ok(welcomeEligible(base, now), "net bevestigd");
  ok(welcomeEligible({ ...base, email_confirmed_at: "2026-10-10T12:00:01Z" }, now), "binnen 7 dagen");
  ok(!welcomeEligible({ ...base, email_confirmed_at: "2026-10-10T12:00:00Z" }, now), "precies 7 dagen: te laat");
  ok(!welcomeEligible({ ...base, email_confirmed_at: "2026-09-01T00:00:00Z" }, now), "oud account");
  ok(!welcomeEligible({ ...base, email_confirmed_at: null }, now), "niet bevestigd");
  ok(!welcomeEligible({ ...base, email_confirmed_at: "2026-10-18T00:00:00Z" }, now), "in de toekomst");
  ok(!welcomeEligible({ ...base, has_row: true }, now), "al verstuurd/gemarkeerd");
  ok(!welcomeEligible({ ...base, email: null }, now), "zonder adres");
  ok(!welcomeEligible({ ...base, deleted_at: "2026-10-17T11:30:00Z" }, now), "verwijderd");
  ok(!welcomeEligible({ ...base, banned_until: "2026-10-18T00:00:00Z" }, now), "geblokkeerd");
  ok(welcomeEligible({ ...base, banned_until: "2026-10-17T00:00:00Z" }, now), "blokkade voorbij");
});

Deno.test("welkomstmail: eerste uitrol markeert alle bevestigde accounts", () => {
  eq(initialMarks([
    { id: "a", email_confirmed_at: "2026-10-16T00:00:00Z" }, { id: "b", email_confirmed_at: null }, { id: "c", email_confirmed_at: "2020-01-01T00:00:00Z" },
  ]), ["a", "c"]);
  eq(initialMarks([]), []);
});
