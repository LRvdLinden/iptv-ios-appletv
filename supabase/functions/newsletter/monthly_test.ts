// Unittests voor het maandoverzicht "Volgende maand op Bingr": deno test supabase/functions/newsletter/monthly_test.ts
// Zonder netwerk (nep-TMDB). Planning (laatste dag van de maand 18:00 Amsterdam, zomer-/wintertijd, februari, schrikkeljaar,
// nooit twee keer), selectie (datumbereik, max. 6, geen dubbele) en opmaak (3 × 2, alt-teksten, NL en EN).
import { type Item, titleUrl } from "./logic.ts";
import {
  buildMonthly, buildMonthlyContent, cardTitle, fromLabel, isLastDayOfMonth, monthAfter, monthlyDue, monthlyQueries, monthName, monthRange,
  nextMonthly, nlRelease, renderMonthly, seasonStart, shownMonthly, validMonth,
} from "./monthly.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }
const at = (iso: string) => Date.parse(iso);
const it = (type: "movie" | "tv", id: number, date: string, extra: Partial<Item> = {}): Item => ({
  type, id, title: `${type} ${id}`, year: Number(date.slice(0, 4)), date, overview: "Omschrijving", poster: `/p${id}.jpg`, backdrop: `/b${id}.jpg`, ...extra,
});

// ---------- planning ----------

Deno.test("planning: laatste dag van de maand 18:00 Amsterdam, wintertijd (31 okt 2026 = 17:00 UTC)", () => {
  eq(monthlyDue(at("2026-10-31T17:00:00Z")), { key: "2026-11", at: "2026-10-31T17:00:00.000Z" }, "18:00 CET");
  eq(monthlyDue(at("2026-10-31T17:05:00Z"))?.key, "2026-11", "ronde iets later in het uur");
  eq(monthlyDue(at("2026-10-31T16:00:00Z")), null, "17:00 lokaal: nog niet");
  eq(monthlyDue(at("2026-10-30T17:00:00Z")), null, "30 oktober is niet de laatste dag");
  eq(monthlyDue(at("2026-11-01T17:00:00Z")), null, "1 november niet");
  // speling: mislukt de ronde van 18:00, dan nog om 19:00 en 20:00 (zelfde sleutel), daarna niet meer
  eq(monthlyDue(at("2026-10-31T19:00:00Z"))?.key, "2026-11", "20:00 lokaal: speling");
  eq(monthlyDue(at("2026-10-31T20:00:00Z")), null, "21:00 lokaal: voorbij");
});

Deno.test("planning: zomertijd (16:00 UTC), jaarwisseling en de dag van de klokwissel zelf", () => {
  eq(monthlyDue(at("2026-07-31T16:00:00Z"))?.key, "2026-08", "18:00 CEST = 16:00 UTC");
  eq(monthlyDue(at("2026-07-31T15:00:00Z")), null, "17:00 CEST");
  eq(monthlyDue(at("2026-12-31T17:00:00Z"))?.key, "2027-01", "december -> januari volgend jaar");
  // 2027: zomertijd begint 28 maart, eindigt 31 oktober (de laatste dag zelf)
  eq(monthlyDue(at("2027-03-31T16:00:00Z"))?.key, "2027-04", "31 maart 2027 (al zomertijd)");
  eq(monthlyDue(at("2027-10-31T17:00:00Z"))?.key, "2027-11", "31 oktober 2027, dag van de wissel: 18:00 CET");
  eq(monthlyDue(at("2027-10-31T15:00:00Z")), null, "16:00 CET");
});

Deno.test("planning: februari en schrikkeljaar", () => {
  eq(monthlyDue(at("2027-02-28T17:00:00Z"))?.key, "2027-03", "28 februari 2027");
  eq(monthlyDue(at("2027-02-27T17:00:00Z")), null, "27 februari 2027");
  eq(monthlyDue(at("2028-02-28T17:00:00Z")), null, "28 februari 2028 (schrikkeljaar) is niet de laatste");
  eq(monthlyDue(at("2028-02-29T17:00:00Z"))?.key, "2028-03", "29 februari 2028");
  ok(isLastDayOfMonth("2028-02-29") && !isLastDayOfMonth("2028-02-28") && isLastDayOfMonth("2027-02-28"), "laatste dag");
  eq(monthRange("2028-02"), { first: "2028-02-01", last: "2028-02-29" }, "februari 2028");
  eq(monthRange("2027-02").last, "2027-02-28", "februari 2027");
  eq(monthRange("2026-11"), { first: "2026-11-01", last: "2026-11-30" }, "november");
  eq(monthRange("2026-12").last, "2026-12-31", "december");
  eq([monthAfter("2026-10-31"), monthAfter("2026-12-31")], ["2026-11", "2027-01"], "volgende maand");
  ok(validMonth("2026-11") && !validMonth("2026-13") && !validMonth("2026-11-01-sun"), "sleutel");
});

