// Build 146: kijkgegevens versleuteld opslaan (account_streams, account_watch_log, account_watch_stats).
// Titels, serietitels, profielnamen en apparaatnamen staan als `enc1:…` (per veld AES-GCM, _shared/sealed.ts) in de
// database. De statistieken tellen per titel; daarvoor rekent device-auth de soort, sleutel en weergavenaam hier uit
// (precies zoals public.bingr_stats_item in schema.sql, zie watch_test.ts) en geeft ze mee aan de database. Een sleutel die
// van de titel komt ('t:<titel>') wordt een vaste, niet terug te rekenen sleutel 'h:<HMAC>' per account.
import { keyedHash, openField, sealField } from "../_shared/sealed.ts";

export type StatsItem = { kind: "live" | "episode" | "movie" | null; item_key: string | null; title: string | null };

const trim = (v: unknown) => String(v ?? "").trim();
const nullif = (s: string) => (s === "" ? null : s);

/** Zelfde uitkomst als public.bingr_stats_item(kind, content_id, series_id, series_title, title). */
export function statsItem(kind: unknown, contentId: unknown, seriesId: unknown, seriesTitle: unknown, title: unknown): StatsItem {
  const k = trim(kind).toLowerCase(), t = trim(title), cid = nullif(trim(contentId));
  const base = t.split(" · ")[0].trim();
  let out: StatsItem;
  if (["live", "catchup", "channel"].includes(k)) out = { kind: "live", item_key: null, title: null };
  else if (["episode", "series"].includes(k)) out = { kind: "episode", item_key: null, title: null };
  else if (["movie", "vod"].includes(k)) out = { kind: "movie", item_key: null, title: null };
  else return { kind: null, item_key: null, title: null };
  if (out.kind === "episode") {
    // Postgres: regexp_replace(base, '\s*[-–:|]?\s*S\d{1,3}\s*[:.]?\s*E\d{1,4}\M.*$', '', 'i') (eerste treffer)
    let pre = base.replace(/\s*[-–:|]?\s*S\d{1,3}\s*[:.]?\s*E\d{1,4}(?![A-Za-z0-9_])[\s\S]*$/i, "").trim();
    pre = pre.replace(/\s*[-–:|·]+$/, "").trim();
    if (pre === "") pre = base;
    out.title = nullif(trim(seriesTitle)) ?? nullif(pre);
    out.item_key = nullif(trim(seriesId)) ?? (out.title !== null ? "t:" + out.title.toLowerCase() : null) ?? cid;
  } else {
    out.title = nullif(base);
    out.item_key = cid ?? (out.title !== null ? "t:" + out.title.toLowerCase() : null);
  }
  if (out.title !== null) out.title = [...out.title].slice(0, 200).join("");
  if (out.item_key !== null) out.item_key = [...out.item_key].slice(0, 200).join("");
  return out;
}

/** Sleutel die van een titel komt ('t:…') vervangen door 'h:' + HMAC(account | sleutel); andere sleutels blijven. */
export async function privateKey(userId: string, itemKey: string | null, key64?: string): Promise<string | null> {
  if (!itemKey || !itemKey.startsWith("t:")) return itemKey;
  return "h:" + await keyedHash("bingr.stats.title.v1", `${userId}|${itemKey}`, key64);
}

/** Velden voor bingr_stream_start / de stream_ping-update: alles wat leesbaar zou zijn, versleuteld. */
export async function sealedStream(userId: string, b: { title?: unknown; kind?: unknown; content_id?: unknown; series_id?: unknown; series_title?: unknown; profile_name?: unknown }, key64?: string) {
  const it = statsItem(b.kind, b.content_id, b.series_id, b.series_title, b.title);
  return {
    title: await sealField(b.title == null ? null : String(b.title).slice(0, 200), key64),
    series_title: await sealField(b.series_title ? String(b.series_title).slice(0, 200) : null, key64),
    profile_name: await sealField(b.profile_name == null ? null : String(b.profile_name).slice(0, 80), key64),
    stat_kind: it.kind,
    stat_key: it.kind ? await privateKey(userId, it.item_key, key64) : null,
    stat_title: await sealField(it.title, key64),
  };
}

/** Rijen voor de app: versleutelde velden terug naar tekst (oude, leesbare rijen blijven gewoon zoals ze zijn). */
// deno-lint-ignore no-explicit-any
export async function openRows(rows: any[], fields: string[], key64?: string): Promise<any[]> {
  return await Promise.all(rows.map(async (r) => {
    const o: Record<string, unknown> = { ...r };
    for (const f of fields) if (f in o) o[f] = await openField(o[f], key64);
    return o;
  }));
}
