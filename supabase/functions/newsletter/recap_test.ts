// Unittests voor de maandrecap "Jouw maand op Bingr": deno test supabase/functions/newsletter/recap_test.ts
// Zonder netwerk (nep-TMDB). Planning (1e van de maand 20:00 lokaal, zomer- en wintertijd, onbekende tijdzone = Amsterdam,
// land), alleen Lifetime (Gratis = geen mail; geen aggregatie staat in recap_test.sh), één keer per maand, de aggregatie (serie met afleveringen, films, live tv), geen mail bij nul, de opmaak (NL/EN,
// alt-teksten, links, escapen) en het bewaren van 13 maanden. De wachtrij en de trigger staan in supabase/tests/recap_test.sh.
import {
  buildRecap, cleanTitle, recapAllowed, duration, hoursText, kept, localIn, monthBefore, nextRecap, parseEpisode, type RecapRow, recapDue,
  recapMonthsNow, recapName, recapSettingsOf, recapTz, recapUrl, renderRecap, retainFrom, sampleRows, whenText,
} from "./recap.ts";
import { enrichRecap, metaOf } from "./recap_tmdb.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }
const at = (iso: string) => Date.parse(iso);

// ---------- planning ----------

Deno.test("planning: 1 november 2026 20:00 Amsterdam (wintertijd) = 19:00 UTC, over oktober", () => {
  eq(recapDue(at("2026-11-01T19:00:00Z"), "Europe/Amsterdam"), "2026-10", "20:00 CET");
  eq(recapDue(at("2026-11-01T18:00:00Z"), "Europe/Amsterdam"), null, "19:00 lokaal: nog niet");
  eq(recapDue(at("2026-11-01T20:00:00Z"), "Europe/Amsterdam"), "2026-10", "21:00: speling");
  eq(recapDue(at("2026-11-01T21:00:00Z"), "Europe/Amsterdam"), "2026-10", "22:00: speling");
  eq(recapDue(at("2026-11-01T22:00:00Z"), "Europe/Amsterdam"), null, "23:00: voorbij");
  eq(recapDue(at("2026-11-02T19:00:00Z"), "Europe/Amsterdam"), null, "2 november niet");
  eq(recapDue(at("2026-10-31T19:00:00Z"), "Europe/Amsterdam"), null, "31 oktober niet");
});

Deno.test("planning: zomertijd (1 juli 2027 20:00 CEST = 18:00 UTC) en de jaarwisseling", () => {
  eq(recapDue(at("2027-07-01T18:00:00Z"), "Europe/Amsterdam"), "2027-06", "20:00 CEST");
  eq(recapDue(at("2027-07-01T17:00:00Z"), "Europe/Amsterdam"), null, "19:00 CEST");
  eq(recapDue(at("2027-01-01T19:00:00Z"), "Europe/Amsterdam"), "2026-12", "januari: over december");
  // 1 april 2027: net na de overgang naar zomertijd
  eq(recapDue(at("2027-04-01T18:00:00Z"), "Europe/Amsterdam"), "2027-03", "april (CEST)");
});

Deno.test("planning: andere tijdzones, onbekende tijdzone = Amsterdam, land als terugval", () => {
  eq(recapDue(at("2026-11-02T01:00:00Z"), "America/New_York"), "2026-10", "New York 20:00 EST");
  eq(recapDue(at("2026-11-01T19:00:00Z"), "America/New_York"), null, "New York 14:00");
  eq(recapDue(at("2026-11-01T07:00:00Z"), "Pacific/Auckland"), "2026-10", "Auckland 20:00 NZDT");
  eq(recapDue(at("2026-11-01T14:00:00Z"), "Asia/Kolkata"), null, "India 19:30 nog niet");
  eq(recapDue(at("2026-11-01T15:00:00Z"), "Asia/Kolkata"), "2026-10", "India 20:30 = 20:xx");
  eq(recapTz(null, null), "Europe/Amsterdam", "niets bekend");
  eq(recapTz("Mars/Olympus", null), "Europe/Amsterdam", "onbekende tijdzone");
  eq(recapTz("Mars/Olympus", "be"), "Europe/Brussels", "land");
  eq(recapTz("Europe/London", "NL"), "Europe/London", "app gaat voor land");
  eq(recapTz(null, "XX"), "Europe/Amsterdam", "onbekend land");
  eq(recapDue(at("2026-11-01T19:00:00Z"), "geen/tijdzone"), "2026-10", "ongeldige tijdzone rekent als Amsterdam");
});

