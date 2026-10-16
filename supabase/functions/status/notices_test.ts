// Tests voor meldingen, niveaus, dagbalken, feed en e-mails van de statuspagina (geen database of internet nodig):
//   deno test --allow-all supabase/functions/status/notices_test.ts
import {
  amsDay, annotateDays, atomFeed, autoTitle, componentLevels, effectiveStatus, isActive, isUpcoming, maintStatus, minutesByDay, type Notice,
  overallLevel, publicNotice, rssFeed, validEmail, validToken, xmlEsc,
} from "./notices.ts";
import { renderConfirm, renderNotice } from "./templates.ts";
import type { DayPoint } from "./logic.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg: string) { if (!v) throw new Error(msg); }

const NOW = Date.parse("2026-10-14T12:00:00Z");
const iso = (h: number) => new Date(NOW + h * 3600e3).toISOString();
function notice(p: Partial<Notice>): Notice {
  return {
    id: 1, kind: "incident", title_nl: "Storing", title_en: "Outage", impact: "major", status: "investigating",
    started_at: iso(-1), resolved_at: null, window_start: null, window_end: null, components: [], updates: [], ...p,
  };
}

Deno.test("onderhoud volgt het tijdvak", () => {
  const m = notice({ kind: "maintenance", status: "scheduled", window_start: iso(1), window_end: iso(3) });
  eq(maintStatus(m, NOW), "scheduled");
  eq(maintStatus(m, NOW + 2 * 3600e3), "in_progress");
  eq(maintStatus(m, NOW + 4 * 3600e3), "completed");
  eq(maintStatus({ ...m, status: "cancelled" }, NOW + 2 * 3600e3), "cancelled");
  eq(isUpcoming(m, NOW), true);
  eq(isActive(m, NOW), false);
  eq(isActive(m, NOW + 2 * 3600e3), true);
  eq(effectiveStatus(notice({ status: "monitoring" }), NOW), "monitoring");
});

Deno.test("niveau per onderdeel en totaalbeeld", () => {
  const mons = [{ id: "db", state: "up" as const }, { id: "auth", state: "down" as const }, { id: "site", state: "degraded" as const }, { id: "apk", state: "up" as const }];
  // zonder meldingen: monitor bepaalt
  let lv = componentLevels(mons, [], NOW);
  eq([lv.get("db"), lv.get("auth"), lv.get("site")], ["operational", "major", "degraded"]);
  eq(overallLevel(lv, [], NOW).level, "major");
  // onderhoud aan auth: monitorfout telt niet, onderdeel staat op onderhoud
  const maint = notice({ id: 2, kind: "maintenance", status: "scheduled", window_start: iso(-1), window_end: iso(1), components: [{ monitor_id: "auth", impact: "maintenance" }] });
  lv = componentLevels(mons, [maint], NOW);
  eq(lv.get("auth"), "maintenance");
  eq(overallLevel(lv, [maint], NOW).level, "degraded"); // site blijft verminderd
  // handmatige storing met gedeeltelijke impact op db
  const inc = notice({ id: 3, components: [{ monitor_id: "db", impact: "partial" }] });
  lv = componentLevels(mons, [maint, inc], NOW);
  eq(lv.get("db"), "partial");
  const ov = overallLevel(lv, [maint, inc], NOW);
  eq([ov.level, ov.partial, ov.maintenance], ["partial", ["db"], ["auth"]]);
  // opgeloste storing telt niet meer; storing zonder onderdelen: impact kritiek = grote storing
  eq(componentLevels(mons, [{ ...inc, status: "resolved", resolved_at: iso(0) }], NOW).get("db"), "operational");
  const all = componentLevels(mons.map((m) => ({ ...m, state: "up" as const })), [], NOW);
  eq(overallLevel(all, [], NOW).level, "operational");
  eq(overallLevel(all, [notice({ impact: "critical" })], NOW).level, "major");
  eq(overallLevel(all, [notice({ impact: "minor" })], NOW).level, "degraded");
  eq(overallLevel(all, [notice({ impact: "none" })], NOW).level, "operational");
});

