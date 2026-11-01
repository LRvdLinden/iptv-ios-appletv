// Maandrecap: TMDB-gegevens bij de titels (id, jaar, poster, achtergrond, de naam in de taal van de mail) en de volgende
// aflevering. Bekend TMDB-id (watch_month.tmdb_id, of het voorbeeld): /movie|tv/{id}; anders zoeken op de opgeschoonde titel
// (+ jaar): /search/movie|tv, eerste resultaat. Mislukt iets, dan zonder die gegevens (nooit fataal). Geen sleutels in logs.
import { imgPath, type Lang, TMDB_LANG } from "./logic.ts";
import { applyMeta, type Recap, recapTitles, type RecapTitle } from "./recap.ts";
import { pool, tmdbGet } from "./tmdb.ts";

type Fetch = typeof fetch;
export type Meta = Partial<Pick<RecapTitle, "tmdbId" | "title" | "year" | "poster" | "backdrop">>;
/** Cache per ronde (veel leden kijken dezelfde titels): sleutel `type|tmdb-id` of `type|q|jaar|taal`. */
export type MetaCache = Map<string, Promise<Meta | null>>;

const yearOf = (d: unknown) => (typeof d === "string" && /^\d{4}/.test(d) ? Number(d.slice(0, 4)) : null);
/** TMDB-detail of zoekresultaat -> Meta. */
export function metaOf(j: Record<string, unknown> | null | undefined, type: "movie" | "tv"): Meta | null {
  if (!j || j.adult === true) return null;
  const id = Number(j.id);
  if (!Number.isInteger(id) || id <= 0) return null;
  const name = String((type === "tv" ? j.name ?? j.title : j.title ?? j.name) ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
  const out: Meta = { tmdbId: id, year: yearOf(type === "tv" ? j.first_air_date : j.release_date) };
  if (name) out.title = name;
  const p = imgPath(j.poster_path), b = imgPath(j.backdrop_path);
  if (p) out.poster = p;
  if (b) out.backdrop = b;
  return out;
}

async function lookup(t: RecapTitle, lang: Lang, key: string, f: Fetch, cache: MetaCache): Promise<Meta | null> {
  const language = TMDB_LANG[lang];
  const ck = t.tmdbId ? `${t.type}|${t.tmdbId}|${lang}` : `${t.type}|${t.title.toLowerCase()}|${t.year ?? ""}|${lang}`;
  let p = cache.get(ck);
  if (!p) {
    p = (async () => {
      if (t.tmdbId) return metaOf(await tmdbGet(`/${t.type}/${t.tmdbId}`, { language }, key, f).catch(() => null), t.type);
      const q: Record<string, string> = { query: t.title, language, include_adult: "false", page: "1" };
      if (t.year) q[t.type === "tv" ? "first_air_date_year" : "year"] = String(t.year);
      let j = await tmdbGet(`/search/${t.type}`, q, key, f).catch(() => null);
      let res = Array.isArray(j?.results) ? j!.results as Record<string, unknown>[] : [];
      if (!res.length && t.year) {
        delete q.year; delete q.first_air_date_year;
        j = await tmdbGet(`/search/${t.type}`, q, key, f).catch(() => null);
        res = Array.isArray(j?.results) ? j!.results as Record<string, unknown>[] : [];
      }
      return metaOf(res[0], t.type);
    })();
    cache.set(ck, p);
  }
  return await p;
}

/** Naam van de volgende aflevering: S/E+1, anders aflevering 1 van het volgende seizoen; null = geen volgende bekend. */
export async function nextEpisode(id: number, season: number, episode: number, lang: Lang, key: string, f: Fetch = fetch) {
  const language = TMDB_LANG[lang];
  const ep = (j: Record<string, unknown> | null) => {
    if (!j || !Number.isInteger(Number(j.episode_number))) return null;
    const air = typeof j.air_date === "string" ? j.air_date : "";
    // nog niet uitgezonden (of geen datum): geen "volgende aflevering"
    if (!air || air > new Date().toISOString().slice(0, 10)) return null;
    const name = String(j.name ?? "").replace(/\s+/g, " ").trim().slice(0, 80);
    return { season: Number(j.season_number), episode: Number(j.episode_number), ...(name && !/^(episode|aflevering) \d+$/i.test(name) ? { name } : {}) };
  };
  const a = ep(await tmdbGet(`/tv/${id}/season/${season}/episode/${episode}`, { language }, key, f).catch(() => null));
  if (a) return a;
  return ep(await tmdbGet(`/tv/${id}/season/${season + 1}/episode/1`, { language }, key, f).catch(() => null));
}

/**
 * Recap aanvullen met TMDB. `learn` krijgt per titel het gevonden id/poster/achtergrond (om in watch_month te bewaren, zodat
 * de volgende keer niet opnieuw gezocht hoeft te worden).
 */
export async function enrichRecap(
  r: Recap, lang: Lang, key: string, opts: { fetch?: Fetch; cache?: MetaCache; learn?: (t: RecapTitle, m: Meta) => void } = {},
): Promise<Recap> {
  const f = opts.fetch ?? fetch, cache = opts.cache ?? new Map();
  const meta = new Map<string, Meta>();
  if (!key) return r;
  await pool(recapTitles(r), 4, async (t) => {
    const m = await lookup(t, lang, key, f, cache);
    if (m) { meta.set(t.key, m); if (!t.tmdbId && opts.learn) opts.learn(t, m); }
  });
  let next: { name?: string; season?: number; episode?: number } | null | undefined;
  const u = r.upNext, id = u ? meta.get(u.key)?.tmdbId ?? u.tmdbId : undefined;
  if (u && id && u.season !== undefined && u.episode) next = await nextEpisode(id, u.season, u.episode, lang, key, f).catch(() => undefined);
  // zonder TMDB-id of als TMDB niets weet: de volgende aflevering op nummer (zonder naam)
  return applyMeta(r, meta, next === undefined ? undefined : next);
}
