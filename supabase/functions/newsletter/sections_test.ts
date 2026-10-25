// Unittests voor de secties Top 10 deze week en Populair: deno test supabase/functions/newsletter/sections_test.ts
// Zonder netwerk: nep-TMDB, nep-Trakt en nep-OMDb. Controleert opbouw, bronnen, links en de HTML (tags, alt-teksten).
import {
  applySections, buildEdition, type Edition, genreMap, imdbId, type Item, type Lists, omdbRating, sectionsOf, titleUrl, toItem,
  top10Of, withGenre,
} from "./logic.ts";
import { credits, renderNewsletter, scoreText } from "./render.ts";
import { buildContent } from "./tmdb.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }

const NOW = Date.parse("2026-10-25T08:00:00Z");
const it = (type: "movie" | "tv", id: number, extra: Partial<Item> = {}): Item => ({
  type, id, title: `${type} ${id}`, year: 2026, date: "2026-10-01", overview: "Omschrijving", poster: `/p${id}.jpg`, backdrop: `/b${id}.jpg`, ...extra,
});
const range = (type: "movie" | "tv", from: number, n: number) => Array.from({ length: n }, (_, k) => it(type, from + k));
const L0: Lists = { freshMovies: [], freshTv: [], soonMovies: [], soonTv: [], popularMovies: [], popularTv: [], trendMovies: [], trendTv: [] };

// ---------- opbouw ----------

Deno.test("top 10: TMDB trending eerst, dan Trakt, dan populair; geen dubbele, geen toekomst, max. 10", () => {
  const today = "2026-10-25";
  const t = top10Of(today, [it("movie", 1), it("movie", 2, { date: "2026-12-01" }), it("movie", 1)], [it("movie", 3), it("movie", 1)], range("movie", 50, 20));
  eq(t.map((x) => x.id), [1, 3, 50, 51, 52, 53, 54, 55, 56, 57], "volgorde en aanvullen");
  eq(top10Of(today, range("tv", 1, 15)).length, 10, "max. 10");
  eq(top10Of(today, undefined, []).length, 0, "leeg");
});

Deno.test("editie: Top 10 films en series apart, Populair zonder titels die al in de mail staan", () => {
  const e = buildEdition({
    ...L0,
    freshMovies: [it("movie", 900)],
    trendMovies: range("movie", 1, 12), trendTv: range("tv", 1, 8),
    traktTv: [it("tv", 1), it("tv", 40), it("tv", 41), it("tv", 42)],
    popularMovies: [it("movie", 2), it("movie", 900), it("movie", 60), it("movie", 61)], popularTv: [it("tv", 3), it("tv", 70), it("tv", 71)],
  }, NOW, new Set());
  eq(e.top10!.movies.map((x) => x.id), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "films");
  eq(e.top10!.tv.map((x) => x.id), [1, 2, 3, 4, 5, 6, 7, 8, 40, 41], "series aangevuld met Trakt");
  ok(e.top10!.movies.every((x) => x.type === "movie") && e.top10!.tv.every((x) => x.type === "tv"), "soort per rij");
  eq(e.credits, { trakt: true }, "Trakt gebruikt");
  eq(e.popular.map((x) => `${x.type}:${x.id}`), ["tv:70", "movie:60", "tv:71", "movie:61"], "populair: om en om, zonder Top 10 en uitgelicht");
  // zonder Trakt-aanvulling geen Trakt in de bronvermelding
  const e2 = buildEdition({ ...L0, trendMovies: range("movie", 1, 10), trendTv: range("tv", 1, 10), traktTv: [it("tv", 1)] }, NOW, new Set());
  eq(e2.credits, {}, "Trakt niet nodig");
});