Deno.test("minuten per dag (Nederlandse tijd, ook rond middernacht en zomertijd)", () => {
  eq(amsDay(Date.parse("2026-10-13T22:30:00Z")), "2026-10-14"); // 00:30 CEST
  const m = minutesByDay(Date.parse("2026-10-13T21:30:00Z"), Date.parse("2026-10-13T22:30:00Z")); // 23:30-00:30 CEST
  eq([...m], [["2026-10-13", 30], ["2026-10-14", 30]]);
  // nacht van 24 op 25 oktober 2026: klok terug (25 uur op 25 oktober)
  const d = minutesByDay(Date.parse("2026-10-24T22:00:00Z"), Date.parse("2026-10-25T23:00:00Z"));
  eq([...d], [["2026-10-25", 25 * 60]]);
  eq(minutesByDay(10, 5).size, 0);
});

Deno.test("dagbalken met storingsminuten en meldingen", () => {
  const days: DayPoint[] = [
    { d: "2026-10-12", u: 100, s: "up", n: 288 },
    { d: "2026-10-13", u: 99.3, s: "down", n: 288 },
    { d: "2026-10-14", u: 100, s: "up", n: 100 },
  ];
  const outages = [{ m: "db", started_at: "2026-10-13T08:00:00Z", ended_at: "2026-10-13T08:12:00Z" }, { m: "auth", started_at: "2026-10-13T08:00:00Z", ended_at: null }];
  const inc = notice({ id: 7, started_at: "2026-10-14T09:00:00Z", resolved_at: "2026-10-14T09:30:00Z", status: "resolved", components: [{ monitor_id: "db", impact: "degraded" }] });
  const mt = notice({ id: 8, kind: "maintenance", status: "completed", window_start: "2026-10-12T01:00:00Z", window_end: "2026-10-12T02:00:00Z", resolved_at: "2026-10-12T02:00:00Z", components: [{ monitor_id: "db", impact: "maintenance" }] });
  const future = notice({ id: 9, kind: "maintenance", status: "scheduled", window_start: iso(48), window_end: iso(50), components: [{ monitor_id: "db", impact: "maintenance" }] });
  const bars = annotateDays(days, "db", outages, [inc, mt, future], NOW);
  eq(bars.map((b) => [b.d, b.s, b.dm, b.i]), [
    ["2026-10-12", "maint", 0, [8]],
    ["2026-10-13", "down", 12, []],
    ["2026-10-14", "degraded", 0, [7]],
  ]);
  // geen metingen maar wel onderhoud: blauw
  eq(annotateDays([{ d: "2026-10-12", u: null, s: "none", n: 0 }], "db", [], [mt], NOW)[0].s, "maint");
});

Deno.test("openbare melding: alleen openbare onderdelen, tijdlijn nieuwste eerst", () => {
  const n = notice({
    components: [{ monitor_id: "db", impact: "major" }, { monitor_id: "geheim", impact: "major" }],
    updates: [{ status: "investigating", body_nl: "a", body_en: "", at: iso(-1) }, { status: "identified", body_nl: "b", body_en: "B", at: iso(0) }],
  });
  const p = publicNotice(n, new Set(["db"]), NOW);
  eq(p.components, [{ id: "db", impact: "major" }]);
  eq(p.updates.map((u) => [u.status, u.body.en]), [["identified", "B"], ["investigating", "a"]]);
  eq(p.title, { nl: "Storing", en: "Outage" });
});

Deno.test("automatische titel", () => {
  eq(autoTitle(["Database"], "nl"), "Storing bij Database");
  eq(autoTitle(["Database", "Opslag"], "en"), "Outage affecting Database and Opslag");
  eq(autoTitle(["A", "B", "C"], "nl"), "Storing bij A, B en C");
  eq(autoTitle(["A", "B", "C", "D", "E"], "nl"), "Storing bij A, B en 3 andere");
});

