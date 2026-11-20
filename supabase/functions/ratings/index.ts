// Bingr ratings (build 179): beoordelingen van IMDb, TMDB, Rotten Tomatoes, Metacritic, Letterboxd en Trakt via MDBList.
// Contract: docs/ACCOUNT.md → "Build 179", punt 9.
//   POST { type: "movie"|"show", tmdb } of { imdb } (met apikey + Authorization: Bearer <access_token>)
//   200 { ok: true, ratings: [{ source, value, votes? }], cached } · 200 { ok: false, error: "unavailable" }
//   400 bad_request · 401 not_signed_in · 405 method · 429 rate_limited
// Sleutel: function-secret MDBLIST_API_KEY (nooit in een repo, app, antwoord of log). Cache: tabel ratings_cache, 7 dagen.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { cacheKey, fresh, mdblistPaths, parseBody, PER_MINUTE, type Rating, toRatings } from "./logic.ts";

const env = (k: string) => Deno.env.get(k);
const KEY = (env("MDBLIST_API_KEY") ?? "").trim();
const API = "https://api.mdblist.com";
const admin = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

async function authed(req: Request): Promise<{ id: string } | Response> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token.split(".").length !== 3) return json({ error: "not_signed_in" }, 401);
  const { data, error } = await admin.auth.getUser(token);
  if (!error && data?.user) return bannedUntilActive((data.user as { banned_until?: string }).banned_until) ? json(BANNED_BODY, 401) : data.user;
  if (isBanError(error)) return json(BANNED_BODY, 401);
  const status = (error as { status?: number } | null)?.status ?? 0;
  return status >= 400 && status < 500 ? json({ error: "not_signed_in" }, 401) : json({ error: "unavailable" }, 503);
}

async function limited(user: string): Promise<boolean> {
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: `ratings:${user}`, p_max: PER_MINUTE, p_window: 60 });
  if (error) { console.error("ratings rate_hit", error.message); return false; }
  return data === false;
}

class NotFound extends Error {}
async function mdblist(path: string): Promise<unknown> {
  const u = new URL(API + path);
  u.searchParams.set("apikey", KEY);
  const r = await fetch(u, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000) });
  if (r.status === 404) { await r.body?.cancel(); throw new NotFound(); }
  if (!r.ok) { await r.body?.cancel(); throw new Error(`mdblist_${r.status}`); }
  return await r.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const user = await authed(req);
  if (user instanceof Response) return user;
  const want = parseBody(await req.json().catch(() => null));
  if (!want) return json({ error: "bad_request" }, 400);
  if (await limited(user.id)) return json({ error: "rate_limited" }, 429);
  const key = cacheKey(want);
  const { data: row } = await admin.from("ratings_cache").select("body,fetched_at").eq("key", key).maybeSingle();
  if (row && fresh(row.fetched_at, Date.now())) {
    return json({ ok: true, ratings: (row.body as { ratings?: Rating[] })?.ratings ?? [], cached: true });
  }
  if (!KEY) return json({ ok: false, error: "unavailable" });
  let ratings: Rating[] | null = null;
  try {
    for (const p of mdblistPaths(want)) {
      try { ratings = toRatings(await mdblist(p)); break; } catch (e) { if (!(e instanceof NotFound)) throw e; }
    }
    ratings ??= [];   // niet gevonden: leeg (ook bewaard, zodat MDBList niet steeds opnieuw gevraagd wordt)
  } catch (e) {
    console.error("ratings upstream", e instanceof Error ? e.message.slice(0, 40) : "fout"); // nooit het adres (sleutel)
    if (row) return json({ ok: true, ratings: (row.body as { ratings?: Rating[] })?.ratings ?? [], cached: true });
    return json({ ok: false, error: "unavailable" });
  }
  const { error } = await admin.from("ratings_cache").upsert({ key, body: { ratings }, fetched_at: new Date().toISOString() });
  if (error) console.error("ratings cache", error.message);
  return json({ ok: true, ratings, cached: false });
});