Deno.test("planning: volgende verzending (eerste keer zaterdag 31 oktober 2026 18:00)", () => {
  eq(nextMonthly(at("2026-10-30T15:00:00Z")), { key: "2026-11", at: "2026-10-31T17:00:00.000Z" }, "vanaf vandaag");
  eq(nextMonthly(at("2026-10-31T17:00:00Z")), { key: "2026-12", at: "2026-11-30T17:00:00.000Z" }, "strikt later");
  eq(nextMonthly(at("2027-02-01T00:00:00Z")), { key: "2027-03", at: "2027-02-28T17:00:00.000Z" }, "februari");
  eq(nextMonthly(at("2027-07-01T00:00:00Z")).at, "2027-07-31T16:00:00.000Z", "zomertijd");
  eq(new Date("2026-10-31T17:00:00Z").getUTCDay(), 6, "31 oktober 2026 is een zaterdag");
});

Deno.test("planning: elk uur een cron-ronde over drie jaar: precies één editie per maand, altijd om 18:00 op de laatste dag", () => {
  const made = new Map<string, number>();
  for (let t = at("2026-10-01T00:00:00Z"); t < at("2029-10-01T00:00:00Z"); t += 3600_000) {
    for (const off of [0, 5 * 60_000]) { // ook een tweede ronde in hetzelfde uur (opnieuw gestart)
      const d = monthlyDue(t + off);
      if (d && !made.has(d.key)) made.set(d.key, t + off); // unieke sleutel: nooit twee keer
    }
  }
  eq(made.size, 36, "36 maanden");
  const fmt = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Amsterdam", hour: "2-digit", hourCycle: "h23" });
  for (const [key, t] of made) {
    eq(fmt.format(new Date(t)), "18", `${key} om 18 uur`);
    const local = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Amsterdam" }).format(new Date(t));
    ok(isLastDayOfMonth(local) && monthAfter(local) === key, `${key} op de laatste dag (${local})`);
  }
  ok(made.has("2026-11") && made.has("2028-03") && made.has("2029-01"), "maanden");
});

// ---------- selectie ----------

Deno.test("selectie: TMDB-verzoeken voor het datumbereik van de volgende maand", () => {
  const q = monthlyQueries("nl", "2026-11");
  eq(q.cinema[0], "/discover/movie");
  eq([q.cinema[1].region, q.cinema[1].with_release_type, q.cinema[1]["release_date.gte"], q.cinema[1]["release_date.lte"], q.cinema[1].sort_by],
    ["NL", "2|3", "2026-11-01", "2026-11-30", "popularity.desc"], "bioscoop");
  eq([q.streaming[1].with_release_type, q.streaming[1]["release_date.lte"]], ["4|5", "2026-11-30"], "streaming en digitaal");
  eq([q.newTv[0], q.newTv[1]["first_air_date.gte"], q.newTv[1]["first_air_date.lte"]], ["/discover/tv", "2026-11-01", "2026-11-30"], "nieuwe series");
  eq([q.seasonTv[1]["air_date.gte"], q.seasonTv[1]["air_date.lte"]], ["2026-11-01", "2026-11-30"], "nieuwe seizoenen");
  eq(monthlyQueries("en", "2028-02").cinema[1]["release_date.lte"], "2028-02-29", "schrikkeljaar");
  eq(monthlyQueries("en", "2026-11").cinema[1].language, "en-US", "taal");
});

