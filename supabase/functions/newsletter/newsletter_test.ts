// Unittests voor de functie newsletter: deno test supabase/functions/newsletter/newsletter_test.ts
// Zonder netwerk en database: tijdrekening, editiesleutels, ontdubbelen, HTML (escapen), links, afmeldtoken, TMDB.
import {
  amsterdam, buildEdition, dueEdition, editionKey, editionRefs, type Item, langOf, nextEdition, oneClickUrl, sameSecret, smtpCode,
  smtpTemporary, titleUrl, tmdbAuth, toItem, unsubPageUrl, unsubToken, unsubUser, validEmail, validKey,
} from "./logic.ts";
import { renderNewsletter, shortDate, subjectOf } from "./render.ts";
import { fetchLists, translate } from "./tmdb.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }
const ms = (iso: string) => Date.parse(iso);

Deno.test("tijd: zondag 09:00 en woensdag 18:00 in Amsterdam, zomer- en wintertijd", () => {
  // zomertijd (CEST, UTC+2): zondag 2026-10-18 09:00 = 07:00 UTC
  eq(dueEdition(ms("2026-10-18T07:00:00Z"))?.key, "2026-10-18-sun", "zo zomertijd");
  eq(dueEdition(ms("2026-10-18T06:00:00Z")), null, "zo 08:00 lokaal nog niet");
  // wintertijd (CET, UTC+1): zondag 2026-11-01 09:00 = 08:00 UTC; 07:00 UTC is dan 08:00 lokaal
  eq(dueEdition(ms("2026-11-01T08:00:00Z"))?.key, "2026-11-01-sun", "zo wintertijd");
  eq(dueEdition(ms("2026-11-01T07:00:00Z")), null, "zo wintertijd 08:00 lokaal");
  // woensdag 18:00: zomer 16:00 UTC, winter 17:00 UTC
  eq(dueEdition(ms("2026-10-21T16:00:00Z"))?.key, "2026-10-21-wed", "wo zomertijd");
  eq(dueEdition(ms("2026-10-28T17:00:00Z"))?.key, "2026-10-28-wed", "wo wintertijd");
  eq(dueEdition(ms("2026-10-28T16:00:00Z")), null, "wo wintertijd 17:00 lokaal");
  // speling: tot 2 uur later mag de editie nog beginnen, daarna niet
  eq(dueEdition(ms("2026-10-18T09:00:00Z"))?.key, "2026-10-18-sun", "speling 2 uur");
  eq(dueEdition(ms("2026-10-18T10:00:00Z")), null, "na de speling");
  eq(dueEdition(ms("2026-10-18T07:00:00Z"))?.at, "2026-10-18T07:00:00.000Z", "at");
  // dag van de omschakeling (zondag 25 oktober 2026, 03:00 -> 02:00): 09:00 CET = 08:00 UTC
  eq(dueEdition(ms("2026-10-25T08:00:00Z"))?.key, "2026-10-25-sun", "omschakeldag herfst");
  eq(dueEdition(ms("2026-10-25T07:00:00Z")), null, "omschakeldag herfst 08:00 lokaal");
  // voorjaar (zondag 29 maart 2026, 02:00 -> 03:00): 09:00 CEST = 07:00 UTC
  eq(dueEdition(ms("2026-03-29T07:00:00Z"))?.key, "2026-03-29-sun", "omschakeldag voorjaar");
  // andere dagen niets
  for (const d of ["2026-10-19", "2026-10-20", "2026-10-22", "2026-10-23", "2026-10-24"]) {
    for (let h = 0; h < 24; h++) eq(dueEdition(ms(`${d}T${String(h).padStart(2, "0")}:00:00Z`)), null, `${d} ${h}`);
  }
});

