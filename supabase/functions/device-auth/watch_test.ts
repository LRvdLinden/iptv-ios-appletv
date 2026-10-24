// Tests voor de versleutelde kijkgegevens (build 146): deno test --allow-env supabase/functions/device-auth/watch_test.ts
// statsItem moet precies doen wat public.bingr_stats_item doet; dezelfde gevallen staan in supabase/tests/profiles_test.sql.
import { openRows, privateKey, sealedStream, statsItem } from "./watch.ts";
import { openField } from "../_shared/sealed.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
Deno.env.set("BINGR_SOURCES_KEY", btoa(String.fromCharCode(...new Uint8Array(32).fill(3))));

Deno.test("statsItem = bingr_stats_item (zelfde gevallen als de SQL-test)", () => {
  eq(statsItem("episode", "e1", null, null, "De Serie · S1:E2 · Pilot"), { kind: "episode", item_key: "t:de serie", title: "De Serie" });
  eq(statsItem("episode", "e1", null, null, "Serie S01E02 Naam"), { kind: "episode", item_key: "t:serie", title: "Serie" });
  eq(statsItem("episode", "e1", null, null, "Serie - S1E2"), { kind: "episode", item_key: "t:serie", title: "Serie" });
  eq(statsItem("series", "e1", "s9", "Echte Titel", "x"), { kind: "episode", item_key: "s9", title: "Echte Titel" });
  eq(statsItem("live", "c1", null, null, "NPO 1 · Journaal"), { kind: "live", item_key: "c1", title: "NPO 1" });
  eq(statsItem("catchup", null, null, null, "NPO 2"), { kind: "live", item_key: "t:npo 2", title: "NPO 2" });
  eq(statsItem("movie", "", null, null, "  Dune  "), { kind: "movie", item_key: "t:dune", title: "Dune" });
  eq(statsItem("radio", "r1", null, null, "x"), { kind: null, item_key: null, title: null });
  eq(statsItem("episode", null, null, null, "S01E01"), { kind: "episode", item_key: "t:s01e01", title: "S01E01" });
});

Deno.test("titelsleutel wordt een vaste HMAC per account; ids blijven", async () => {
  const a = await privateKey("u1", "t:dune"), b = await privateKey("u1", "t:dune"), c = await privateKey("u2", "t:dune");
  ok(a!.startsWith("h:") && a!.length === 34, "h: + 32 hex"); eq(a, b, "vast"); ok(a !== c, "per account anders");
  eq(await privateKey("u1", "c1"), "c1"); eq(await privateKey("u1", null), null);
});

Deno.test("sealedStream: niets leesbaars, terug te lezen", async () => {
  const s = await sealedStream("u1", { title: "De Serie · S1:E2 · Pilot", kind: "episode", content_id: "e1", profile_name: "Emma" });
  for (const f of [s.title, s.profile_name, s.stat_title]) ok(String(f).startsWith("enc1:"), "versleuteld");
  ok(s.stat_key!.startsWith("h:"), "sleutel"); eq(s.stat_kind, "episode"); eq(s.series_title, null);
  eq(await openField(s.stat_title), "De Serie"); eq(await openField(s.title), "De Serie · S1:E2 · Pilot");
  const rows = await openRows([{ title: s.title, profile_name: "oud leesbaar", minutes: 3 }], ["title", "profile_name"]);
  eq(rows, [{ title: "De Serie · S1:E2 · Pilot", profile_name: "oud leesbaar", minutes: 3 }]);
});