Deno.test("planning: welke maanden nu, de volgende verzending", () => {
  eq(recapMonthsNow(at("2026-11-01T19:00:00Z")), [], "oktober 2026 (deels bijgehouden) gaat niet: eerste recap over november");
  eq(recapMonthsNow(at("2026-12-01T19:00:00Z")), ["2026-11"], "1 december: over november");
  eq(recapMonthsNow(at("2026-11-15T19:00:00Z")), [], "midden in de maand: niets");
  eq(recapMonthsNow(at("2026-10-31T07:00:00Z")), [], "UTC+14 is dan pas 21:00 op 31 oktober");
  eq(recapMonthsNow(at("2026-10-31T06:00:00Z")).length, 0);
  eq(recapMonthsNow(at("2026-12-02T08:00:00Z")), ["2026-11"], "UTC-12: nog op 1 december 20:00");
  eq(nextRecap(at("2026-11-01T12:00:00Z")), { key: "2026-11", at: "2026-12-01T19:00:00.000Z" }, "eerste: 1 december 20:00");
  eq(nextRecap(at("2026-12-01T19:00:00Z")), { key: "2026-12", at: "2027-01-01T19:00:00.000Z" }, "daarna 1 januari");
  eq(nextRecap(at("2027-06-15T12:00:00Z")).at, "2027-07-01T18:00:00.000Z", "zomer");
  eq(monthBefore("2027-01-01"), "2026-12");
  eq(localIn(at("2026-11-01T19:30:00Z"), "Europe/Amsterdam").hour, 20);
});

Deno.test("één keer per account en maand: de sleutel is de maand, ook over de uren van de speling", () => {
  const keys = new Set(["2026-11-01T19:00:00Z", "2026-11-01T20:00:00Z", "2026-11-01T21:00:00Z"].map((x) => recapDue(at(x), "Europe/Amsterdam")));
  eq([...keys], ["2026-10"]);
  // over een heel jaar elk uur: per tijdzone precies 12 maanden, elk precies 3 uur (20, 21, 22)
  for (const tz of ["Europe/Amsterdam", "America/New_York", "Asia/Kolkata"]) {
    const count = new Map<string, number>();
    for (let t = at("2026-11-01T00:00:00Z"); t < at("2027-11-01T00:00:00Z"); t += 3600_000) {
      const k = recapDue(t, tz);
      if (k) count.set(k, (count.get(k) ?? 0) + 1);
    }
    eq(count.size, 12, `${tz}: 12 maanden`);
    ok([...count.values()].every((n) => n === 3), `${tz}: elke maand 3 rondes`);
  }
});

Deno.test("bewaren: 13 maanden", () => {
  eq(retainFrom(at("2026-11-01T00:30:00Z")), "2025-11");
  eq(retainFrom(at("2027-01-31T23:00:00Z")), "2026-01");
  ok(kept("2025-11", at("2026-11-20T00:00:00Z")) && !kept("2025-10", at("2026-11-20T00:00:00Z")), "november 2025 blijft, oktober 2025 niet");
  eq(recapSettingsOf(null), { enabled: true, audience: "lifetime" }, "standaard aan, alleen Lifetime");
  eq(recapSettingsOf({ show_recap: false, recap_audience: "all" }), { enabled: false, audience: "lifetime" }, "altijd alleen Lifetime");
  ok(recapAllowed("lifetime") && !recapAllowed("free") && !recapAllowed(null) && !recapAllowed(undefined), "Gratis = geen recap");
});

