// Bingr nieuwsbrief: inhoud uit TMDB (function-secret BINGR_TMDB_API_KEY: v3-API-sleutel of v4-leestoken).
import { buildEdition, type Content, type Edition, type Item, type Kind, type Lang, tmdbAuth, tmdbQueries, toItem } from "./logic.ts";

const API = "https://api.themoviedb.org/3";
type Fetch = typeof fetch;

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

/** Alle lijsten voor één taal. */
export async function fetchLists(lang: Lang, ms: number, key: string, f: Fetch = fetch) {
  const q = tmdbQueries(lang, ms);
  const [freshMovies, freshTv, soonMovies, soonTv, popular] = await Promise.all([
    list(q.freshMovies[0], q.freshMovies[1], key, "movie", f),
    list(q.freshTv[0], q.freshTv[1], key, "tv", f),
    list(q.soonMovies[0], q.soonMovies[1], key, "movie", f),
    list(q.soonTv[0], q.soonTv[1], key, "tv", f),
    list(q.popular[0], q.popular[1], key, undefined, f),
  ]);
  return { freshMovies, freshTv, soonMovies, soonTv, popular };
}

/**
 * Inhoud voor nl en en. De keuze (welke titels) wordt gemaakt op de Nederlandse lijsten; de Engelse versie krijgt dezelfde
 * titels met Engelse teksten (zelfde id's; ontbreekt er een in de Engelse lijsten, dan de titel zonder omschrijving).
 */
export async function buildContent(ms: number, key: string, recentFeatured: Set<string>, recentShown: Set<string>, f: Fetch = fetch): Promise<Content> {
  const [nlL, enL] = await Promise.all([fetchLists("nl", ms, key, f), fetchLists("en", ms, key, f)]);
  const nl = buildEdition(nlL, ms, recentFeatured, recentShown);
  return { nl, en: translate(nl, enL) };
}

export function translate(nl: Edition, en: Record<string, Item[]>): Edition {
  const by = new Map<string, Item>();
  for (const l of Object.values(en)) for (const i of l) by.set(`${i.type}:${i.id}`, i);
  const tr = (i: Item): Item => {
    const e = by.get(`${i.type}:${i.id}`);
    return e ? { ...i, title: e.title, overview: e.overview } : { ...i, overview: "" }; // nooit Nederlandse tekst in de Engelse mail
  };
  return { featured: nl.featured ? tr(nl.featured) : null, fresh: nl.fresh.map(tr), soon: nl.soon.map(tr), popular: nl.popular.map(tr) };
}
