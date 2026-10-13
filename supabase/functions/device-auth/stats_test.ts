// deno test supabase/functions/device-auth/stats_test.ts
// zonder externe imports (werkt ook offline)
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`verwacht ${y}\n  kreeg  ${x}`);
}
import { buildStats, isoWeek, periodRange, todayIn, validTz } from "./stats.ts";

Deno.test("week begint op maandag, ook vanaf zondag", () => {
  // 13 okt 2026 = dinsdag
  const w = periodRange("week", 0, "2026-10-13");
  assertEquals([w.from, w.to, w.buckets.length, w.label_hint], ["2026-10-12", "2026-10-18", 7, "2026-W42"]);
  const sun = periodRange("week", 0, "2026-10-18");
  assertEquals([sun.from, sun.to], ["2026-10-12", "2026-10-18"]);
  const mon = periodRange("week", 0, "2026-10-12");
  assertEquals(mon.from, "2026-10-12");
  const prev = periodRange("week", -1, "2026-10-13");
  assertEquals([prev.from, prev.to, prev.buckets[0], prev.buckets[6]], ["2026-10-05", "2026-10-11", "2026-10-05", "2026-10-11"]);
  // over de jaargrens
  const y = periodRange("week", 0, "2027-01-01");
  assertEquals([y.from, y.to, y.label_hint], ["2026-12-28", "2027-01-03", "2026-W53"]);
});

Deno.test("maand: dagen, offsets en schrikkeljaar", () => {
  const m = periodRange("month", 0, "2026-10-13");
  assertEquals([m.from, m.to, m.buckets.length, m.label_hint, m.byMonth], ["2026-10-01", "2026-10-31", 31, "2026-10", false]);
  const feb = periodRange("month", -8, "2026-10-13");
  assertEquals([feb.from, feb.to, feb.buckets.length], ["2026-02-01", "2026-02-28", 28]);
  const leap = periodRange("month", -1, "2028-03-31");
  assertEquals([leap.from, leap.to, leap.buckets.length], ["2028-02-01", "2028-02-29", 29]);
  const back = periodRange("month", -10, "2026-10-13");
  assertEquals([back.from, back.to], ["2025-12-01", "2025-12-31"]);
});

Deno.test("jaar: 12 maanden als buckets", () => {
  const y = periodRange("year", -1, "2026-10-13");
  assertEquals([y.from, y.to, y.label_hint, y.byMonth, y.buckets.length, y.buckets[0], y.buckets[11]],
    ["2025-01-01", "2025-12-31", "2025", true, 12, "2025-01", "2025-12"]);
});

Deno.test("standaard en grenzen", () => {
  const d = periodRange(undefined, undefined, "2026-10-13");
  assertEquals([d.period, d.offset], ["month", 0]);
  assertEquals(periodRange("bogus", 5, "2026-10-13").offset, 0); // toekomst kan niet
  assertEquals(periodRange("week", -9999, "2026-10-13").offset, -600);
  assertEquals(periodRange("week", "x", "2026-10-13").offset, 0);
});

Deno.test("tijdzone", () => {
  assertEquals(validTz("Europe/Amsterdam"), "Europe/Amsterdam");
  assertEquals(validTz("Mars/Olympus"), null);
  assertEquals(validTz(""), null);
  assertEquals(validTz("'; drop table x"), null);
  const at = new Date("2026-10-12T23:30:00Z");
  assertEquals(todayIn("Europe/Amsterdam", at), "2026-10-13");
  assertEquals(todayIn("America/New_York", at), "2026-10-12");
  assertEquals(todayIn("UTC", at), "2026-10-12");
  // maandag 00:30 in Amsterdam is nog zondag in UTC: de week van Amsterdam begint al
  const mon = new Date("2026-10-11T22:30:00Z");
  assertEquals(periodRange("week", 0, todayIn("Europe/Amsterdam", mon)).from, "2026-10-12");
  assertEquals(periodRange("week", 0, todayIn("UTC", mon)).from, "2026-10-05");
});

Deno.test("isoWeek", () => {
  assertEquals(isoWeek("2026-01-01"), "2026-W01");
  assertEquals(isoWeek("2027-01-04"), "2027-W01");
});

