// Build 68: kijkstatistieken. Pure functies (geen database), zodat de periodes en het antwoord los te testen zijn
// (stats_test.ts: `deno test supabase/functions/device-auth/stats_test.ts`).
export const DEFAULT_TZ = "Europe/Amsterdam";
export type Period = "week" | "month" | "year";
export const PERIODS: Period[] = ["week", "month", "year"];

/** Geldige IANA-tijdzone (max. 64 tekens), anders null. */
export function validTz(v: unknown): string | null {
  const s = v == null ? "" : String(v).trim().slice(0, 64);
  if (!s || !/^[A-Za-z0-9_+\-/]+$/.test(s)) return null;
  try { new Intl.DateTimeFormat("en-US", { timeZone: s }); return s; } catch { return null; }
}

/** De lokale datum (YYYY-MM-DD) in een tijdzone. */
export function todayIn(tz: string, now: Date = new Date()): string {
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  const g = (t: string) => p.find((x) => x.type === t)!.value;
  return `${g("year")}-${g("month")}-${g("day")}`;
}

const D = (iso: string) => new Date(iso + "T00:00:00Z");
const iso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (d: Date, n: number) => new Date(d.getTime() + n * 864e5);
const pad = (n: number) => String(n).padStart(2, "0");

/** ISO-weeknummer ("2026-W42") van een datum. */
export function isoWeek(day: string): string {
  const d = D(day);
  const dow = (d.getUTCDay() + 6) % 7; // maandag = 0
  const thu = addDays(d, 3 - dow);
  const jan1 = Date.UTC(thu.getUTCFullYear(), 0, 1);
  const wk = 1 + Math.floor((thu.getTime() - jan1) / (7 * 864e5));
  return `${thu.getUTCFullYear()}-W${pad(wk)}`;
}

export type Range = {
  period: Period; offset: number; from: string; to: string; label_hint: string; byMonth: boolean; buckets: string[];
};

/** Periode rond `today` (lokale datum): week (maandag t/m zondag), maand of jaar; offset 0 = huidig, -1 = vorige … */
export function periodRange(periodIn: unknown, offsetIn: unknown, today: string): Range {
  const period: Period = PERIODS.includes(periodIn as Period) ? periodIn as Period : "month";
  const n = Math.trunc(Number(offsetIn ?? 0));
  const offset = Number.isFinite(n) ? Math.max(-600, Math.min(0, n)) : 0;
  const t = D(today);
  let from: Date, to: Date;
  if (period === "week") {
    const monday = addDays(t, -((t.getUTCDay() + 6) % 7));
    from = addDays(monday, offset * 7); to = addDays(from, 6);
  } else if (period === "month") {
    from = new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() + offset, 1));
    to = new Date(Date.UTC(from.getUTCFullYear(), from.getUTCMonth() + 1, 0));
  } else {
    from = new Date(Date.UTC(t.getUTCFullYear() + offset, 0, 1));
    to = new Date(Date.UTC(t.getUTCFullYear() + offset, 11, 31));
  }
  const buckets: string[] = [];
  if (period === "year") {
    for (let m = 1; m <= 12; m++) buckets.push(`${from.getUTCFullYear()}-${pad(m)}`);
  } else {
    for (let d = from; d <= to; d = addDays(d, 1)) buckets.push(iso(d));
  }
  const f = iso(from);
  const label_hint = period === "week" ? isoWeek(f) : period === "month" ? f.slice(0, 7) : f.slice(0, 4);
  return { period, offset, from: f, to: iso(to), label_hint, byMonth: period === "year", buckets };
}

/** Wat bingr_watch_stats (SQL) teruggeeft. */
export type Raw = {
  buckets?: { key: string; kind: string; minutes: number | string }[];
  items?: { kind: string; item_key: string; title: string | null; minutes: number | string; plays: number; episodes: number }[];
  counts?: { kind: string; items: number; episodes: number | string | null }[];
  profiles?: { profile_id: string; profile_name: string | null; minutes: number | string }[];
  since?: string | null;
};

const num = (v: unknown) => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
const r = (v: unknown) => Math.round(num(v));

/** Het antwoord van watch_stats; alle minuten zijn hele getallen (afgerond). */
export function buildStats(raw: Raw, range: Range, opts: { profileId: string | null; tz: string; profileNames?: Map<string, string> }) {
  const per = new Map<string, { m: number; movie: number; episode: number; live: number }>();
  for (const k of range.buckets) per.set(k, { m: 0, movie: 0, episode: 0, live: 0 });
  const kindMin = { movie: 0, episode: 0, live: 0 } as Record<string, number>;
  for (const b of raw.buckets ?? []) {
    const kind = b.kind as "movie" | "episode" | "live";
    if (!(kind in kindMin)) continue;
    const x = num(b.minutes);
    kindMin[kind] += x;
    const slot = per.get(b.key);
    if (slot) { slot[kind] += x; slot.m += x; }
  }
  const counts = new Map((raw.counts ?? []).map((c) => [c.kind, c]));
  const items = raw.items ?? [];
  const top = (kind: string, withEp: boolean) => items.filter((i) => i.kind === kind)
    .sort((a, b) => num(b.minutes) - num(a.minutes) || String(a.item_key).localeCompare(String(b.item_key))).slice(0, 10)
    .map((i) => withEp
      ? { title: i.title ?? "", item_key: i.item_key, minutes: r(i.minutes), episodes: num(i.episodes) }
      : { title: i.title ?? "", item_key: i.item_key, minutes: r(i.minutes) });
  const names = opts.profileNames ?? new Map();
  const profiles = opts.profileId != null ? [] : (raw.profiles ?? [])
    .map((p) => ({ profile_id: p.profile_id || null, profile_name: (p.profile_id && names.get(p.profile_id)) || p.profile_name || null, minutes: r(p.minutes) }))
    .sort((a, b) => b.minutes - a.minutes);
  return {
    period: range.period, offset: range.offset, from: range.from, to: range.to, label_hint: range.label_hint, tz: opts.tz,
    profile_id: opts.profileId,
    totals: {
      minutes: r(kindMin.movie + kindMin.episode + kindMin.live),
      movies: { count: num(counts.get("movie")?.items), minutes: r(kindMin.movie) },
      series: { shows: num(counts.get("episode")?.items), episodes: num(counts.get("episode")?.episodes), minutes: r(kindMin.episode) },
      live: { channels: num(counts.get("live")?.items), minutes: r(kindMin.live) },
    },
    by_bucket: range.buckets.map((k) => {
      const s = per.get(k)!;
      return { key: k, minutes: r(s.m), movie_minutes: r(s.movie), episode_minutes: r(s.episode), live_minutes: r(s.live) };
    }),
    top: { series: top("episode", true), movies: top("movie", false), channels: top("live", false) },
    profiles,
    since: raw.since ?? null,
  };
}
