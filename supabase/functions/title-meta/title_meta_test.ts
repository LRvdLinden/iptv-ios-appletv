// Unittests voor de functie title-meta: deno test supabase/functions/title-meta/title_meta_test.ts (zonder netwerk)
import { cacheKey, canonicalUrl, Limiter, parseQuery, searchQuery, toMeta } from "./logic.ts";
function assertEquals(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

const P = (s: string) => new URLSearchParams(s);

Deno.test("parseQuery: geldig en ongeldig", () => {
  assertEquals(parseQuery(P("type=movie&id=603&q=The%20Matrix&y=1999")), { kind: "movie", id: 603, q: "The Matrix", y: 1999 });
  assertEquals(parseQuery(P("type=tv&q=Dark")), { kind: "tv", id: null, q: "Dark", y: null });
  assertEquals(parseQuery(P("type=tv&id=1&y=abcd")), { kind: "tv", id: 1, q: "", y: null });
  for (const bad of ["", "type=person&id=1", "type=movie", "type=movie&id=0", "type=movie&id=12a", "type=movie&id=-1",
    "type=movie&id=12345678901", "type=movie&q=%20%0A"]) {
    assertEquals(parseQuery(P(bad)), null, bad);
  }
  assertEquals(parseQuery(P("type=movie&q=a%00b"))?.q, "a b");
  assertEquals(parseQuery(P("type=movie&q=" + "x".repeat(300)))?.q.length, 200);
});

Deno.test("cacheKey en searchQuery", () => {
  assertEquals(cacheKey({ kind: "movie", id: 603, q: "x", y: null }), "movie:603");
  assertEquals(cacheKey({ kind: "tv", id: null, q: "Dark", y: 2017 }), "s:tv:dark:2017");
  assertEquals(searchQuery({ kind: "tv", id: null, q: "Dark", y: 2017 }, "nl-NL")[1].first_air_date_year, "2017");
  assertEquals(searchQuery({ kind: "movie", id: null, q: "Up", y: 2009 }, "nl-NL")[1].primary_release_year, "2009");
  assertEquals(searchQuery({ kind: "movie", id: null, q: "Up", y: null }, "nl-NL")[0], "/search/movie");
});

Deno.test("toMeta: nl met terugval en, afbeeldingen, jaar", () => {
  const nl = { id: 603, title: "The Matrix", overview: "", release_date: "1999-03-30", poster_path: "/p.jpg", backdrop_path: "/b.jpg" };
  const en = { id: 603, title: "The Matrix", overview: "A hacker learns...", release_date: "1999-03-30" };
  const m = toMeta("movie", nl, en)!;
  assertEquals(m.year, 1999);
  assertEquals(m.overview, { nl: "A hacker learns...", en: "A hacker learns..." });
  assertEquals(m.backdrop, "https://image.tmdb.org/t/p/w1280/b.jpg");
  assertEquals(m.poster, "https://image.tmdb.org/t/p/w780/p.jpg");
  assertEquals(m.image, { url: "https://image.tmdb.org/t/p/w1280/b.jpg", width: 1280, height: 720 });
  assertEquals(m.url, "https://bingr.online/titel/?type=movie&id=603&q=The%20Matrix&y=1999");
});

Deno.test("toMeta: serie, alleen poster, vreemde paden genegeerd", () => {
  const m = toMeta("tv", { id: 70523, name: "Dark", overview: "NL tekst", first_air_date: "2017-12-01", poster_path: "/p.jpg", backdrop_path: "../x" }, null)!;
  assertEquals(m.title, { nl: "Dark", en: "Dark" });
  assertEquals(m.overview.en, "NL tekst");
  assertEquals(m.backdrop, null);
  assertEquals(m.image, { url: "https://image.tmdb.org/t/p/w780/p.jpg", width: 780, height: 1170 });
  assertEquals(toMeta("tv", { id: 1 }, null), null);
  assertEquals(toMeta("movie", null, null), null);
});

Deno.test("canonicalUrl en Limiter", () => {
  assertEquals(canonicalUrl("tv", 1, "A & B", null), "https://bingr.online/titel/?type=tv&id=1&q=A%20%26%20B");
  const l = new Limiter(2, 1000);
  assertEquals([l.allow("a", 0), l.allow("a", 1), l.allow("a", 2), l.allow("b", 2), l.allow("a", 1001)], [true, true, false, true, true]);
});