Deno.test("selectie: Nederlandse releasedatum en begin van een nieuw seizoen", () => {
  const rd = { results: [
    { iso_3166_1: "US", release_dates: [{ type: 3, release_date: "2026-11-02T00:00:00.000Z" }] },
    { iso_3166_1: "NL", release_dates: [
      { type: 1, release_date: "2026-11-01T00:00:00.000Z" }, { type: 3, release_date: "2026-11-20T00:00:00.000Z" },
      { type: 3, release_date: "2026-11-14T00:00:00.000Z" }, { type: 4, release_date: "2026-11-05T00:00:00.000Z" },
      { type: 3, release_date: "2026-12-01T00:00:00.000Z" },
    ] },
  ] };
  eq(nlRelease(rd, [2, 3], "2026-11"), "2026-11-14", "vroegste NL-bioscoopdatum in de maand");
  eq(nlRelease(rd, [4, 5], "2026-11"), "2026-11-05", "digitaal");
  eq(nlRelease(rd, [2, 3], "2026-12"), "2026-12-01", "andere maand");
  eq(nlRelease({ results: [] }, [3], "2026-11"), null, "geen NL");
  eq(nlRelease(null, [3], "2026-11"), null, "geen antwoord");
  const tv = { seasons: [
    { season_number: 0, air_date: "2026-11-01" }, { season_number: 1, air_date: "2024-03-01" },
    { season_number: 2, air_date: "2025-05-01" }, { season_number: 3, air_date: "2026-11-12" },
  ] };
  eq(seasonStart(tv, "2026-11"), { season: 3, date: "2026-11-12" }, "seizoen 3");
  eq(seasonStart(tv, "2026-12"), null, "geen nieuw seizoen in december");
  eq(seasonStart({ seasons: [{ season_number: 1, air_date: "2026-11-03" }] }, "2026-11"), null, "seizoen 1 = nieuwe serie, niet hier");
});

Deno.test("selectie: alleen de volgende maand, max. 12 kandidaten, max. 6 getoond, geen dubbele, op datum", () => {
  const cinema = [it("movie", 1, "2026-11-20"), it("movie", 2, "2026-10-30"), it("movie", 3, "2026-12-01"), ...Array.from({ length: 15 }, (_, k) => it("movie", 10 + k, `2026-11-${String(28 - k).padStart(2, "0")}`))];
  const streaming = [it("movie", 1, "2026-11-25"), it("movie", 40, "2026-11-03"), it("movie", 41, "2026-11-02")];
  const newTv = [it("tv", 1, "2026-11-07"), it("tv", 2, "2026-11-01")];
  const seasons = [it("tv", 3, "2026-11-12", { season: 3 }), it("tv", 1, "2026-11-07")];
  const e = buildMonthly({ cinema, streaming, newTv, seasons }, "2026-11");
  ok([...e.cinema, ...e.streaming, ...e.series].every((x) => x.date!.startsWith("2026-11")), "alleen november");
  ok(!e.cinema.some((x) => x.id === 2 || x.id === 3), "oktober en december vallen weg");
  eq(e.cinema.length, 12, "max. 12 kandidaten");
  ok(!e.streaming.some((x) => x.id === 1), "film 1 staat al bij de bioscoop");
  eq(e.series.map((x) => x.id), [1, 3, 2], "series om en om, geen dubbele");
  eq(e.featured && `${e.featured.type}:${e.featured.id}`, "movie:1", "uitgelicht: populairste met achtergrond");
  const s = shownMonthly(e);
  ok(s.cinema.length === 6 && s.streaming.length <= 6 && s.series.length <= 6, "max. 6 per sectie");
  ok(!s.cinema.some((x) => x.id === 1), "uitgelicht niet nog eens in het raster");
  const refs = [s.featured, ...s.cinema, ...s.streaming, ...s.series].map((x) => `${x!.type}:${x!.id}`);
  eq(new Set(refs).size, refs.length, "geen titel twee keer");
  const dates = s.cinema.map((x) => x.date!);
  eq(dates, [...dates].sort(), "op datum");
});

