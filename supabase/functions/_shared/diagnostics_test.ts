// Tests voor de diagnose-bijlage (build 146): deno test supabase/functions/_shared/diagnostics_test.ts
import { cleanDiagnostics, DIAG_MAX_IN, DIAG_MAX_OUT, looksPersonal, scrubText, ticketPlatform } from "./diagnostics.ts";

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
  eq(r.value.device.model, undefined); eq(r.value.state.serverKinds, ["Plex"]);
  // build 147: stack-regels en foutteksten blijven, zonder adres of pad
  eq(r.value.crash.stack, ["0 …/Player.swift:10", "1 Bingr ok"]);
  eq(r.value.crash.reason, "Could not load [url]"); eq(r.value.milestones, [{ name: "ok_2", ms: 10 }]);
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
  eq(huge.value.crash.stack.length, 50, "build 147: past nu binnen 20 KB (zie schema 2 voor inkorten)");
});

// build 147: diagnose-schema 2 (docs/ACCOUNT.md, "Build 147")
export const EXAMPLE2 = {
  schema: 2, kind: "start", createdAt: "2026-10-24T10:15:00.000Z",
  app: { platform: "ios", version: "1.0.1", build: 147, engine: "vlc" },
  device: { type: "phone", model: "iPhone 17 Pro Max", manufacturer: "Apple", os: "iOS", osVersion: "27.2", language: "nl-NL", screen: "1320x2868" },
  start: {
    summary: "hung", appMs: 7400, userWaitMs: 7000, maxHangMs: 1200,
    previous: { problem: "hang", milestone: "ready", seconds: 80.1, foreground: true, task: "catalogus sorteren", at: "2026-10-24T09:58:00.000Z", build: 146,
      stack: ["0 Bingr CatalogStore.sort(_:) + 312", "1 Bingr HomeViewModel.rebuildRows() + 88"] },
  },
  milestones: [{ name: "launch", ms: 0 }, { name: "session", ms: 200 }, { name: "first_frame", ms: 300 }, { name: "ready", ms: 14400 }],
  fetch: [
    { server: "s1", kind: "live", status: "ok", count: 1056 }, { server: "s1", kind: "movie", status: "ok", count: 10259 },
    { server: "s1", kind: "series", status: "failed", count: 0, error: "timeout" }, { server: "s2", kind: "series", status: "empty", count: 0 },
    { server: "s2", kind: "movie", status: "hidden", count: 812 },
  ],
  network: { type: "wifi", online: true },
  storage: { totalMB: 156, cacheMB: 24, catalogMB: 120, downloadsMB: 12, freeMB: 81234 },
  memory: { usedMB: 332, appMB: 332, lowMemory: false },
  state: { signedIn: true, profiles: 2, servers: 2, channels: 1056, movies: 10259, series: 0 },
};

Deno.test("schema 2: voorbeeld uit het contract komt ongewijzigd door", () => {
  const r = cleanDiagnostics(EXAMPLE2);
  if (!r.ok) throw new Error(r.error);
  eq(r.value, EXAMPLE2); eq(r.stripped, false);
});

Deno.test("schema 2: velden alleen bij schema 2; schema 1 blijft schema 1", () => {
  const { schema: _s, ...rest } = EXAMPLE2;
  const r = cleanDiagnostics({ ...rest, schema: 1 });
  if (!r.ok) throw new Error(r.error);
  ok(r.stripped, "stripped");
  eq([r.value.schema, r.value.start, r.value.fetch, r.value.network, r.value.storage], [1, undefined, undefined, undefined, undefined]);
  const z = cleanDiagnostics(rest); // zonder schema = 1
  ok(z.ok && z.value.schema === 1 && !z.value.start, "zonder schema");
  const v3 = cleanDiagnostics({ ...EXAMPLE2, schema: 3, extra: { x: 1 } }); // nieuwer: als 2, onbekend weg
  ok(v3.ok && v3.value.schema === 2 && v3.value.start?.summary === "hung" && !v3.value.extra && v3.stripped, "schema 3");
  ok(cleanDiagnostics({ kind: "start", schema: 2, app: { platform: "webos" } }).ok, "webos");
});

Deno.test("schema 2: typen, opsommingen en grenzen", () => {
  const r = cleanDiagnostics({
    schema: 2, kind: "start", app: { platform: "android" },
    start: { summary: "meh", appMs: -1, userWaitMs: "1200", previous: { problem: "freeze", milestone: "Klaar!", seconds: 99999, foreground: "ja", task: 42 } },
    fetch: [
      { server: "provider.example.com", kind: "live", status: "ok", count: 1 }, { server: "s1", kind: "radio", status: "ok" },
      { server: "s1", kind: "series", status: "broken" }, { server: "s3", kind: "series", status: "failed", error: "HTTP 503 from http://p.example/player_api.php?username=a&password=b" },
      ...Array.from({ length: 50 }, (_, i) => ({ server: `s${(i % 9) + 1}`, kind: "movie", status: "ok", count: i })),
    ],
    network: { type: "5g" }, storage: { totalMB: "100", cacheMB: -3 },
  });
  if (!r.ok) throw new Error(r.error);
  eq(r.value.start, { userWaitMs: 1200, previous: { task: "42" } });
  eq(r.value.fetch[0], { server: "s3", kind: "series", status: "failed", error: "HTTP 503 from [url]" });
  eq(r.value.fetch.length, 30, "max. 30 regels fetch");
  eq(r.value.network, undefined); eq(r.value.storage, { totalMB: 100 });
});