Deno.test("tijd: volgende editie en lokale tijd", () => {
  eq(nextEdition(ms("2026-10-17T12:00:00Z")), { key: "2026-10-18-sun", at: "2026-10-18T07:00:00.000Z" }, "za -> zo");
  eq(nextEdition(ms("2026-10-18T07:00:00Z")), { key: "2026-10-21-wed", at: "2026-10-21T16:00:00.000Z" }, "strikt later");
  eq(nextEdition(ms("2026-10-21T16:30:00Z")), { key: "2026-10-25-sun", at: "2026-10-25T08:00:00.000Z" }, "na omschakeling");
  eq(nextEdition(ms("2026-10-25T09:00:00Z")), { key: "2026-10-28-wed", at: "2026-10-28T17:00:00.000Z" }, "wintertijd wo");
  const l = amsterdam(ms("2026-12-31T23:30:00Z"));
  eq([l.date, l.dow, l.hour, l.minute], ["2027-01-01", 5, 0, 30], "jaarwisseling");
});

Deno.test("editiesleutel", () => {
  eq(editionKey("2026-10-18", "sun"), "2026-10-18-sun");
  ok(validKey("2026-10-21-wed") && !validKey("2026-10-21-mon") && !validKey("x") && !validKey(null), "validKey");
});

const it = (type: "movie" | "tv", id: number, extra: Partial<Item> = {}): Item => ({
  type, id, title: `${type} ${id}`, year: 2026, date: "2026-10-01", overview: "Omschrijving", poster: `/p${id}.jpg`, backdrop: `/b${id}.jpg`, ...extra,
});
const NOW = ms("2026-10-18T07:00:00Z");
const L0 = { freshMovies: [], freshTv: [], soonMovies: [], soonTv: [], popularMovies: [], popularTv: [], trendMovies: [] as Item[], trendTv: [] as Item[] };
// genoeg trending, zodat de Top 10 niet uit Populair hoeft aan te vullen
L0.trendMovies = Array.from({ length: 10 }, (_, n) => it("movie", 100 + n));

Deno.test("inhoud: uitgelicht ontdubbelen over de vorige 2 edities", () => {
  const lists = { ...L0, freshMovies: [it("movie", 1), it("movie", 2)], freshTv: [it("tv", 1), it("tv", 2)], popularMovies: [it("movie", 9)] };
  eq(buildEdition(lists, NOW, new Set()).featured?.id, 1, "eerste");
  const e = buildEdition(lists, NOW, new Set(["movie:1", "tv:1"]));
  eq([e.featured?.type, e.featured?.id], ["movie", 2], "vorige uitgelichte overgeslagen");
  ok(!e.fresh.some((x) => x.type === "movie" && x.id === 2), "uitgelicht niet nog eens in het raster");
  // zonder achtergrond niet uitlichten
  const nb = buildEdition({ ...lists, freshMovies: [it("movie", 1, { backdrop: null })], freshTv: [] }, NOW, new Set());
  eq(nb.featured?.id, 9, "terugval op populair");
  // in het raster gaan nieuwe titels voor
  const r = buildEdition({ ...lists, freshMovies: [it("movie", 1), it("movie", 2), it("movie", 3)], freshTv: [] }, NOW, new Set(), new Set(["movie:2"]));
  eq(r.fresh.map((x) => x.id), [3, 2], "niet eerder getoond eerst");
  // editionRefs
  eq(editionRefs(e).featured, ["movie:2"]);
  ok(editionRefs(e).shown.includes("movie:9"), "shown");
  eq(editionRefs(null), { featured: [], shown: [] });
});

Deno.test("inhoud: binnenkort op datum, alleen toekomst; nieuw niet in de toekomst", () => {
  const e = buildEdition({
    ...L0,
    freshMovies: [it("movie", 1, { date: "2026-12-01" }), it("movie", 2)], freshTv: [],
    soonMovies: [it("movie", 5, { date: "2026-11-20" }), it("movie", 6, { date: "2026-10-10" })], soonTv: [it("tv", 7, { date: "2026-10-30" })],
  }, NOW, new Set());
  eq(e.fresh.map((x) => x.id), [], "toekomstige titel niet in Nieuw, nr. 2 is uitgelicht");
  eq(e.featured?.id, 2);
  eq(e.soon.map((x) => x.id), [7, 5], "op datum, verleden weg");
});