Deno.test("schakelaars: Top 10 en Populair uit, ontbrekende kolom = aan", () => {
  const e: Edition = { featured: null, fresh: [], soon: [], popular: [it("movie", 1)], top10: { movies: [it("movie", 2)], tv: [it("tv", 3)] } };
  eq(sectionsOf(null), { top10: true, popular: true }, "standaard aan");
  eq(sectionsOf({ enabled: true }), { top10: true, popular: true }, "oude rij");
  eq(sectionsOf({ show_top10: false, show_popular: true }), { top10: false, popular: true });
  const off = applySections(e, { top10: false, popular: false });
  eq([off.popular.length, off.top10!.movies.length, off.top10!.tv.length], [0, 0, 0], "uit");
  eq(applySections(e, { top10: true, popular: true }), e, "aan = ongewijzigd");
  const h = renderNewsletter({ lang: "nl", edition: off, unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news" }).html;
  ok(!h.includes("Top 10 deze week") && !h.includes(">Populair<"), "secties niet in de mail");
});

Deno.test("TMDB-gegevens: genres, score (genoeg stemmen), IMDb-id en OMDb-score", () => {
  const x = toItem({ id: 7, title: "X", poster_path: "/a.jpg", genre_ids: [18, 80, 53, 99, "x"], vote_average: 7.849, vote_count: 500 }, "movie")!;
  eq([x.genres, x.score], [[18, 80, 53], 7.8]);
  const d = toItem({ id: 7, name: "Y", poster_path: "/a.jpg", genres: [{ id: 10765, name: "Sci-Fi" }], vote_average: 9, vote_count: 3 }, "tv")!;
  eq([d.genres, d.score], [[10765], undefined], "details-vorm; te weinig stemmen = geen score");
  const g = genreMap({ genres: [{ id: 18, name: "Drama" }, { id: 80, name: "<b>Misdaad</b>" }] }, { genres: [{ id: 18, name: "Drama (tv)" }] });
  eq(withGenre(x, g).genre, "Drama");
  eq(withGenre({ ...x, type: "tv" }, g).genre, "Drama (tv)", "genres per soort");
  eq(withGenre({ ...x, genres: [12345] }, g).genre, undefined, "onbekend genre");
  eq([imdbId("tt0111161"), imdbId("tt1"), imdbId("javascript:"), imdbId(5)], ["tt0111161", null, null, null]);
  eq([omdbRating({ Response: "True", imdbRating: "8.7" }), omdbRating({ imdbRating: "N/A" }), omdbRating({ Response: "False" }), omdbRating(null), omdbRating({ imdbRating: "11" })],
    [8.7, null, null, null, null]);
  eq([scoreText("nl", { ...x, imdb: 8.7 }), scoreText("en", { ...x, imdb: 8.7 }), scoreText("nl", x), scoreText("nl", { ...x, score: undefined })],
    ["IMDb 8,7", "IMDb 8.7", "TMDB 7,8", ""], "IMDb gaat voor, anders TMDB");
});

// ---------- ophalen (nep-API's) ----------

type Seen = { url: URL; headers: Headers };
function fakeApis(opts: { trendMovies?: number; failOmdb?: boolean } = {}) {
  const seen: Seen[] = [];
  const res = (j: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(j), { status }));
  const f = ((u: URL | string, init?: RequestInit) => {
    const url = new URL(String(u));
    seen.push({ url, headers: new Headers(init?.headers) });
    const lang = url.searchParams.get("language") ?? "";
    const en = lang === "en-US";
    const row = (type: "movie" | "tv", id: number) => ({
      id, [type === "tv" ? "name" : "title"]: `${en ? "EN" : "NL"} ${type} ${id}`, overview: en ? "English" : "Nederlands",
      poster_path: `/p${id}.jpg`, backdrop_path: `/b${id}.jpg`, [type === "tv" ? "first_air_date" : "release_date"]: "2025-05-01",
      genre_ids: [18], vote_average: 7.25, vote_count: 900,
    });
    if (url.hostname === "api.themoviedb.org") {
      const p = url.pathname.replace(/^\/3/, "");
      if (p === "/genre/movie/list" || p === "/genre/tv/list") return res({ genres: [{ id: 18, name: en ? "Drama" : "Drama NL" }] });
      if (p === "/trending/movie/week") return res({ results: Array.from({ length: opts.trendMovies ?? 12 }, (_, k) => row("movie", 1 + k)) });
      if (p === "/trending/tv/week") return res({ results: Array.from({ length: 12 }, (_, k) => row("tv", 1 + k)) });
      if (p === "/movie/popular") return res({ results: Array.from({ length: 20 }, (_, k) => row("movie", 1 + k)) });
      if (p === "/tv/popular") return res({ results: Array.from({ length: 20 }, (_, k) => row("tv", 1 + k)) });
      let m = p.match(/^\/(movie|tv)\/(\d+)\/external_ids$/);
      if (m) return res({ imdb_id: `tt${String(1000000 + Number(m[2])).padStart(7, "0")}` });
      m = p.match(/^\/(movie|tv)\/(\d+)$/);
      if (m) return res({ ...row(m[1] as "movie" | "tv", Number(m[2])), genres: [{ id: 18, name: "Drama" }] });
      return res({ results: [] }); // discover / upcoming
    }
    if (url.hostname === "api.trakt.tv") {
      const show = url.pathname.includes("shows");
      return res(Array.from({ length: 5 }, (_, k) => ({ [show ? "show" : "movie"]: { ids: { tmdb: 500 + k, imdb: `tt900000${k}` } } })));
    }
    if (url.hostname === "www.omdbapi.com") {
      if (opts.failOmdb) return res({}, 500);
      return res({ Response: "True", imdbRating: url.searchParams.get("i") === "tt9000000" ? "6.1" : "8.4" });
    }
    return res({}, 404);
  }) as typeof fetch;
  return { f, seen };
}

Deno.test("ophalen: Top 10 en Populair uit TMDB, Trakt alleen ter aanvulling, IMDb-scores via OMDb, NL en EN", async () => {
  const { f, seen } = fakeApis({ trendMovies: 7 });
  const c = await buildContent(NOW, { tmdb: "0123456789abcdef0123456789abcdef", trakt: "trakt-client-id", omdb: "omdbkey" }, new Set(), new Set(), f);
  // Top 10 films: 7 van TMDB, aangevuld met Trakt (TMDB-details), Top 10 series: 10 van TMDB
  eq(c.nl.top10!.movies.map((x) => x.id), [1, 2, 3, 4, 5, 6, 7, 500, 501, 502], "films aangevuld met Trakt");
  eq(c.nl.top10!.tv.length, 10, "series");
  eq(c.nl.credits, { trakt: true, omdb: true }, "bronnen");
  ok(c.nl.popular.length > 0 && c.nl.popular.every((x) => ![...c.nl.top10!.movies, ...c.nl.top10!.tv].some((t) => t.type === x.type && t.id === x.id)), "populair zonder Top 10");
  // IMDb-scores (OMDb) op Top 10 en Populair; Trakt gaf het IMDb-id al mee (geen external_ids nodig)
  eq(c.nl.top10!.movies.find((x) => x.id === 500)?.imdb, 6.1, "score via Trakt-IMDb-id");
  ok([...c.nl.top10!.tv, ...c.nl.popular].every((x) => x.imdb === 8.4), "scores");
  ok(!seen.some((s) => s.url.pathname === "/3/movie/500/external_ids"), "Trakt-IMDb-id hergebruikt");
  // taal: titels en genres
  eq([c.nl.top10!.tv[0].title, c.nl.top10!.tv[0].genre], ["NL tv 1", "Drama NL"]);
  eq([c.en.top10!.tv[0].title, c.en.top10!.tv[0].genre, c.en.top10!.tv[0].imdb], ["EN tv 1", "Drama", 8.4]);
  eq(c.en.top10!.movies.find((x) => x.id === 500)?.title, "EN movie 500", "Engelse titel voor Trakt-aanvulling");
  // Trakt: client-id in de kop, nooit in de URL; OMDb: alleen het IMDb-id en de sleutel
  const trakt = seen.filter((s) => s.url.hostname === "api.trakt.tv");
  ok(trakt.length === 2 && trakt.every((s) => s.headers.get("trakt-api-key") === "trakt-client-id" && !s.url.search.includes("trakt-client-id")), "Trakt-kop");
  ok(seen.filter((s) => s.url.hostname === "www.omdbapi.com").every((s) => /^tt\d+$/.test(s.url.searchParams.get("i") ?? "")), "OMDb op IMDb-id");
  ok(!seen.some((s) => /imdb\.com/.test(s.url.hostname)), "nooit imdb.com");
  ok(seen.filter((s) => s.url.hostname === "www.omdbapi.com").length <= 40, "begrensd aantal OMDb-verzoeken");
});

Deno.test("ophalen: zonder Trakt- en OMDb-sleutel alleen TMDB (TMDB-score); OMDb-fout is niet fataal", async () => {
  const a = fakeApis();
  const c = await buildContent(NOW, { tmdb: "0123456789abcdef0123456789abcdef" }, new Set(), new Set(), a.f);
  ok(!a.seen.some((s) => s.url.hostname !== "api.themoviedb.org"), "alleen TMDB");
  ok(!a.seen.some((s) => s.url.pathname.endsWith("/external_ids")), "geen external_ids zonder OMDb");
  eq(c.nl.credits, {}, "geen extra bronnen");
  eq(scoreText("nl", c.nl.top10!.movies[0]), "TMDB 7,3", "TMDB-score");
  const b = fakeApis({ failOmdb: true });
  const d = await buildContent(NOW, { tmdb: "0123456789abcdef0123456789abcdef", omdb: "k" }, new Set(), new Set(), b.f);
  ok(d.nl.top10!.movies.length === 10 && d.nl.top10!.movies.every((x) => x.imdb === undefined), "zonder scores verder");
});

// ---------- links en HTML ----------

const VOID = new Set(["img", "br", "meta", "link", "hr", "input", "col", "area", "base", "source", "wbr"]);
/** Tags in balans (zonder commentaar en conditionele Outlook-blokken); geeft de eerste fout of "". */
function tagProblem(html: string): string {
  const src = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<!doctype[^>]*>/i, "");
  const stack: string[] = [];
  for (const m of src.matchAll(/<\/?([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(\/?)>/g)) {
    const name = m[1].toLowerCase();
    if (VOID.has(name) || m[2] === "/") continue;
    if (m[0].startsWith("</")) {
      const top = stack.pop();
      if (top !== name) return `</${name}> sluit <${top}>`;
    } else stack.push(name);
  }
  if (stack.length) return `niet gesloten: ${stack.join(",")}`;
  if (/<[^>]*<|"[^"]*\n[^"]*"\s*>/.test(src.replace(/<style[\s\S]*?<\/style>/g, ""))) return "kapotte tag";
  return "";
}

const full = (): Edition => ({
  featured: it("movie", 1, { genre: "Actie" }),
  fresh: [it("tv", 2)], soon: [it("movie", 3, { date: "2026-11-05" })],
  popular: [it("movie", 4, { genre: "Komedie", imdb: 7.1 }), it("tv", 5, { title: `Tom & "Jerry" <i>`, score: 6.5 })],
  top10: {
    movies: range("movie", 10, 10).map((x, n) => ({ ...x, genre: "Drama", imdb: n === 0 ? 8.2 : undefined, score: 7 })),
    tv: range("tv", 30, 7).map((x) => ({ ...x, genre: "Sci-Fi & Fantasy" })),
  },
  credits: { trakt: true },
});

Deno.test("links: elke poster en titel opent de titel in Bingr, zonder trackers of persoonsgegevens", () => {
  const m = renderNewsletter({ lang: "nl", edition: full(), firstName: "Léon", unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=a.b", year: 2026 });
  const hrefs = [...m.html.matchAll(/href="([^"]*)"/g)].map((x) => x[1].replace(/&amp;/g, "&"));
  const titles = hrefs.filter((h) => h.startsWith("https://bingr.online/titel/"));
  for (const i of [...full().top10!.movies, ...full().top10!.tv, ...full().popular]) ok(titles.includes(titleUrl(i)), `link ${i.type}:${i.id}`);
  for (const h of titles) {
    const u = new URL(h);
    eq([...u.searchParams.keys()].filter((k) => !["type", "id", "q", "y"].includes(k)), [], `alleen type/id/q/y: ${h}`);
    ok(!/utm_|léon|leon|@/i.test(h), "geen trackers of naam");
  }
  ok(hrefs.every((h) => h.startsWith("https://")), "alleen https-links");
  eq(titleUrl({ type: "tv", id: 30, title: "tv 30", year: 2026 }), "https://bingr.online/titel/?type=tv&id=30&q=tv%2030&y=2026");
});

Deno.test("HTML: Top 10 en Populair in NL en EN, geen kapotte tags, alt-teksten, vaste breedtes, bronvermelding", () => {
  for (const lang of ["nl", "en"] as const) {
    const m = renderNewsletter({ lang, edition: full(), unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=a.b", year: 2026 });
    eq(tagProblem(m.html), "", `${lang}: tags`);
    const imgs = [...m.html.matchAll(/<img\b[^>]*>/g)].map((x) => x[0]);
    ok(imgs.length >= 1 + 1 + 1 + 2 + 17, `${lang}: posters (${imgs.length})`);
    for (const i of imgs) {
      ok(/\salt="[^"]+"/.test(i), `${lang}: alt-tekst ontbreekt: ${i.slice(0, 80)}`);
      ok(/\swidth="\d+"/.test(i), `${lang}: vaste breedte: ${i.slice(0, 80)}`);
      ok(/src="https:\/\/image\.tmdb\.org\/t\/p\/w\d+\/[A-Za-z0-9_-]+\.jpg"/.test(i), `${lang}: alleen image.tmdb.org`);
    }
    ok(m.html.includes('alt="Tom &amp; &quot;Jerry&quot; &lt;i&gt;"') && !m.html.includes("<i>"), `${lang}: titel ge-escaped (ook in alt)`);
    ok(m.html.includes(lang === "nl" ? "Top 10 deze week" : "Top 10 this week"), `${lang}: kop Top 10`);
    ok(m.html.includes(lang === "nl" ? ">Films<" : ">Movies<") && m.html.includes(">Series<"), `${lang}: films en series apart`);
    ok(m.html.includes(lang === "nl" ? ">Populair<" : ">Popular<") && !/Populair op IMDb|Popular on IMDb/.test(m.html), `${lang}: Populair (niet "op IMDb")`);
    ok(m.html.includes(lang === "nl" ? "IMDb 8,2" : "IMDb 8.2") && m.html.includes(lang === "nl" ? "TMDB 7,0" : "TMDB 7.0"), `${lang}: scores`);
    ok(m.html.includes("2026 · Drama") && m.html.includes("2026 · Sci-Fi &amp; Fantasy"), `${lang}: jaar en genre`);
    ok(/>10<\/span>/.test(m.html) && />1<\/span>/.test(m.html), `${lang}: rangnummers`);
    ok(m.html.includes("w185/p10.jpg") && m.html.includes('width="93"'), `${lang}: posterrij van 5`);
    const pos = (x: string) => m.html.indexOf(`${x}</div><div style="height:3px`);
    const [top, fresh] = lang === "nl" ? [pos("Top 10 deze week"), pos("Nieuw om te kijken")] : [pos("Top 10 this week"), pos("New to watch")];
    ok(top > m.html.indexOf("w780/b1.jpg") && top < fresh, `${lang}: Top 10 na Uitgelicht, voor Nieuw`);
    const c = credits(lang, full());
    ok(c[0].includes("TMDB API") && c.some((x) => x.includes("Trakt")) && c.some((x) => x.includes("OMDb")) && c.some((x) => x.includes("JustWatch")), `${lang}: bronnen`);
    for (const x of c) ok(m.html.includes(x.replace(/&/g, "&amp;")), `${lang}: bron in de voettekst`);
    ok(m.text.includes(lang === "nl" ? "Top 10 deze week" : "Top 10 this week") && m.text.includes("1. movie 10 (2026 · Drama, IMDb") && m.text.includes("https://bingr.online/titel/?type=tv&id=30"), `${lang}: platte tekst`);
  }
  const nl = renderNewsletter({ lang: "nl", edition: full(), unsubscribeUrl: "https://u" });
  ok(nl.html.includes("Deze mail gebruikt de TMDB API, maar is niet goedgekeurd of gecertificeerd door TMDB."), "TMDB-vermelding");
  // zonder OMDb-scores en zonder Trakt: die bronnen niet noemen
  const plain = { ...full(), credits: {}, popular: [], top10: { movies: [it("movie", 1, { score: 7 })], tv: [] } };
  const c = credits("nl", plain);
  ok(!c.some((x) => x.includes("Trakt") || x.includes("OMDb")), "alleen gebruikte bronnen");
  // oude editie (zonder top10/genres) blijft werken
  const old = renderNewsletter({ lang: "nl", edition: { featured: null, fresh: [], soon: [], popular: [it("movie", 4)] }, unsubscribeUrl: "https://u" });
  eq(tagProblem(old.html), "", "oude editie");
  ok(old.html.includes(">Populair<") && !old.html.includes("Top 10"), "oude editie zonder Top 10");
});