/** Nep-TMDB: discover per soort (taal-afhankelijke titels), releasedatums en seizoenen. */
function fakeTmdb(): { f: typeof fetch; calls: string[] } {
  const calls: string[] = [];
  const res = (x: unknown) => new Response(JSON.stringify(x), { status: 200, headers: { "Content-Type": "application/json" } });
  const f = (async (input: URL | string) => {
    const u = new URL(String(input)), p = u.pathname.replace(/^\/3/, ""), en = u.searchParams.get("language") === "en-US";
    calls.push(p + (u.searchParams.get("with_release_type") ? `?${u.searchParams.get("with_release_type")}` : "") + (u.searchParams.get("air_date.gte") ? "?air" : ""));
    const t = (id: number, nl: string, e: string, extra: Record<string, unknown> = {}) =>
      ({ id, title: en ? e : nl, name: en ? e : nl, overview: en ? `EN ${e}` : `NL ${nl}`, poster_path: `/p${id}.jpg`, backdrop_path: `/b${id}.jpg`, genre_ids: [18], vote_average: 7.4, vote_count: 50, ...extra });
    if (p === "/genre/movie/list" || p === "/genre/tv/list") return res({ genres: [{ id: 18, name: en ? "Drama" : "Drama" }, { id: 35, name: en ? "Comedy" : "Komedie" }] });
    if (p === "/discover/movie" && u.searchParams.get("with_release_type") === "2|3") {
      return res({ results: [t(1, "Bioscoop <één>", "Cinema <one>", { release_date: "2026-11-02" }), t(2, "Film twee", "Movie two", { release_date: "2026-10-01", genre_ids: [35] })] });
    }
    if (p === "/discover/movie") return res({ results: [t(1, "Bioscoop <één>", "Cinema <one>"), t(3, "Digitaal", "Digital", { release_date: "2026-11-09" })] });
    if (p === "/discover/tv" && u.searchParams.get("first_air_date.gte")) return res({ results: [t(7, "Nieuwe serie", "New show", { first_air_date: "2026-11-21" })] });
    if (p === "/discover/tv") return res({ results: [t(7, "Nieuwe serie", "New show", { first_air_date: "2026-11-21" }), t(8, "Oude serie", "Old show", { first_air_date: "2019-01-01" }), t(9, "Geen seizoen", "No season", { first_air_date: "2020-01-01" })] });
    if (p === "/movie/1/release_dates") return res({ results: [{ iso_3166_1: "NL", release_dates: [{ type: 3, release_date: "2026-11-14T00:00:00.000Z" }] }] });
    if (p === "/movie/2/release_dates") return res({ results: [{ iso_3166_1: "NL", release_dates: [{ type: 3, release_date: "2026-11-26T00:00:00.000Z" }] }] });
    if (p === "/movie/3/release_dates") return res({ results: [{ iso_3166_1: "NL", release_dates: [{ type: 4, release_date: "2026-11-09T00:00:00.000Z" }] }] });
    if (p === "/tv/8") return res({ id: 8, seasons: [{ season_number: 1, air_date: "2019-01-01" }, { season_number: 4, air_date: "2026-11-05" }] });
    if (p === "/tv/9") return res({ id: 9, seasons: [{ season_number: 1, air_date: "2020-01-01" }, { season_number: 2, air_date: "2026-08-05" }] });
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  return { f, calls };
}

Deno.test("selectie: hele opbouw met nep-TMDB (NL-datums, nieuwe seizoenen, Engelse teksten, genres)", async () => {
  const { f, calls } = fakeTmdb();
  const c = await buildMonthlyContent("2026-11", "0123456789abcdef0123456789abcdef", f);
  ok(calls.includes("/discover/movie?2|3") && calls.includes("/discover/movie?4|5") && calls.includes("/discover/tv?air"), "verzoeken");
  eq(c.nl.featured?.id, 1, "uitgelicht");
  eq(c.nl.featured?.date, "2026-11-14", "NL-bioscoopdatum in plaats van de wereldwijde");
  eq(c.nl.cinema.map((x) => [x.id, x.date]), [[1, "2026-11-14"], [2, "2026-11-26"]], "bioscoop (film 2 heeft een NL-datum in november)");
  eq(c.nl.streaming.map((x) => x.id), [3], "streaming zonder film 1 (al in de bioscoop)");
  eq(c.nl.series.map((x) => [x.id, x.date, x.season ?? null]), [[7, "2026-11-21", null], [8, "2026-11-05", 4]], "nieuwe serie + seizoen 4; seizoen buiten de maand valt weg");
  eq(c.en.series[1].title, "Old show", "Engelse titel");
  eq(c.en.cinema[1].genre, "Comedy", "Engels genre");
  eq(c.nl.cinema[1].genre, "Komedie", "Nederlands genre");
  ok(!JSON.stringify(c.en).includes("NL "), "geen Nederlandse tekst in de Engelse editie");
  eq(c.nl.cinema[0].score, 7.4, "score");
});

// ---------- opmaak ----------

Deno.test("render: 3 × 2 per sectie, alt-teksten, links, NL en EN", async () => {
  const many = (type: "movie" | "tv", from: number, n: number, extra: Partial<Item> = {}) =>
    Array.from({ length: n }, (_, k) => it(type, from + k, `2026-11-${String(10 + k).padStart(2, "0")}`, { genre: "Drama", score: 7.1, ...extra }));
  const e = buildMonthly({ cinema: many("movie", 1, 9), streaming: many("movie", 20, 9), newTv: many("tv", 40, 4), seasons: many("tv", 60, 4, { season: 2 }) }, "2026-11");
  for (const lang of ["nl", "en"] as const) {
    const m = renderMonthly({ lang, edition: e, unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=x", year: 2026 });
    const posters = m.html.match(/<img [^>]*width="156" height="234"[^>]*>/g) ?? [];
    eq(posters.length, 18, `${lang}: 3 secties × 6 posters`);
    eq((m.html.match(/<tr><td width="31\.2%"/g) ?? []).length, 6, `${lang}: 2 rijen per sectie`);
    eq((m.html.match(/<img [^>]*width="500" height="281"[^>]*>/g) ?? []).length, 1, `${lang}: één liggende afbeelding (uitgelicht)`);
    const imgs = m.html.match(/<img [^>]*>/g) ?? [];
    ok(imgs.every((x) => /alt="[^"]+"/.test(x)), `${lang}: elke afbeelding heeft een alt-tekst`);
    ok(m.html.includes('alt="movie 2"'), `${lang}: alt = titel`);
    ok(m.html.includes(titleUrl(e.cinema[1]).replace(/&/g, "&amp;")), `${lang}: poster linkt naar de titel in Bingr`);
    ok(m.html.includes("unsubscribe/?k=news&amp;t=x") && m.text.includes("unsubscribe/?k=news&t=x"), `${lang}: afmeldlink`);
    ok(m.html.includes("★") || m.html.includes("&#9733;"), `${lang}: score`);
  }
  const nl = renderMonthly({ lang: "nl", edition: e, unsubscribeUrl: "u" }), en = renderMonthly({ lang: "en", edition: e, unsubscribeUrl: "u" });
  eq(nl.subject, "Volgende maand op Bingr: movie 1 en meer in november", "onderwerp NL");
  eq(en.subject, "Coming next month: movie 1 and more in November", "onderwerp EN");
  ok(nl.html.includes("Films in de bioscoop") && nl.html.includes("Nieuw op streaming en digitaal") && nl.html.includes("Nieuwe series en nieuwe seizoenen"), "secties NL");
  ok(en.html.includes("In cinemas") && en.html.includes("New on streaming and digital") && en.html.includes("New series and new seasons"), "secties EN");
  ok(nl.html.includes("vanaf 11 nov · Drama") && en.html.includes("from Nov 11 · Drama"), "datum in de taal van de ontvanger");
  ok(nl.html.includes("Dit komt er in november") && en.html.includes("Coming in November"), "kop");
  ok(nl.html.includes("· seizoen 2") && en.html.includes("· season 2"), "nieuw seizoen");
  ok(nl.text.includes("Films in de bioscoop") && nl.text.includes("(vanaf 11 nov · Drama, TMDB 7,1)"), "platte tekst NL");
  ok(en.text.includes("(from Nov 11 · Drama, TMDB 7.1)"), "platte tekst EN");
  ok(renderMonthly({ lang: "nl", edition: e, unsubscribeUrl: "u", preview: true }).subject.startsWith("[Voorbeeld] "), "voorbeeld");
});

Deno.test("render: escapen, lege editie, korte titels en labels", () => {
  const bad = it("movie", 5, "2026-11-03", { title: 'Film <script>alert(1)</script> "x"', overview: "<b>vet</b>" });
  const m = renderMonthly({ lang: "nl", edition: buildMonthly({ cinema: [bad], streaming: [], newTv: [], seasons: [] }, "2026-11"), unsubscribeUrl: "u" });
  ok(!m.html.includes("<script>alert") && m.html.includes("&lt;script&gt;") && !m.html.includes("<b>vet</b>"), "TMDB-tekst ge-escaped");
  const empty = renderMonthly({ lang: "en", edition: { month: "2026-12", featured: null, cinema: [], streaming: [], series: [] }, unsubscribeUrl: "u" });
  ok(empty.html.includes("No new titles are known for next month yet.") && empty.subject.includes("December"), "lege editie");
  const long = it("tv", 9, "2026-11-04", { title: "Een heel erg lange seriestitel die niet past", season: 12 });
  const ct = cardTitle("nl", long);
  ok(ct.endsWith(" · seizoen 12") && ct.includes("…") && Array.from(ct).length <= 34, `korte titel met seizoen (${ct})`);
  eq(fromLabel("en", it("movie", 1, "2026-11-30")), "from Nov 30 · Movie", "zonder genre: soort");
  eq([monthName("nl", "2027-03"), monthName("en", "2027-03")], ["maart", "March"], "maandnamen");
});