Deno.test("TMDB: resultaten, afbeeldingspaden en sleutelsoort", () => {
  ok(toItem({ id: 1, title: "X", poster_path: "/a.jpg", adult: true }, "movie") === null, "volwassen weg");
  ok(toItem({ id: 1, title: "X" }, "movie") === null, "zonder poster weg");
  ok(toItem({ id: 1, name: "P", media_type: "person", poster_path: "/a.jpg" }) === null, "personen weg");
  const x = toItem({ id: 5, name: "Show", first_air_date: "2026-09-01", poster_path: "/a.jpg", backdrop_path: "javascript:alert(1)", media_type: "tv" })!;
  eq([x.type, x.year, x.backdrop], ["tv", 2026, null], "vreemd pad weg");
  ok(toItem({ id: 3, title: "Y", poster_path: "/../x.jpg" }, "movie") === null, "pad met .. weg");
  ok(toItem({ id: 3, title: "Y", poster_path: "/a.jpg", overview: "x ".repeat(400) }, "movie")!.overview.endsWith("…"), "inkorten");
  eq(tmdbAuth("0123456789abcdef0123456789abcdef"), { param: "0123456789abcdef0123456789abcdef" }, "v3");
  const v4 = "eyJhbGciOiJIUzI1NiJ9." + "a".repeat(80) + ".sig";
  eq(tmdbAuth(v4), { header: `Bearer ${v4}` }, "v4");
  eq(tmdbAuth(""), {}, "leeg");
});

Deno.test("TMDB: ophalen met v3 en v4, vertalen zonder Nederlandse tekst in de Engelse mail", async () => {
  const seen: { url: URL; auth: string | null }[] = [];
  const fake = ((u: URL, init?: RequestInit) => {
    seen.push({ url: new URL(u), auth: new Headers(init?.headers).get("authorization") });
    const page = { results: [{ id: 1, title: "Film", name: "Serie", poster_path: "/p.jpg", release_date: "2026-10-01", first_air_date: "2026-10-01", media_type: "movie" }] };
    return Promise.resolve(new Response(JSON.stringify(page), { status: 200 }));
  }) as typeof fetch;
  const l = await fetchLists("nl", NOW, "0123456789abcdef0123456789abcdef", fake);
  eq(l.freshMovies.length, 1);
  ok(seen.every((s) => s.url.searchParams.get("api_key") && !s.auth), "v3 als api_key");
  ok(seen.some((s) => s.url.pathname === "/3/discover/movie" && s.url.searchParams.get("watch_region") === "NL" && s.url.searchParams.get("with_watch_monetization_types") === "flatrate"), "streaming in NL");
  ok(seen.some((s) => s.url.pathname === "/3/movie/popular") && seen.some((s) => s.url.pathname === "/3/tv/popular"), "populair");
  ok(seen.some((s) => s.url.pathname === "/3/trending/movie/week") && seen.some((s) => s.url.pathname === "/3/trending/tv/week"), "top 10");
  ok(seen.every((s) => s.url.searchParams.get("language") === "nl-NL"), "taal");
  seen.length = 0;
  await fetchLists("en", NOW, "eyJhbGciOiJIUzI1NiJ9." + "a".repeat(80) + ".sig", fake);
  ok(seen.every((s) => !s.url.searchParams.get("api_key") && s.auth?.startsWith("Bearer ")), "v4 als Bearer");
  ok(seen.every((s) => s.url.searchParams.get("language") === "en-US"), "en-US");
  const nl = { featured: it("movie", 1, { title: "Nederlands", overview: "NL" }), fresh: [it("tv", 2, { overview: "NL" })], soon: [], popular: [] };
  const en = translate(nl, { a: [it("movie", 1, { title: "English", overview: "EN" })] });
  eq([en.featured?.title, en.featured?.overview, en.fresh[0].overview], ["English", "EN", ""]);
});

