// Bingr introdb (build 179): tijden van intro, samenvatting en aftiteling per aflevering (TheIntroDB, openbaar, geen sleutel).
// Contract: docs/ACCOUNT.md → "Build 179", punt 10.
//   POST { tmdb, imdb?, season, episode } (met apikey + Authorization: Bearer <access_token>)
//   200 { ok: true, intro: {start,end}|null, recap: {start,end}|null, credits: {start}|null, cached }
//   200 { ok: false, error: "not_found" | "unavailable" } · 400 bad_request · 401 not_signed_in · 405 · 429 rate_limited
// Cache: tabel ratings_cache (sleutel introdb:<tmdb>:<seizoen>:<aflevering>), gevonden 30 dagen, niet gevonden 1 dag.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { BANNED_BODY, bannedUntilActive, isBanError } from "../_shared/ban.ts";
import { cacheKey, fresh, parseBody, PER_MINUTE, type Result, toResult, url } from "./logic.ts";

const env = (k: string) => Deno.env.get(k);
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
  const { data, error } = await admin.rpc("bingr_rate_hit", { p_key: `introdb:${user}`, p_max: PER_MINUTE, p_window: 60 });
  if (error) { console.error("introdb rate_hit", error.message); return false; }
  return data === false;
}

function answer(r: Result | null, cached: boolean): Response {
  return r ? json({ ok: true, ...r, cached }) : json({ ok: false, error: "not_found", cached });
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
  const cachedResult = (row?.body as { result?: Result | null } | undefined)?.result ?? null;
  if (row && fresh(row.fetched_at, cachedResult !== null, Date.now())) return answer(cachedResult, true);
  let result: Result | null;
  try {
    const r = await fetch(url(want), { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000) });
    if (r.status === 404) { await r.body?.cancel(); result = null; }
    else if (!r.ok) { await r.body?.cancel(); throw new Error(`introdb_${r.status}`); }
    else result = toResult(await r.json());
  } catch (e) {
    console.error("introdb upstream", e instanceof Error ? e.message.slice(0, 40) : "fout");
    if (row) return answer(cachedResult, true);
    return json({ ok: false, error: "unavailable" });
  }
  const { error } = await admin.from("ratings_cache").upsert({ key, body: { result }, fetched_at: new Date().toISOString() });
  if (error) console.error("introdb cache", error.message);
  return answer(result, false);
});
