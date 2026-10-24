// Tests voor de diagnose-bijlage (build 146): deno test supabase/functions/_shared/diagnostics_test.ts
import { cleanDiagnostics, DIAG_MAX_IN, DIAG_MAX_OUT, looksPersonal, ticketPlatform } from "./diagnostics.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }

// het voorbeeld uit docs/ACCOUNT.md ("Build 146" → "Diagnose-bijlage")
export const EXAMPLE = {
  schema: 1, kind: "app", createdAt: "2026-10-24T10:15:00.000Z",
  app: { platform: "tvos", version: "1.0.1", build: 146, engine: "vlc" },
  device: { type: "tv", model: "Apple TV 4K (3rd generation)", manufacturer: "Apple", os: "tvOS", osVersion: "26.1", language: "nl-NL", screen: "3840x2160" },
  milestones: [{ name: "splash", ms: 420 }, { name: "profiles", ms: 1310 }, { name: "servers_loaded", ms: 5200, ok: true }],
  memory: { usedMB: 812, totalMB: 3072, appMB: 410, lowMemory: false },
  crash: { at: "2026-10-23T21:02:11.000Z", type: "EXC_BAD_ACCESS", reason: "KERN_INVALID_ADDRESS", stack: ["0 Bingr PlayerView.play() + 120", "1 Bingr LiveTV.zap(to:) + 44"], build: 145 },
  state: {
    signedIn: true, profiles: 3, servers: 2, serverKinds: ["Xtream Codes", "M3U / M3U8"], lastSync: "2026-10-24T10:14:02.000Z", lastSyncOk: true,
    plan: "lifetime", pushEnabled: false, channels: 12450, movies: 30210, series: 4120, uptimeS: 5400,
    network: { online: true, type: "ethernet", backend: "ok", backendMs: 180, provider: "slow", providerMs: 2900, vpn: false },
    storage: { usedMB: 950, freeMB: 18000, cacheMB: 640, dbMB: 120 },
  },
};

Deno.test("voorbeeld uit het contract komt ongewijzigd door", () => {
  const r = cleanDiagnostics(EXAMPLE);
  if (!r.ok) throw new Error(r.error);
  eq(r.value, EXAMPLE); eq(r.stripped, false);
});

Deno.test("verplicht: kind en app.platform; te groot", () => {
  eq(cleanDiagnostics(null), { ok: false, error: "bad_diagnostics" });
  eq(cleanDiagnostics({ ...EXAMPLE, kind: "crash" }), { ok: false, error: "bad_diagnostics", field: "kind" });
  eq(cleanDiagnostics({ ...EXAMPLE, app: { platform: "symbian" } }), { ok: false, error: "bad_diagnostics", field: "app.platform" });
  const big = cleanDiagnostics({ ...EXAMPLE, junk: "x".repeat(DIAG_MAX_IN) });
  ok(!big.ok && big.error === "diagnostics_too_large", "te groot");
  const min = cleanDiagnostics({ kind: "start", app: { platform: "tizen" } });
  ok(min.ok, "minimaal");
  if (min.ok) eq(min.value, { schema: 1, kind: "start", app: { platform: "tizen" } });
});

Deno.test("geen persoonsgegevens, URL's, servers of onbekende velden", () => {
  const r = cleanDiagnostics({
    ...EXAMPLE, email: "leon@example.com", serverURL: "http://provider.example:8080",
    device: { ...EXAMPLE.device, model: "iPhone van Léon leon@example.com", name: "Léons iPhone" },
    state: { ...EXAMPLE.state, username: "leon", serverKinds: ["http://x.example/get.php?username=a&password=b", "Plex"], network: { ...EXAMPLE.state.network, ip: "192.168.1.10" } },
    crash: { ...EXAMPLE.crash, reason: "Could not load http://provider.example/live/user/pass/1.ts", stack: ["0 /Users/leon/Bingr/Player.swift:10", "1 Bingr ok"] },
    milestones: [{ name: "Splash Screen!", ms: 1 }, { name: "ok_1", ms: -5 }, { name: "ok_2", ms: 10 }],
  });
  if (!r.ok) throw new Error(r.error);
  ok(r.stripped, "stripped");
  const j = JSON.stringify(r.value);
  for (const bad of ["example", "username", "192.168", "/Users/", "Léon", "serverURL", "password"]) ok(!j.includes(bad), `geen ${bad}`);
  eq(r.value.device.model, undefined); eq(r.value.state.serverKinds, ["Plex"]); eq(r.value.crash.stack, ["1 Bingr ok"]);
  eq(r.value.crash.reason, undefined); eq(r.value.milestones, [{ name: "ok_2", ms: 10 }]);
});

Deno.test("typen en grenzen", () => {
  const r = cleanDiagnostics({
    kind: "app", app: { platform: "android", build: "146", version: 1 }, device: { type: "fridge", language: "nl-NL; rm -rf" },
    memory: { usedMB: "812.55", totalMB: -1 }, state: { servers: 2.6, lastSync: "gisteren", signedIn: "ja", network: { type: "5g" } },
    milestones: Array.from({ length: 100 }, (_, i) => ({ name: `m${i}`, ms: i })),
  });
  if (!r.ok) throw new Error(r.error);
  eq(r.value.app, { platform: "android", version: "1", build: 146 });
  eq(r.value.device, undefined, "onbekend type en taal weg");
  eq(r.value.memory, { usedMB: 812.6 });
  eq(r.value.state, { servers: 3 });
  eq(r.value.milestones.length, 40, "max. 40 mijlpalen");
});

Deno.test("te groot na opschonen: stack en mijlpalen ingekort", () => {
  const r = cleanDiagnostics({ ...EXAMPLE, crash: { ...EXAMPLE.crash, stack: Array.from({ length: 50 }, (_, i) => `${i} Bingr ${"Frame".repeat(36)}`) },
    milestones: Array.from({ length: 40 }, (_, i) => ({ name: `stap_${i}`, ms: i })) });
  if (!r.ok) throw new Error(r.error);
  ok(JSON.stringify(r.value).length <= DIAG_MAX_OUT, "binnen de grens");
  ok(r.value.crash.stack[0].startsWith("0 Bingr"), "begin van de stack blijft");
  const huge = cleanDiagnostics({ ...EXAMPLE, crash: { ...EXAMPLE.crash, stack: Array.from({ length: 50 }, (_, i) => `${i} ${"B".repeat(197)}`) },
    milestones: Array.from({ length: 40 }, (_, i) => ({ name: `s${"t".repeat(38)}${i}`.slice(0, 40), ms: 600000 })),
    state: { ...EXAMPLE.state, serverKinds: Array.from({ length: 10 }, () => "K".repeat(20)) } });
  if (!huge.ok) throw new Error(huge.error);
  ok(JSON.stringify(huge.value).length <= DIAG_MAX_OUT, "groot: binnen de grens");
  ok(huge.value.crash.stack.length < 50, "stack korter");
});

Deno.test("hulpjes", () => {
  ok(looksPersonal("rtmp://x") && looksPersonal("a@b.nl") && looksPersonal("10.0.0.1") && looksPersonal("AA:BB:CC:DD:EE:FF") && looksPersonal("C:\\Users\\leon"), "persoonlijk");
  ok(!looksPersonal("Apple TV 4K (3rd generation)") && !looksPersonal("SM-T870") && !looksPersonal("26.1"), "gewoon");
  eq(ticketPlatform("ipados"), "ios"); eq(ticketPlatform("windows"), "windows"); eq(ticketPlatform(undefined), null);
});
