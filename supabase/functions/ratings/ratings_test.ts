// Unittests voor de functie ratings: deno test supabase/functions/ratings/ratings_test.ts (zonder netwerk)
import { cacheKey, fresh, mapSource, mdblistPaths, parseBody, toRatings } from "./logic.ts";
function assertEquals(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("parseBody: geldig en ongeldig", () => {
  assertEquals(parseBody({ type: "movie", tmdb: 550 }), { kind: "movie", tmdb: 550, imdb: null });
  assertEquals(parseBody({ type: "tv", tmdb: "1396" }), { kind: "show", tmdb: 1396, imdb: null });
  assertEquals(parseBody({ imdb: "tt0137523" }), { kind: null, tmdb: null, imdb: "tt0137523" });
  assertEquals(parseBody({ type: "show", imdb: "tt0903747" }), { kind: "show", tmdb: null, imdb: "tt0903747" });
  for (const bad of [null, [], "x", {}, { tmdb: 550 }, { type: "movie", tmdb: 0 }, { type: "movie", tmdb: -1 }, { type: "person", tmdb: 1 },
    { imdb: "nm123" }, { imdb: "tt1/../x" }, { type: "movie", tmdb: 1.5 }]) {
    assertEquals(parseBody(bad), null, JSON.stringify(bad));
  }
});

Deno.test("cacheKey en paden", () => {
  assertEquals(cacheKey({ kind: "movie", tmdb: 550, imdb: null }), "movie:550");
  assertEquals(cacheKey({ kind: "show", tmdb: 1396, imdb: "tt0903747" }), "show:1396");
  assertEquals(cacheKey({ kind: null, tmdb: null, imdb: "tt0137523" }), "imdb:tt0137523");
  assertEquals(mdblistPaths({ kind: "show", tmdb: 1396, imdb: null }), ["/tmdb/show/1396"]);
  assertEquals(mdblistPaths({ kind: null, tmdb: null, imdb: "tt1" + "234567" }), ["/imdb/movie/tt1234567", "/imdb/show/tt1234567"]);
});

Deno.test("toRatings: bronnen, schalen en volgorde", () => {
  const j = { ratings: [
    { source: "trakt", value: 86, score: 86, votes: 1000 },
    { source: "imdb", value: 8.8, score: 88, votes: 2300000 },
    { source: "metacritic", value: 66, score: 66 },
    { source: "tomatoes", value: 79, score: 79 },
    { source: "popcorn", value: 96, score: 96 },
    { source: "letterboxd", value: 4.3, score: 86 },
    { source: "tmdb", value: 84, score: 84 },
    { source: "rogerebert", value: 4, score: 100 },
    { source: "myanimelist", value: null, score: null },
    { source: "imdb", value: 1, score: 10 },
    { source: "tomatoes", value: null },
  ] };
  assertEquals(toRatings(j), [
    { source: "imdb", value: 8.8, votes: 2300000 }, { source: "tmdb", value: 8.4 }, { source: "tomatoes", value: 79 },
    { source: "tomatoesaudience", value: 96 }, { source: "metacritic", value: 66 }, { source: "letterboxd", value: 4.3 },
    { source: "trakt", value: 86, votes: 1000 },
  ]);
  assertEquals(toRatings({ ratings: [{ source: "imdb", value: null, score: 72 }] }), [{ source: "imdb", value: 7.2 }]);
  assertEquals(toRatings({ ratings: [{ source: "metacritic", value: 0, score: 0 }] }), []);
  assertEquals(toRatings(null), []);
  assertEquals(toRatings({ ratings: "x" }), []);
  assertEquals(mapSource("Popcorn"), "tomatoesaudience");
  assertEquals(mapSource("x"), null);
});

Deno.test("fresh: 7 dagen", () => {
  const now = Date.parse("2026-11-15T12:00:00Z");
  assertEquals(fresh("2026-11-09T12:00:00Z", now), true);
  assertEquals(fresh("2026-11-08T11:59:00Z", now), false);
  assertEquals(fresh("2026-11-20T12:00:00Z", now), false);
  assertEquals(fresh(null, now), false);
  assertEquals(fresh("x", now), false);
});
