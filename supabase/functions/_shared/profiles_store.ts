// Build 146: profielen lezen en schrijven in account_data (versleuteld in `sealed`, leesbare kopie in `profiles` alleen
// zolang oude apps die nodig hebben). Gebruikt door device-auth (get_profiles/put_profiles, watch_stats, onderhoud) en
// push (profielnamen bij herinneringen). Logica in profiles.ts; contract in docs/ACCOUNT.md ("Build 146").
import { seal, unseal } from "./sealed.ts";
import {
  cleanProfiles, legacyMode, type LegacyMode, liveCount, mergeProfiles, needsMirror, PROFILES_MAX_BYTES, sameList,
} from "./profiles.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
export type ProfilesRow = {
  profiles: unknown; sealed: string | null; updated_at: string; legacy_at: string | null; plain_cleared: boolean | null;
};
const COLS = "profiles,sealed,updated_at,legacy_at,plain_cleared";

let modeCache: { at: number; v: LegacyMode } | null = null;
/** app_settings.profiles_legacy (60 s in het geheugen; bij een fout de veilige standaard "mirror"). */
export async function currentMode(db: Db): Promise<LegacyMode> {
  if (modeCache && Date.now() - modeCache.at < 60_000) return modeCache.v;
  const { data, error } = await db.from("app_settings").select("value").eq("key", "profiles_legacy").maybeSingle();
  const v = error ? "mirror" : legacyMode(data?.value);
  if (!error) modeCache = { at: Date.now(), v };
  return v;
}
export const resetModeCache = () => { modeCache = null; };

/** De profielen van een account (versleutelde lijst samengevoegd met wat oude apps in de leesbare kopie schreven). */
export async function readProfiles(db: Db, userId: string): Promise<{ list: Obj[]; row: ProfilesRow | null; sealedList: Obj[] }> {
  const { data: row, error } = await db.from("account_data").select(COLS).eq("user_id", userId).maybeSingle();
  if (error) throw new Error(`account_data: ${error.message}`);
  if (!row) return { list: [], row: null, sealedList: [] };
  let sealedList: Obj[] = [];
  if (row.sealed) {
    const o = await unseal(row.sealed).catch(() => { throw new Error("decrypt_failed"); });
    sealedList = cleanProfiles(o?.profiles) ?? [];
  }
  const plain = row.plain_cleared ? [] : cleanProfiles(row.profiles) ?? [];
  return { list: plain.length ? mergeProfiles(sealedList, plain) : sealedList, row: row as ProfilesRow, sealedList };
}

async function appVersions(db: Db, userId: string): Promise<{ app_version: string | null }[]> {
  const { data, error } = await db.from("account_devices").select("app_version").eq("user_id", userId);
  if (error) throw new Error(`account_devices: ${error.message}`);
  return data ?? [];
}

export type SyncResult = { list: Obj[]; updatedAt: string | null; wrote: boolean } | { error: "too_large" | "busy" };
/**
 * Lezen, (optioneel) binnenkomende profielen samenvoegen, en zo nodig opnieuw opslaan: versleuteld, met of zonder
 * leesbare kopie (needsMirror). Optimistisch: de update lukt alleen als updated_at nog gelijk is (een oude app of een
 * ander apparaat schreef intussen niet); anders opnieuw, max. 4 keer.
 */
export async function syncProfiles(db: Db, userId: string, incoming: Obj[] | null, opts: { nowMs?: number; mode?: LegacyMode } = {}): Promise<SyncResult> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const { list, row, sealedList } = await readProfiles(db, userId);
    const merged = incoming ? mergeProfiles(list, incoming, opts.nowMs) : list;
    const mode = opts.mode ?? await currentMode(db);
    const mirror = needsMirror(mode, await appVersions(db, userId), row?.legacy_at ?? null, opts.nowMs);
    const plainNow = row && !row.plain_cleared ? cleanProfiles(row.profiles) ?? [] : [];
    const needWrite = !row ? merged.length > 0
      : !row.sealed || !sameList(merged, sealedList) || (mirror ? (row.plain_cleared === true || !sameList(plainNow, merged)) : (!row.plain_cleared || plainNow.length > 0));
    if (!needWrite) return { list: merged, updatedAt: row?.updated_at ?? null, wrote: false };
    if (JSON.stringify(merged).length > PROFILES_MAX_BYTES) return { error: "too_large" };
    const now = new Date(opts.nowMs ?? Date.now()).toISOString();
    const patch = {
      sealed: await seal({ profiles: merged }), sealed_at: now, profile_count: liveCount(merged), updated_at: now,
      profiles: mirror ? merged : [], plain_cleared: !mirror,
    };
    if (!row) {
      const { error } = await db.from("account_data").insert({ user_id: userId, ...patch });
      if (!error) return { list: merged, updatedAt: now, wrote: true };
      if (error.code !== "23505") throw new Error(`account_data insert: ${error.message}`);
      continue; // gelijktijdig aangemaakt: opnieuw lezen
    }
    const { data, error } = await db.from("account_data").update(patch).eq("user_id", userId).eq("updated_at", row.updated_at).select("user_id");
    if (error) throw new Error(`account_data update: ${error.message}`);
    if (data?.length) return { list: merged, updatedAt: now, wrote: true };
  }
  return { error: "busy" };
}

/** Namen van de profielen (id → naam, zonder tombstones); voor statistieken en herinneringen. Nooit een fout. */
export async function profileNames(db: Db, userId: string): Promise<Map<string, string>> {
  const names = new Map<string, string>();
  try {
    const { list } = await readProfiles(db, userId);
    for (const p of list) if (p && p.id && p.deleted !== true && typeof p.name === "string" && p.name) names.set(String(p.id), p.name);
  } catch (e) { console.error("profielnamen", e instanceof Error ? e.message : "fout"); }
  return names;
}
/** De lijst zelf (voor push: hoofdprofiel en aantal); [] bij een fout. */
export async function profilesOrEmpty(db: Db, userId: string): Promise<Obj[]> {
  try { return (await readProfiles(db, userId)).list; } catch { return []; }
}