Deno.test("schema 2: geen adressen, paden of servernamen in stack, taak en fouten", () => {
  const r = cleanDiagnostics({
    ...EXAMPLE2,
    start: { ...EXAMPLE2.start, previous: { ...EXAMPLE2.start.previous, task: "sync met leon@example.com",
      stack: ["0 Bingr XtreamClient.get(http://provider.example:8080/get.php?username=leon&password=geheim) + 4",
        "1 libsystem /var/mobile/Containers/Data/Application/ABC/Library/Caches/catalog.db",
        "2 Bingr Net.connect(10.0.0.12:8080)", "3 Bingr Portal(AA:BB:CC:DD:EE:FF)", "4 Bingr resolve iptv.provider-x.tv failed",
        "5 C:\\Users\\Leon\\AppData\\Local\\Bingr\\app.js:12", "6 Bingr ok", "7 at nl.lrvdlinden.bingr.MainActivity.onCreate(MainActivity.kt:42)"] } },
    fetch: [{ server: "s1", kind: "series", status: "failed", error: "ENOTFOUND my.iptv-host.net" }],
  });
  if (!r.ok) throw new Error(r.error);
  ok(r.stripped, "stripped");
  const j = JSON.stringify(r.value);
  for (const bad of ["example", "leon", "Leon", "geheim", "10.0.0.12", "AA:BB", "provider-x", "iptv-host", "/var/mobile", "Containers"]) ok(!j.includes(bad), `geen ${bad}`);
  const p = r.value.start.previous;
  eq(p.task, "sync met [e-mail]");
  eq(p.stack, ["0 Bingr XtreamClient.get([url]) + 4", "1 libsystem …/catalog.db", "2 Bingr Net.connect([ip])", "3 Bingr Portal([mac])",
    "4 Bingr resolve [host] failed", "5 …/app.js:12", "6 Bingr ok", "7 at nl.lrvdlinden.bingr.MainActivity.onCreate(MainActivity.kt:42)"]);
  eq(r.value.fetch[0].error, "ENOTFOUND [host]");
});

Deno.test("schema 2: te groot na opschonen blijft begrensd", () => {
  const long = (i: number) => `${i} Bingr ${"Frame".repeat(38)}`;
  const r = cleanDiagnostics({ ...EXAMPLE2, crash: { type: "EXC_BAD_ACCESS", stack: Array.from({ length: 50 }, (_, i) => long(i)) },
    start: { ...EXAMPLE2.start, previous: { ...EXAMPLE2.start.previous, stack: Array.from({ length: 30 }, (_, i) => long(i)) } },
    milestones: Array.from({ length: 40 }, (_, i) => ({ name: `stap_${i}`, ms: i })),
    fetch: Array.from({ length: 30 }, (_, i) => ({ server: `s${(i % 9) + 1}`, kind: "movie", status: "failed", error: "E".repeat(60) })) });
  if (!r.ok) throw new Error(r.error);
  ok(JSON.stringify(r.value).length <= DIAG_MAX_OUT, "binnen de grens");
  ok(r.value.start.summary === "hung" && r.value.start.previous.problem === "hang", "kern blijft");
  ok(r.value.crash.stack.length < 50 && r.value.crash.stack[0].startsWith("0 Bingr"), "stack ingekort, begin blijft");
  ok(!cleanDiagnostics({ ...EXAMPLE2, junk: "x".repeat(DIAG_MAX_IN) }).ok, "ruw te groot");
});

Deno.test("scrubText", () => {
  eq(scrubText("Player.swift:120", 200), "Player.swift:120");
  eq(scrubText("Bingr.PlayerView.play()", 200), "Bingr.PlayerView.play()");
  eq(scrubText("com.google.android.exoplayer2.source.MediaSource", 200), "com.google.android.exoplayer2.source.MediaSource");
  eq(scrubText("GET cdn.example.com:8443 timeout", 200), "GET [host] timeout");
  eq(scrubText("fe80::1ff:fe23:4567:890a down", 200), "[ip] down");
  eq(scrubText("   ", 200), undefined);
});

Deno.test("hulpjes", () => {
  ok(looksPersonal("rtmp://x") && looksPersonal("a@b.nl") && looksPersonal("10.0.0.1") && looksPersonal("AA:BB:CC:DD:EE:FF") && looksPersonal("C:\\Users\\leon"), "persoonlijk");
  ok(!looksPersonal("Apple TV 4K (3rd generation)") && !looksPersonal("SM-T870") && !looksPersonal("26.1"), "gewoon");
  eq(ticketPlatform("ipados"), "ios"); eq(ticketPlatform("windows"), "windows"); eq(ticketPlatform(undefined), null);
});