Deno.test("feed: XML veilig en compleet", () => {
  eq(xmlEsc(`a<b>&"c'\u0001`), "a&lt;b&gt;&amp;&quot;c&apos;");
  const n = notice({
    id: 42, title_nl: "Storing <script>alert(1)</script> & meer", status: "resolved", resolved_at: iso(0),
    components: [{ monitor_id: "db", impact: "major" }],
    updates: [{ status: "resolved", body_nl: "Opgelost & \"klaar\"\u0007", body_en: "Fixed", at: iso(0) }],
  });
  const names = new Map([["db", { nl: "Database", en: "Database" }]]);
  const items = [publicNotice(n, new Set(["db"]), NOW)];
  const a = atomFeed(items, { lang: "nl", site: "https://bingr.online", self: "https://bingr.online/status/feed.atom", updated: iso(0), names });
  ok(a.startsWith('<?xml version="1.0" encoding="utf-8"?>'), "atom: xml-kop");
  ok(!a.includes("<script>") && !a.includes("\u0007"), "atom: geen ruwe HTML of stuurtekens");
  ok(a.includes("&lt;script&gt;") && a.includes("tag:bingr.online,2026:status-42"), "atom: titel ge-escaped en id");
  ok(a.includes("https://bingr.online/status/incident/?id=42"), "atom: link naar de melding");
  eq((a.match(/<entry>/g) ?? []).length, 1);
  // na één keer unescapen is de inhoud nog steeds geëscapete HTML (dus nooit uitvoerbaar)
  ok(a.includes("Opgelost &amp;amp; &amp;quot;klaar&amp;quot;"), "atom: inhoud is geëscapete HTML (dubbel in de XML)");
  const r = rssFeed(items, { lang: "en", site: "https://bingr.online", self: "https://bingr.online/status/feed.en.rss", updated: iso(0), names });
  ok(r.includes("<rss version=\"2.0\"") && r.includes("<language>en-gb</language>") && r.includes("<item>"), "rss: opbouw");
  ok(!/supabase/i.test(a + r), "feeds noemen geen leverancier");
});

Deno.test("e-mails: bevestigen en melding", () => {
  const c = renderConfirm("nl", "t".repeat(48));
  ok(c.html.includes("https://bingr.online/status/?confirm=" + "t".repeat(48)), "bevestigingslink");
  ok(c.subject.includes("Bevestig"), "onderwerp nl");
  ok(c.text.includes("Aanmelding bevestigen"), "platte tekst");
  const n = publicNotice(notice({
    id: 5, title_nl: "Inloggen <traag>", title_en: "Sign-in slow", status: "identified",
    components: [{ monitor_id: "auth", impact: "partial" }],
    updates: [{ status: "investigating", body_nl: "We kijken", body_en: "Looking", at: iso(-1) }, { status: "identified", body_nl: "Oorzaak <b>gevonden</b>", body_en: "Found it", at: iso(0) }],
  }), new Set(["auth"]), NOW);
  const names = new Map([["auth", { nl: "Accounts & inloggen", en: "Accounts & sign-in" }]]);
  const m = renderNotice(n, "nl", names, "u".repeat(48));
  ok(m.subject === "[Bingr Storing] Oorzaak bekend: Inloggen <traag>", `onderwerp: ${m.subject}`);
  ok(m.html.includes("Inloggen &lt;traag&gt;") && m.html.includes("Oorzaak &lt;b&gt;gevonden&lt;/b&gt;"), "html ge-escaped");
  ok(m.html.includes("https://bingr.online/status/?unsubscribe=" + "u".repeat(48)), "afmeldlink in de voettekst");
  ok(m.html.includes("https://bingr.online/status/incident/?id=5"), "knop naar de melding");
  ok(m.html.includes("Accounts &amp; inloggen"), "getroffen onderdeel");
  ok(m.text.includes("Afmelden: https://bingr.online/status/?unsubscribe="), "afmelden in platte tekst");
  const en = renderNotice(n, "en", names, "u".repeat(48));
  ok(en.subject.startsWith("[Bingr Incident] Identified: Sign-in slow") && en.html.includes("Found it"), "engels");
  ok(!/supabase/i.test(c.html + m.html + en.html + m.text), "mails noemen geen leverancier");
  // aanhef met de voornaam van het account (alleen als die bekend is)
  ok(!/Hoi |Hi /.test(c.html + c.text + m.text) && !m.html.includes(">Hoi "), "zonder naam geen aanhef");
  const cn = renderConfirm("nl", "t".repeat(48), "Léon");
  ok(cn.html.includes(">Hoi Léon,</p>") && cn.text.includes("Hoi Léon,"), "bevestigen met aanhef");
  const mn = renderNotice(n, "en", names, "u".repeat(48), "<Ann>");
  ok(mn.html.includes(">Hi Ann,</p>") && mn.text.includes("Hi Ann,") && !mn.html.includes("<Ann>"), "melding met aanhef, opgeschoond");
});

Deno.test("e-mailadres en token controleren", () => {
  eq(validEmail(" Leon@Example.NL "), "leon@example.nl");
  eq(validEmail("geen-adres"), null);
  eq(validEmail("a@b"), null);
  eq(validEmail("x@y..nl"), null);
  eq(validEmail("a".repeat(250) + "@x.nl"), null);
  eq(validToken("a".repeat(48)), true);
  eq(validToken("kort"), false);
  eq(validToken("a".repeat(47) + "<"), false);
});
