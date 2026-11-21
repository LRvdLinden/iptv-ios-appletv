// Unittests voor de functie introdb: deno test supabase/functions/introdb/introdb_test.ts (zonder netwerk)
import { cacheKey, cleanTitle, fresh, parseBody, showId, showKey, showQueries, titleYear, toResult, url } from "./logic.ts";
function assertEquals(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("parseBody", () => {
  assertEquals(parseBody({ tmdb: 1396, imdb: "tt0903747", season: 1, episode: 2 }), { tmdb: 1396, imdb: "tt0903747", season: 1, episode: 2 });
  assertEquals(parseBody({ tmdb: "1396", season: 0, episode: 1 }), { tmdb: 1396, imdb: null, season: 0, episode: 1 });
  assertEquals(parseBody({ tmdb: 1, season: 1, episode: 1, imdb: "x" })?.imdb, null);
  for (const bad of [null, {}, { tmdb: 1396 }, { tmdb: 0, season: 1, episode: 1 }, { tmdb: 1, season: -1, episode: 1 },
    { tmdb: 1, season: 1, episode: 1.5 }, [1], { season: 1, episode: 1 }, { title: "", season: 1, episode: 1 },
    { title: "Dark", season: 1 }, { title: "Dark", tmdb: "x", season: 1, episode: 1 }, { title: 5, season: 1, episode: 1 }]) {
    assertEquals(parseBody(bad), null, JSON.stringify(bad));
  }
});

Deno.test("cacheKey en url", () => {
  const w = { tmdb: 1396, imdb: "tt0903747", season: 1, episode: 2 };
  assertEquals(cacheKey(w), "introdb:1396:1:2");
  assertEquals(url(w), "https://api.theintrodb.org/v4/media?tmdb_id=1396&imdb_id=tt0903747&season=1&episode=2");
  assertEquals(url({ ...w, imdb: null }), "https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=2");
});

Deno.test("toResult: milliseconden → seconden", () => {
  assertEquals(toResult({ tvdb_id: 1, type: "tv", intro: [{ start_ms: 12500, end_ms: 75000 }], recap: [{ start_ms: null, end_ms: 40000 }],
    credits: [{ start_ms: 2580000, end_ms: null }] }),
    { intro: { start: 12.5, end: 75 }, recap: { start: 0, end: 40 }, credits: { start: 2580 } });
  assertEquals(toResult({ intro: [{ start_ms: 1000, end_ms: null }, { start_ms: 2000, end_ms: 62000 }] }),
    { intro: { start: 2, end: 62 }, recap: null, credits: null });
  assertEquals(toResult({ intro: [], credits: [] }), null);
  assertEquals(toResult({ intro: [{ start_ms: 5000, end_ms: 4000 }] }), null);
  assertEquals(toResult(null), null);
  assertEquals(toResult({ intro: "x" }), null);
});

Deno.test("fresh: 30 dagen gevonden, 1 dag niet gevonden", () => {
  const now = Date.parse("2026-11-15T12:00:00Z");
  assertEquals(fresh("2026-10-20T12:00:00Z", true, now), true);
  assertEquals(fresh("2026-10-15T11:00:00Z", true, now), false);
  assertEquals(fresh("2026-11-15T00:00:00Z", false, now), true);
  assertEquals(fresh("2026-11-14T11:00:00Z", false, now), false);
});

Deno.test("parseBody: build 186, zonder tmdb met titel/jaar/imdb", () => {
  assertEquals(parseBody({ title: "NL | Breaking Bad (2008) 4K", season: 1, episode: 2 }),
    { tmdb: null, title: "Breaking Bad", year: 2008, imdb: null, season: 1, episode: 2 });
  assertEquals(parseBody({ title: "Dark", year: 2017, imdb: "tt5753856", season: 1, episode: 1 }),
    { tmdb: null, title: "Dark", year: 2017, imdb: "tt5753856", season: 1, episode: 1 });
  assertEquals((parseBody({ tmdb: null, title: "Dark", year: "1800", season: 1, episode: 1 }) as { year?: unknown })?.year, null);
  assertEquals(parseBody({ imdb: "tt0903747", season: 2, episode: 3 }),
    { tmdb: null, title: "", year: null, imdb: "tt0903747", season: 2, episode: 3 });
});

Deno.test("cleanTitle en titleYear", () => {
  const cases: [string, string][] = [
    ["NL | Breaking Bad (2008)", "Breaking Bad"], ["[NL] The Office (US) FHD", "The Office"], ["EN - Dark S01E02", "Dark"],
    ["NCIS: Hawaii", "NCIS: Hawaii"], ["BBC - Planet Earth", "BBC - Planet Earth"], ["It: Welcome to Derry", "It: Welcome to Derry"],
    ["NL SUBS | Shōgun 4K HEVC", "Shōgun"], ["The.Last.Of.Us.2023", "The Last Of Us 2023"], ["Fargo - 2014", "Fargo"],
    ["Slow Horses ¦ NL", "Slow Horses"], ["Lupin - FR", "Lupin"], ["  ", ""],
  ];
  for (const [raw, want] of cases) assertEquals(cleanTitle(raw), want, raw);
  assertEquals(titleYear("Breaking Bad (2008)"), 2008);
  assertEquals(titleYear("Fargo - 2014"), 2014);
  assertEquals(titleYear("Blade Runner 2049"), null);
});

Deno.test("showKey, showQueries en showId", () => {
  const l = { tmdb: null, title: "Shōgun", year: 2024, imdb: "tt2788316", season: 1, episode: 1 } as const;
  assertEquals(showKey(l), "introdb-show:shogun:2024");
  assertEquals(showKey({ ...l, title: "The Office!", year: null }), "introdb-show:the office:");
  assertEquals(showQueries(l), [
    ["/find/tt2788316", { external_source: "imdb_id" }],
    ["/search/tv", { query: "Shōgun", include_adult: "false", page: "1", first_air_date_year: "2024" }],
    ["/search/tv", { query: "Shōgun", include_adult: "false", page: "1" }],
  ]);
  assertEquals(showQueries({ ...l, imdb: null, year: null }).length, 1);
  assertEquals(showId({ movie_results: [{ id: 1 }], tv_results: [{ id: 126308 }] }), 126308);
  assertEquals(showId({ results: [{ id: 1396 }, { id: 2 }] }), 1396);
  assertEquals(showId({ results: [] }), null);
  assertEquals(showId({ tv_results: [], results: [{ id: 5 }] }), null);
  assertEquals(showId(null), null);
});
