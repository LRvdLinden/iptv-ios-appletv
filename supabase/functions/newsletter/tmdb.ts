// Bingr nieuwsbrief: inhoud uit TMDB (function-secret BINGR_TMDB_API_KEY: v3-API-sleutel of v4-leestoken), aangevuld met
// Trakt trending voor de Top 10 (BINGR_TRAKT_CLIENT_ID, zoals TrendingStore in de apps) en IMDb-scores via OMDb
// (BINGR_OMDB_API_KEY, dezelfde bron als de IMDb-scores in de apps). IMDb zelf heeft geen openbare API en scrapen mag
// niet volgens hun voorwaarden: dat gebeurt dus nergens. Zonder Trakt- of OMDb-sleutel: alleen TMDB (TMDB-score).
// Sleutels nooit loggen; fouten van Trakt/OMDb zijn nooit fataal (dan zonder die gegevens).
import {
  buildEdition, type Content, type Edition, genreMap, type GenreMap, imdbId, type Item, type Kind, type Lang, type Lists,
  mapEdition, omdbRating, ref, TMDB_LANG, tmdbAuth, tmdbQueries, toItem, withGenre,
} from "./logic.ts";

const API = "https://api.themoviedb.org/3";
const TRAKT = "https://api.trakt.tv";
const OMDB = "https://www.omdbapi.com/";
type Fetch = typeof fetch;
export type Keys = { tmdb: string; trakt?: string; omdb?: string };

export async function tmdbGet(path: string, q: Record<string, string>, key: string, f: Fetch = fetch): Promise<Record<string, unknown> | null> {
  const a = tmdbAuth(key);
  if (!a.header && !a.param) return null;
  const u = new URL(API + path);
  for (const [k, v] of Object.entries(q)) u.searchParams.set(k, v);
  if (a.param) u.searchParams.set("api_key", a.param);
  const r = await f(u, { headers: { Accept: "application/json", ...(a.header ? { Authorization: a.header } : {}) }, signal: AbortSignal.timeout(15000) });
  if (!r.ok) { await r.body?.cancel(); throw new Error(`tmdb_${r.status}`); }
  return await r.json();
}

async function list(path: string, q: Record<string, string>, key: string, kind: Kind | undefined, f: Fetch): Promise<Item[]> {
  const j = await tmdbGet(path, q, key, f);
  const res = Array.isArray(j?.results) ? j!.results as Record<string, unknown>[] : [];
  return res.map((r) => toItem(r, kind)).filter((x): x is Item => !!x);
}

/** Alle TMDB-lijsten voor één taal. */
export async function fetchLists(lang: Lang, ms: number, key: string, f: Fetch = fetch): Promise<Lists> {
  const q = tmdbQueries(lang, ms);
  const [freshMovies, freshTv, soonMovies, soonTv, trendMovies, trendTv, popularMovies, popularTv] = await Promise.all([
    list(q.freshMovies[0], q.freshMovies[1], key, "movie", f),
    list(q.freshTv[0], q.freshTv[1], key, "tv", f),
    list(q.soonMovies[0], q.soonMovies[1], key, "movie", f),
    list(q.soonTv[0], q.soonTv[1], key, "tv", f),
    list(q.trendMovies[0], q.trendMovies[1], key, "movie", f),
    list(q.trendTv[0], q.trendTv[1], key, "tv", f),
    list(q.popularMovies[0], q.popularMovies[1], key, "movie", f),
    list(q.popularTv[0], q.popularTv[1], key, "tv", f),
  ]);
  return { freshMovies, freshTv, soonMovies, soonTv, trendMovies, trendTv, popularMovies, popularTv };
}

/** Genre-namen in één taal (/genre/movie/list en /genre/tv/list); mislukt = geen genres. */
export async function fetchGenres(lang: Lang, key: string, f: Fetch = fetch): Promise<GenreMap> {
  const q = { language: TMDB_LANG[lang] };
  const [m, t] = await Promise.all([
    tmdbGet("/genre/movie/list", q, key, f).catch(() => null),
    tmdbGet("/genre/tv/list", q, key, f).catch(() => null),
  ]);
  return genreMap(m, t);
}

/** Trakt trending (zonder login, alleen de client-id): [{tmdb, imdb}] in volgorde. Mislukt = []. */
export async function traktTrending(kind: Kind, clientId: string, f: Fetch = fetch): Promise<{ tmdb: number; imdb: string | null }[]> {
  if (!clientId) return [];
  try {
    const u = new URL(`${TRAKT}/${kind === "tv" ? "shows" : "movies"}/trending`);
    u.searchParams.set("limit", "30");
    const r = await f(u, {
      headers: { "Content-Type": "application/json", "trakt-api-version": "2", "trakt-api-key": clientId },
      signal: AbortSignal.timeout(10000),
    });
    if (!r.ok) { await r.body?.cancel(); return []; }
    const j = await r.json();
    const out: { tmdb: number; imdb: string | null }[] = [];
    for (const e of Array.isArray(j) ? j : []) {
      const ids = (e?.movie ?? e?.show)?.ids ?? {};
      const tmdb = Number(ids.tmdb);
      if (Number.isInteger(tmdb) && tmdb > 0) out.push({ tmdb, imdb: imdbId(ids.imdb) });
    }
    return out;
  } catch { return []; }
}

/** Kleine pool: hoogstens `n` verzoeken tegelijk. */
export async function pool<T, R>(xs: T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(xs.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, xs.length) }, async () => {
    while (i < xs.length) { const k = i++; out[k] = await fn(xs[k]); }
  }));
  return out;
}