Deno.test("links: universele link per titel", () => {
  eq(titleUrl({ type: "movie", id: 603, title: "The Matrix", year: 1999 }), "https://bingr.online/titel/?type=movie&id=603&q=The%20Matrix&y=1999");
  eq(titleUrl({ type: "tv", id: 1, title: "Tom & Jerry's \"show\"/?#", year: null }), "https://bingr.online/titel/?type=tv&id=1&q=Tom%20%26%20Jerry%27s%20%22show%22%2F%3F%23");
  const u = new URL(titleUrl({ type: "tv", id: 9, title: "Café über", year: 2026 }));
  eq([u.searchParams.get("q"), u.searchParams.get("y")], ["Café über", "2026"]);
});

Deno.test("HTML: huisstijl, escapen van TMDB-tekst, knoppen, voettekst", () => {
  const evil = it("movie", 1, { title: `<script>alert("x")</script>`, overview: `<img src=x onerror=alert(1)> & "q"` });
  const ed = { featured: evil, fresh: [it("tv", 2, { title: "A&B" })], soon: [it("movie", 3, { date: "2026-11-05" })], popular: [it("movie", 4)] };
  for (const lang of ["nl", "en"] as const) {
    const m = renderNewsletter({ lang, edition: ed, firstName: "<Léon>", unsubscribeUrl: "https://bingr.online/unsubscribe/?k=news&t=a.b", year: 2026 });
    ok(!m.html.includes("<script>") && m.html.includes("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"), `${lang}: titel ge-escaped`);
    ok(!m.html.includes("<img src=x") && m.html.includes("&lt;img src=x onerror=alert(1)&gt; &amp; &quot;q&quot;"), `${lang}: omschrijving ge-escaped`);
    ok(m.html.includes("A&amp;B"), `${lang}: raster ge-escaped`);
    ok(m.html.includes("BINGR") && m.html.includes("#E50914") && m.html.includes("background:#000000"), `${lang}: huisstijl`);
    ok(!/app-?icon|apple-touch-icon|favicon/i.test(m.html), `${lang}: geen app-icoon`);
    ok(m.html.includes('href="https://bingr.online/titel/?type=movie&amp;id=1&amp;q='), `${lang}: knoplink`);
    ok(m.html.includes("https://image.tmdb.org/t/p/w780/b1.jpg") && m.html.includes("https://image.tmdb.org/t/p/w342/p2.jpg"), `${lang}: afbeeldingen`);
    ok(m.html.includes("k=news&amp;t=a.b"), `${lang}: afmeldlink`);
    ok(m.html.includes("TMDB") && m.html.includes("/privacy.html") && m.html.includes("support.bingr.online"), `${lang}: voettekst`);
    ok(!/€|\$\d|prijs|price/i.test(m.html), `${lang}: geen prijzen`);
    ok(!/netflix/i.test(m.html + m.text), `${lang}: geen namen van diensten`);
    ok(m.text.includes("https://bingr.online/titel/?type=tv&id=2") && m.text.includes("k=news&t=a.b"), `${lang}: platte tekst`);
    ok(m.html.includes(lang === "nl" ? "Hoi Léon," : "Hi Léon,"), `${lang}: aanhef`);
  }
  const nl = renderNewsletter({ lang: "nl", edition: ed, unsubscribeUrl: "https://u", year: 2026 });
  ok(nl.html.includes("Bingr levert zelf geen films of series. Of een titel bij jou te zien is, hangt af van je eigen bron."), "eerlijke zin");
  ok(nl.html.includes("Bekijk in Bingr") && nl.html.includes("Meer info") && nl.html.includes("Binnenkort") && nl.html.includes(">Populair<"), "secties nl");
  ok(nl.html.includes(">5 nov<"), "datum bij binnenkort");
  const en = renderNewsletter({ lang: "en", edition: ed, unsubscribeUrl: "https://u", year: 2026 });
  ok(en.html.includes("Watch in Bingr") && en.html.includes("Coming soon") && en.html.includes(">Nov 5<") && en.html.includes('lang="en"'), "secties en");
  eq(shortDate("nl", "2026-03-01"), "1 mrt");
  eq(shortDate("en", null), "");
  eq(subjectOf("nl", ed, true).startsWith("[Voorbeeld] Nieuw om te kijken: <script>"), true, "onderwerp (platte tekst, geen HTML)");
  const empty = renderNewsletter({ lang: "nl", edition: { featured: null, fresh: [], soon: [], popular: [] }, unsubscribeUrl: "https://u" });
  ok(empty.html.includes("geen nieuwe titels") && empty.subject === "Nieuw om te kijken bij Bingr", "lege editie");
});