Deno.test("buildStats: totalen, buckets, top en profielen", () => {
  const range = periodRange("week", 0, "2026-10-13");
  const raw = {
    buckets: [
      { key: "2026-10-12", kind: "movie", minutes: "95.4" },
      { key: "2026-10-12", kind: "episode", minutes: 44.6 },
      { key: "2026-10-13", kind: "live", minutes: 30 },
      { key: "2026-10-13", kind: "radio", minutes: 999 }, // onbekend: negeren
    ],
    items: [
      { kind: "episode", item_key: "xs7", title: "Bluey", minutes: 44.6, plays: 3, episodes: 2 },
      { kind: "movie", item_key: "xv5", title: "Dune", minutes: 95.4, plays: 1, episodes: 0 },
      { kind: "live", item_key: "x12", title: "NPO 1", minutes: 20, plays: 1, episodes: 0 },
      { kind: "live", item_key: "x4", title: "RTL 4", minutes: 10, plays: 2, episodes: 0 },
    ],
    counts: [{ kind: "movie", items: 1, episodes: 0 }, { kind: "episode", items: 1, episodes: "2" }, { kind: "live", items: 2, episodes: 0 }],
    profiles: [{ profile_id: "p2", profile_name: "Kids (oud)", minutes: 44.6 }, { profile_id: "p1", profile_name: "Léon", minutes: 125.4 }, { profile_id: "", profile_name: null, minutes: 0.2 }],
    since: "2026-10-01",
  };
  const s = buildStats(raw, range, { profileId: null, tz: "Europe/Amsterdam", profileNames: new Map([["p2", "Kids"]]) });
  assertEquals(s.totals, { minutes: 170, movies: { count: 1, minutes: 95 }, series: { shows: 1, episodes: 2, minutes: 45 }, live: { channels: 2, minutes: 30 } });
  assertEquals(s.by_bucket.length, 7);
  assertEquals(s.by_bucket[0], { key: "2026-10-12", minutes: 140, movie_minutes: 95, episode_minutes: 45, live_minutes: 0 });
  assertEquals(s.by_bucket[1], { key: "2026-10-13", minutes: 30, movie_minutes: 0, episode_minutes: 0, live_minutes: 30 });
  assertEquals(s.by_bucket[6].minutes, 0);
  assertEquals(s.top.channels.map((c) => c.title), ["NPO 1", "RTL 4"]);
  assertEquals(s.top.series[0], { title: "Bluey", item_key: "xs7", minutes: 45, episodes: 2 });
  assertEquals(s.top.movies[0], { title: "Dune", item_key: "xv5", minutes: 95 });
  assertEquals(s.profiles, [
    { profile_id: "p1", profile_name: "Léon", minutes: 125 },
    { profile_id: "p2", profile_name: "Kids", minutes: 45 },
    { profile_id: null, profile_name: null, minutes: 0 },
  ]);
  assertEquals([s.since, s.period, s.from, s.to, s.profile_id], ["2026-10-01", "week", "2026-10-12", "2026-10-18", null]);
  // één profiel: geen uitsplitsing
  assertEquals(buildStats(raw, range, { profileId: "p1", tz: "UTC" }).profiles, []);
});

Deno.test("buildStats: leeg en jaar-buckets", () => {
  const range = periodRange("year", 0, "2026-10-13");
  const s = buildStats({ buckets: [{ key: "2026-10", kind: "live", minutes: 12 }] }, range, { profileId: null, tz: "UTC" });
  assertEquals(s.by_bucket.length, 12);
  assertEquals(s.by_bucket[9], { key: "2026-10", minutes: 12, movie_minutes: 0, episode_minutes: 0, live_minutes: 12 });
  assertEquals(s.totals.live, { channels: 0, minutes: 12 });
  const e = buildStats({}, range, { profileId: null, tz: "UTC" });
  assertEquals([e.totals.minutes, e.since, e.top.series.length, e.profiles.length], [0, null, 0, 0]);
});

Deno.test("top 10 per soort", () => {
  const range = periodRange("month", 0, "2026-10-13");
  const items = Array.from({ length: 15 }, (_, i) => ({ kind: "movie", item_key: "m" + i, title: "M" + i, minutes: i + 1, plays: 1, episodes: 0 }));
  const s = buildStats({ items }, range, { profileId: null, tz: "UTC" });
  assertEquals(s.top.movies.length, 10);
  assertEquals(s.top.movies[0].item_key, "m14");
});
