// Unittests voor de functie introdb: deno test supabase/functions/introdb/introdb_test.ts (zonder netwerk)
import { cacheKey, fresh, parseBody, toResult, url } from "./logic.ts";
function assertEquals(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("parseBody", () => {
  assertEquals(parseBody({ tmdb: 1396, imdb: "tt0903747", season: 1, episode: 2 }), { tmdb: 1396, imdb: "tt0903747", season: 1, episode: 2 });
  assertEquals(parseBody({ tmdb: "1396", season: 0, episode: 1 }), { tmdb: 1396, imdb: null, season: 0, episode: 1 });
  assertEquals(parseBody({ tmdb: 1, season: 1, episode: 1, imdb: "x" })?.imdb, null);
  for (const bad of [null, {}, { tmdb: 1396 }, { tmdb: 0, season: 1, episode: 1 }, { tmdb: 1, season: -1, episode: 1 },
    { tmdb: 1, season: 1, episode: 1.5 }, [1]]) {
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