/**
 * Trakt-titels die TMDB trending niet al heeft, aangevuld met TMDB-details (poster, titel, genres) in de taal. Alleen
 * zoveel als de Top 10 nog nodig heeft (hoogstens 10 detailverzoeken per soort).
 */
async function traktItems(kind: Kind, trend: Item[], ids: { tmdb: number }[], lang: Lang, key: string, f: Fetch): Promise<Item[]> {
  const have = new Set(trend.map(ref));
  const need = Math.max(0, 10 - trend.length);
  if (!need) return [];
  const todo = ids.filter((x) => !have.has(`${kind}:${x.tmdb}`)).slice(0, need + 3);
  const got = await pool(todo, 4, async (x) => {
    const j = await tmdbGet(`/${kind}/${x.tmdb}`, { language: TMDB_LANG[lang] }, key, f).catch(() => null);
    return j ? toItem(j, kind) : null;
  });
  return got.filter((x): x is Item => !!x);
}

/**
 * IMDb-scores (via OMDb) voor de Top 10 en Populair: IMDb-id uit Trakt of TMDB external_ids, score uit OMDb. Zonder
 * OMDb-sleutel niets (de mail toont dan de TMDB-score). Per titel één keer; fouten = geen score.
 */
export async function imdbScores(items: Item[], keys: Keys, known: Map<string, string>, f: Fetch = fetch): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  if (!keys.omdb) return out;
  const uniq = [...new Map(items.map((i) => [ref(i), i])).values()].slice(0, 40);
  await pool(uniq, 5, async (i) => {
    try {
      let tt = known.get(ref(i)) ?? null;
      if (!tt) {
        const j = await tmdbGet(`/${i.type}/${i.id}/external_ids`, {}, keys.tmdb, f).catch(() => null);
        tt = imdbId(j?.imdb_id);
      }
      if (!tt) return;
      const u = new URL(OMDB);
      u.searchParams.set("i", tt);
      u.searchParams.set("apikey", keys.omdb!);
      const r = await f(u, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000) });
      if (!r.ok) { await r.body?.cancel(); return; }
      const s = omdbRating(await r.json());
      if (s !== null) out.set(ref(i), s);
    } catch { /* geen score */ }
  });
  return out;
}

/**
 * Inhoud voor nl en en. De keuze (welke titels) wordt gemaakt op de Nederlandse lijsten; de Engelse versie krijgt dezelfde
 * titels met Engelse teksten (zelfde id's; ontbreekt er een in de Engelse lijsten, dan de titel zonder omschrijving).
 * Genres per taal; IMDb-scores (OMDb) voor de Top 10 en Populair.
 */
export async function buildContent(ms: number, keys: Keys | string, recentFeatured: Set<string>, recentShown: Set<string>, f: Fetch = fetch): Promise<Content> {
  const k: Keys = typeof keys === "string" ? { tmdb: keys } : keys;
  const [nlL, enL, gNl, gEn, trM, trT] = await Promise.all([
    fetchLists("nl", ms, k.tmdb, f), fetchLists("en", ms, k.tmdb, f), fetchGenres("nl", k.tmdb, f), fetchGenres("en", k.tmdb, f),
    traktTrending("movie", k.trakt ?? "", f), traktTrending("tv", k.trakt ?? "", f),
  ]);
  const [traktMovies, traktTv] = await Promise.all([
    traktItems("movie", nlL.trendMovies, trM, "nl", k.tmdb, f), traktItems("tv", nlL.trendTv, trT, "nl", k.tmdb, f),
  ]);
  let nl = buildEdition({ ...nlL, traktMovies, traktTv }, ms, recentFeatured, recentShown);
  // IMDb-scores voor de Top 10 en Populair (taalonafhankelijk)
  const known = new Map<string, string>();
  for (const x of trM) if (x.imdb) known.set(`movie:${x.tmdb}`, x.imdb);
  for (const x of trT) if (x.imdb) known.set(`tv:${x.tmdb}`, x.imdb);
  const scored = [...(nl.top10?.movies ?? []), ...(nl.top10?.tv ?? []), ...nl.popular];
  const imdb = await imdbScores(scored, k, known, f);
  if (imdb.size) {
    nl = mapEdition(nl, (i) => (imdb.has(ref(i)) ? { ...i, imdb: imdb.get(ref(i)) } : i));
    nl.credits = { ...nl.credits, omdb: true };
  }
  // Engelse titels voor wat Trakt aanvulde
  const enExtra = await Promise.all(
    [...(nl.top10?.movies ?? []), ...(nl.top10?.tv ?? [])]
      .filter((i) => [...traktMovies, ...traktTv].some((t) => ref(t) === ref(i)))
      .map((i) => tmdbGet(`/${i.type}/${i.id}`, { language: TMDB_LANG.en }, k.tmdb, f).then((j) => (j ? toItem(j, i.type) : null)).catch(() => null)),
  );
  const en = translate(nl, { ...enL, extra: enExtra.filter((x): x is Item => !!x) } as unknown as Record<string, Item[]>);
  return { nl: mapEdition(nl, (i) => withGenre(i, gNl)), en: mapEdition(en, (i) => withGenre(i, gEn)) };
}

export function translate(nl: Edition, en: Record<string, Item[]>): Edition {
  const by = new Map<string, Item>();
  for (const l of Object.values(en)) for (const i of l ?? []) by.set(`${i.type}:${i.id}`, i);
  return mapEdition(nl, (i: Item): Item => {
    const e = by.get(`${i.type}:${i.id}`);
    const base = { ...i };
    delete base.genre; // genre opnieuw in de eigen taal
    return e ? { ...base, title: e.title, overview: e.overview } : { ...base, overview: "" }; // nooit Nederlandse tekst in de Engelse mail
  });
}