// ---------- aggregatie ----------

const row = (x: Partial<RecapRow> & Pick<RecapRow, "kind" | "item_key">): RecapRow => ({
  title: x.item_key, plays: 1, minutes: 30, episodes: 0, first_at: "2026-10-10T18:00:00Z", last_at: "2026-10-10T19:00:00Z", ...x,
});
const ROWS: RecapRow[] = [
  row({ kind: "episode", item_key: "s1", title: "NL - The Bear (2022)", plays: 5, minutes: 200, episodes: 4, first_at: "2026-10-02T18:10:00Z", last_at: "2026-10-28T20:00:00Z", first_label: "The Bear · S1:E1 · System", last_label: "The Bear · S1:E4" }),
  row({ kind: "episode", item_key: "s2", title: "Bluey", plays: 9, minutes: 90, episodes: 9 }),
  row({ kind: "episode", item_key: "s3", title: "Klein", plays: 1, minutes: 20, episodes: 1 }),
  row({ kind: "episode", item_key: "s4", title: "Te kort", plays: 1, minutes: 0.5, episodes: 0 }),
  row({ kind: "movie", item_key: "m1", title: "Dune: Part Two [4K]", plays: 1, minutes: 166, first_at: "2026-10-30T19:00:00Z", last_at: "2026-10-30T21:46:00Z" }),
  row({ kind: "movie", item_key: "m2", title: "Up", plays: 2, minutes: 96, first_at: "2026-10-01T17:00:00Z", last_at: "2026-10-01T18:36:00Z" }),
  row({ kind: "live", item_key: "c1", title: "NPO 1 · Journaal", plays: 6, minutes: 300, first_at: "2026-10-01T05:00:00Z", last_at: "2026-10-31T21:00:00Z" }),
  row({ kind: "live", item_key: "c2", title: "RTL 4", plays: 1, minutes: 10 }),
];

Deno.test("aggregatie: serie met afleveringen, films, live tv", () => {
  const r = buildRecap(ROWS, "2026-10", "Europe/Amsterdam")!;
  eq(r.totals, { episodes: 14, movies: 2, minutes: 883 }, "tegels: afleveringen, films, minuten incl. live");
  eq(r.series.map((s) => s.title), ["The Bear", "Bluey", "Klein"], "top 3 series op kijktijd, titel opgeschoond");
  eq(r.movies.map((s) => s.title), ["Dune: Part Two", "Up"], "films");
  ok(r.series.every((s) => s.type === "tv") && r.movies.every((s) => s.type === "movie"), "soorten");
  eq(r.channel, { title: "NPO 1", minutes: 300 }, "meest gekeken zender, niet in de toplijsten");
  ok(![...r.series, ...r.movies].some((t) => t.title.includes("NPO")), "geen zenders in de toplijsten");
  eq([r.first?.title, r.first?.at], ["Up", "2026-10-01T17:00:00Z"], "eerste titel: geen live");
  eq([r.last?.title, r.last?.at], ["Dune: Part Two", "2026-10-30T21:46:00Z"], "laatste titel: geen live");
  eq([r.upNext?.title, r.upNext?.season, r.upNext?.episode], ["The Bear", 1, 5], "volgende aflevering na S1E4");
  eq(r.hero?.title, "The Bear", "kop: meest bekeken serie of film");
  eq(r.series[0].year, 2022);
});

Deno.test("aggregatie: geen mail bij nul", () => {
  eq(buildRecap([], "2026-10", "Europe/Amsterdam"), null, "geen rijen");
  eq(buildRecap([row({ kind: "movie", item_key: "x", minutes: 0.4 })], "2026-10", "Europe/Amsterdam"), null, "minder dan 1 minuut");
  const live = buildRecap([row({ kind: "live", item_key: "c", title: "NPO 1", minutes: 60 })], "2026-10", "Europe/Amsterdam")!;
  ok(live && live.series.length === 0 && live.first === null && live.channel?.minutes === 60 && live.totals.minutes === 60, "alleen live: wel een mail, met uren en zender");
});

