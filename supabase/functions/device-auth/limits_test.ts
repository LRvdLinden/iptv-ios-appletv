// Tests voor build 171 (#31): deno test supabase/functions/device-auth/limits_test.ts
import { limitDevices, limitStreams, suggestRemove } from "./limits.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

const devices = [
  { device_id: "tv", name: "Apple TV", platform: "tvos", created_at: "2026-01-01T00:00:00Z", last_seen_at: "2026-11-15T10:00:00Z" },
  { device_id: "oud", name: "Oude iPad", platform: "ipados", created_at: "2026-01-01T00:00:00Z", last_seen_at: "2026-08-01T10:00:00Z" },
  { device_id: "me", name: "iPhone", platform: "ios", created_at: "2026-01-01T00:00:00Z", last_seen_at: "2026-07-01T10:00:00Z", current: true },
];
const streams = [{ device_id: "tv", profile_id: "p1", profile_name: "Léon", title: "NPO 1", kind: "live", last_ping: "2026-11-15T10:01:00Z" }];

Deno.test("limitDevices: oude velden blijven, nieuwe erbij", () => {
  const d = limitDevices(devices, streams);
  eq(d.map((x) => x.device_id), ["tv", "oud", "me"], "volgorde gelijk");
  eq(d[0].name, "Apple TV");
  eq(d[0].last_seen_at, "2026-11-15T10:00:00Z", "oud veld blijft");
  eq(d[0].last_seen, "2026-11-15T10:00:00Z");
  eq([d[0].watching, d[0].profile_name, d[0].title], [true, "Léon", "NPO 1"]);
  eq([d[1].watching, d[1].title, d[1].current], [false, null, false]);
  eq(d[2].current, true);
});

Deno.test("suggestRemove: langst niet gebruikt, niet dit apparaat en niet aan het kijken", () => {
  eq(suggestRemove(limitDevices(devices, streams)), { device_id: "oud", last_seen: "2026-08-01T10:00:00Z" });
  eq(suggestRemove(limitDevices([devices[0]], streams)), null);
});

Deno.test("limitStreams: last_seen en current", () => {
  const s = limitStreams(streams, devices, "tv");
  eq(s[0].last_seen, "2026-11-15T10:01:00Z");
  eq(s[0].device_last_seen, "2026-11-15T10:00:00Z");
  eq(s[0].current, true);
  eq(limitStreams(streams, [], "me")[0].current, false);
  eq(limitStreams([{ device_id: "x" }], [{ device_id: "x", last_seen_at: "2026-11-01T00:00:00Z" }])[0].last_seen, "2026-11-01T00:00:00Z");
});