Deno.test("afmelden: token per account, niet te vervalsen, niet uitwisselbaar", async () => {
  const id = "0B6A0D2E-1C3F-4A5B-9C8D-7E6F5A4B3C2D", secret = "geheim-0123456789abcdef";
  const t = await unsubToken(id, secret);
  ok(/^[0-9a-f-]{36}\.[A-Za-z0-9_-]{24}$/.test(t), "vorm (zoals de afmeldpagina verwacht)");
  eq(await unsubUser(t, secret), id.toLowerCase(), "geldig");
  eq(await unsubUser(t, "ander-geheim-0123456789"), null, "ander geheim");
  eq(await unsubUser(t.replace(/.$/, (c) => (c === "A" ? "B" : "A")), secret), null, "gewijzigde handtekening");
  eq(await unsubUser(t.replace(/^0b/, "1b"), secret), null, "ander account");
  for (const bad of [null, "", "x.y", `${id}`, `${t}.x`, "a".repeat(200), `${id}.!!!`]) eq(await unsubUser(bad, secret), null, `ongeldig ${bad}`);
  eq(await unsubUser(t, ""), null, "zonder geheim");
  // het berichten-token van admin ("unsub:<id>", sleutel bingr-unsub-v1) geldt hier niet
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", await crypto.subtle.digest("SHA-256", enc.encode(`bingr-unsub-v1|${secret}`)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`unsub:${id.toLowerCase()}`))).subarray(0, 18);
  const adminT = `${id.toLowerCase()}.${btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
  eq(await unsubUser(adminT, secret), null, "berichten-token telt niet");
  eq(unsubPageUrl("a.b"), "https://bingr.online/unsubscribe/?k=news&t=a.b");
  eq(oneClickUrl("https://x.supabase.co/functions/v1/newsletter", "a.b"), "https://x.supabase.co/functions/v1/newsletter?unsubscribe=a.b");
});

Deno.test("overig: taal, e-mailadres, geheimen, SMTP-fouten", () => {
  eq(["", null, "nl", "nl-BE", "NL", "en", "de", "zh-Hans"].map(langOf), ["nl", "nl", "nl", "nl", "nl", "en", "en", "en"]);
  ok(validEmail("a.b+c@bingr.online") && !validEmail("a@b") && !validEmail("a b@c.nl") && !validEmail("<a@b.nl>") && !validEmail("x".repeat(250) + "@b.nl"), "e-mail");
  ok(sameSecret("0123456789abcdef0", "0123456789abcdef0") && !sameSecret("0123456789abcdef1", "0123456789abcdef0"), "geheim");
  ok(!sameSecret("", "") && !sameSecret("kort", "kort") && !sameSecret(null, "0123456789abcdef0"), "leeg/kort telt niet");
  ok(smtpTemporary({ responseCode: 421 }) && smtpTemporary({ code: "ETIMEDOUT" }) && !smtpTemporary({ responseCode: 550 }), "tijdelijk");
  eq([smtpCode({ responseCode: 550, response: "550 a@b.nl unknown" }), smtpCode({ code: "EAUTH" }), smtpCode(new Error("a@b.nl"))], ["smtp_550", "eauth", "error"], "codes zonder adressen");
});