Deno.test("aflevering uit de streamtitel en opschonen van titels", () => {
  eq(parseEpisode("Serie · S1:E2 · Naam"), { season: 1, episode: 2, name: "Naam" });
  eq(parseEpisode("Serie S01E02"), { season: 1, episode: 2 });
  eq(parseEpisode("Serie - S2E10 - De finale"), { season: 2, episode: 10, name: "De finale" });
  eq(parseEpisode("Film zonder aflevering"), null);
  eq(parseEpisode(null), null);
  eq(cleanTitle("NL - The Bear (2022)"), { title: "The Bear", year: 2022 });
  eq(cleanTitle("|NL| Oppenheimer 2023 4K"), { title: "Oppenheimer", year: 2023 });
  eq(cleanTitle("1917"), { title: "1917", year: null }, "een jaartal als titel blijft");
  eq(recapName("  Léon ", "L"), "Léon");
  eq(recapName(null, "Sam"), "Sam", "weergavenaam");
  eq(recapName("", "kijk www.example.com"), undefined, "geen naam met een link");
});

// ---------- opmaak ----------

const R = () => buildRecap(ROWS, "2026-10", "Europe/Amsterdam")!;

Deno.test("opmaak NL: kop, aanhef, tegels, secties, alt-teksten en links", () => {
  const r = R();
  r.hero!.backdrop = "/back.jpg";
  r.series[0].poster = "/bear.jpg";
  r.series[0].tmdbId = 136315;
  const m = renderRecap({ lang: "nl", recap: r, name: "Léon", unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=x", year: 2026 });
  eq(m.subject, "Jouw oktober op Bingr");
  for (const s of ["Jouw oktober 2026", "Hoi Léon,", "afleveringen", "uur gekeken", "Je eerste titel van oktober", "Meest bekeken series",
    "Meest bekeken films", "Je laatste titel van oktober", "Volgende aflevering", "Meest gekeken zender", "NPO 1", "Uren inclusief live tv.", "Afmelden"]) {
    ok(m.html.includes(s), `html mist "${s}"`);
  }
  ok(m.html.includes('src="https://image.tmdb.org/t/p/w780/back.jpg"') && m.html.includes('alt="The Bear"'), "kop met backdrop en alt");
  ok(m.html.includes('src="https://image.tmdb.org/t/p/w342/bear.jpg" width="156" height="234" alt="The Bear"'), "poster in één formaat met alt");
  ok(!/<img(?![^>]*alt=")/.test(m.html), "elke afbeelding heeft een alt-tekst");
  ok(m.html.includes("https://bingr.online/titel/?type=tv&amp;id=136315&amp;q=The%20Bear&amp;y=2022"), "link met TMDB-id");
  ok(m.html.includes("https://bingr.online/titel/?type=movie&amp;q=Up"), "link zonder TMDB-id: zoeken op titel");
  ok(m.html.includes("S1 · A5"), "volgende aflevering");
  ok(m.html.includes(">15</div>"), "uren (boven de 10 afgerond)");
  ok(m.text.includes("Hoi Léon,") && m.text.includes("Meest bekeken series") && m.text.includes("1. The Bear"), "tekstversie");
  ok(!m.html.includes("Voorbeeld met voorbeeldgegevens"), "geen voorbeeldlabel");
});

Deno.test("opmaak EN, zonder naam, escapen, voorbeeld", () => {
  const r = R();
  r.series[1].title = `<script>alert(1)</script>`;
  const m = renderRecap({ lang: "en", recap: r, unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news", preview: true, sample: true });
  eq(m.subject, "[Voorbeeld] Your October on Bingr");
  ok(m.html.includes("Your October 2026") && m.html.includes("Most watched series") && m.html.includes("Up next") && m.html.includes("S1 · E5"), "Engels");
  ok(!m.html.includes("Hi ") || !/Hi [^<]*,<\/p>/.test(m.html), "geen aanhef zonder naam");
  ok(!m.html.includes("<script>alert") && m.html.includes("&lt;script&gt;"), "titel ge-escaped");
  ok(m.html.includes("Preview with sample data"), "voorbeeldlabel");
  ok(m.html.includes(">15</div>") && m.html.includes(">14</div>"), "uren en afleveringen");
});

Deno.test("tijden en duur in de taal en tijdzone van het account", () => {
  eq(whenText("nl", "2026-10-04T18:14:00Z", "Europe/Amsterdam"), "zo 4 okt · 20:14");
  eq(whenText("en", "2026-10-04T18:14:00Z", "America/New_York"), "Sun Oct 4 · 14:14");
  eq(whenText("nl", "2026-10-04T18:14:00Z", "Europe/Amsterdam", true), "zo 4 okt", "bij benadering: alleen de dag");
  eq(duration("nl", 574), "9 u 34 min");
  eq(duration("en", 574), "9h 34m");
  eq(duration("nl", 45), "45 min");
  eq(hoursText("nl", 90), "1,5");
  eq(hoursText("en", 60 * 42.4), "42");
  eq(recapUrl({ type: "tv", key: "k", title: "A & B", plays: 1, minutes: 1, episodes: 0, year: 2020 }), "https://bingr.online/titel/?type=tv&q=A%20%26%20B&y=2020");
});

Deno.test("TMDB: id, poster en volgende aflevering (nep-TMDB), voorbeeldgegevens", async () => {
  const calls: string[] = [];
  const fake = (async (u: URL | string) => {
    const url = new URL(String(u)), p = url.pathname.replace("/3", "");
    calls.push(p);
    const body = p === "/search/tv" ? { results: [{ id: 136315, name: "The Bear", first_air_date: "2022-06-23", poster_path: "/bear.jpg", backdrop_path: "/bearb.jpg" }] }
      : p === "/search/movie" ? { results: [{ id: 1, title: url.searchParams.get("query"), release_date: "2024-01-01", poster_path: "/m.jpg" }] }
      : p === "/tv/136315/season/1/episode/5" ? { season_number: 1, episode_number: 5, name: "Sheridan", air_date: "2022-06-23" }
      : p.startsWith("/tv/") || p.startsWith("/movie/") ? { id: Number(p.split("/")[2]), name: "X", title: "X", poster_path: "/x.jpg", backdrop_path: "/xb.jpg" }
      : {};
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  const learned: string[] = [];
  const r = await enrichRecap(R(), "nl", "0123456789abcdef0123456789abcdef", { fetch: fake, learn: (t) => learned.push(t.key) });
  eq([r.series[0].tmdbId, r.series[0].poster, r.hero?.backdrop], [136315, "/bear.jpg", "/bearb.jpg"], "gevonden via zoeken");
  eq([r.upNext?.episode, r.upNext?.episodeName], [5, "Sheridan"], "volgende aflevering met naam");
  ok(learned.includes("episode:s1"), "gevonden id wordt bewaard");
  ok(!calls.some((c) => c.includes("api_key")), "sleutel niet in het pad");
  eq(metaOf({ id: 5, adult: true }, "movie"), null, "geen volwassen titels");
  // voorbeeld: vaste gegevens met TMDB-id's, nooit van een echte gebruiker
  const s = buildRecap(sampleRows("2026-10"), "2026-10", "Europe/Amsterdam")!;
  ok(s.series.length === 3 && s.movies.length === 3 && s.series.every((t) => t.tmdbId) && s.channel?.title === "NPO 1", "voorbeeldgegevens");
  eq([s.first?.title, s.first?.season, s.first?.episode], ["The Bear", 3, 1]);
});
