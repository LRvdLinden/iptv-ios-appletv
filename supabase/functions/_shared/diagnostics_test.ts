// Tests voor de diagnose-bijlage (build 146): deno test supabase/functions/_shared/diagnostics_test.ts
import { cleanDiagnostics, DIAG_CODES, DIAG_MAX_IN, DIAG_MAX_OUT, looksPersonal, scrubText, ticketPlatform } from "./diagnostics.ts";

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
  const v3 = cleanDiagnostics({ ...EXAMPLE2, schema: 3, extra: { x: 1 } }); // build 148: schema 3 bestaat, onbekend weg
  ok(v3.ok && v3.value.schema === 3 && v3.value.start?.summary === "hung" && !v3.value.extra && v3.stripped, "schema 3");
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

// build 148: diagnose-schema 3 (docs/ACCOUNT.md, "Build 148")
export const EXAMPLE3 = {
  schema: 3, kind: "start", createdAt: "2026-10-24T14:04:00.000Z",
  app: { platform: "ios", version: "1.0.1", build: 148, engine: "vlc", lang: "nl" },
  device: { type: "phone", model: "iPhone 17 Pro Max", manufacturer: "Apple", os: "iOS", osVersion: "27.2", language: "nl-NL" },
  start: {
    summary: "slow", appMs: 5300, userWaitMs: 11600, maxHangMs: 5500,
    longestHang: { ms: 5500, task: "apply", milestone: "ready", foreground: true, stack: ["0 Bingr CatalogStore.apply(_:) + 210", "1 Bingr ServerSync.finish() + 64"] },
    previous: { problem: "hang", milestone: "ready", seconds: 110, foreground: true, task: "apply", build: 147 },
  },
  milestones: [{ code: "started", ms: 0 }, { code: "first_frame", ms: 300 }, { code: "profile_picked", ms: 12100 }, { code: "ready", ms: 16900 },
    { code: "fetch", ms: 20800 }, { code: "save", ms: 42300 }],
  updates: [{ server: "s1", at: "2026-10-24T14:04:20.000Z", phases: [{ code: "fetch", ms: 3900, memMB: 210 }, { code: "parse", ms: 6200, memMB: 455 },
    { code: "index", ms: 2100, memMB: 430 }, { code: "apply", ms: 5500, memMB: 440 }, { code: "save", ms: 3800, memMB: 320 }], totalMs: 21500, peakMB: 455, result: "ok" }],
  fetch: [
    { server: "s1", kind: "live", status: "ok", delivered: 11784, visible: 1056, hidden: { categories: 10728, kids: 0, duplicates: 0, other: 0 } },
    { server: "s1", kind: "movie", status: "ok", delivered: 36593, visible: 10286, hidden: { categories: 26307, kids: 0, duplicates: 0, other: 0 } },
    { server: "s1", kind: "series", status: "ok", delivered: 8773, visible: 3570, hidden: { categories: 5203, kids: 0, duplicates: 0, other: 0 } },
  ],
  network: { type: "wifi", online: true },
  memory: { appMB: 455, lowMemory: false },
  state: { signedIn: true, profiles: 2, servers: 1, channels: 1056, movies: 10286, series: 3570 },
};

Deno.test("schema 3: voorbeeld uit het contract komt ongewijzigd door", () => {
  const r = cleanDiagnostics(EXAMPLE3);
  if (!r.ok) throw new Error(r.error);
  eq(r.value, EXAMPLE3); eq(r.stripped, false);
  // het voorbeeld in ACCOUNT.md is gelijk aan EXAMPLE3
  const doc = Deno.readTextFileSync(new URL("../../../docs/ACCOUNT.md", import.meta.url));
  const block = doc.split("## Build 148")[1].split("```json")[1].split("```")[0];
  eq(JSON.parse(block), EXAMPLE3, "ACCOUNT.md");
  for (const c of DIAG_CODES) ok(/^[a-z][a-z0-9_]{0,39}$/.test(c) && doc.includes("`" + c + "`"), `code ${c} in het contract`);
});

Deno.test("schema 3: nieuwe velden alleen bij schema 3; schema 2 en 1 blijven geldig", () => {
  const r2 = cleanDiagnostics({ ...EXAMPLE3, schema: 2 });
  if (!r2.ok) throw new Error(r2.error);
  ok(r2.stripped, "stripped");
  eq([r2.value.schema, r2.value.updates, r2.value.start.longestHang, r2.value.app.lang, r2.value.milestones, r2.value.fetch[0].delivered],
    [2, undefined, undefined, undefined, undefined, undefined]);
  eq(r2.value.fetch[0], { server: "s1", kind: "live", status: "ok" });
  const r1 = cleanDiagnostics({ ...EXAMPLE3, schema: 1 });
  ok(r1.ok && r1.value.schema === 1 && !r1.value.start && !r1.value.updates && !r1.value.fetch, "schema 1");
  const r4 = cleanDiagnostics({ ...EXAMPLE3, schema: 4 });
  ok(r4.ok && r4.value.schema === 3 && r4.value.updates.length === 1, "nieuwer = 3");
  // oude naam naast de code mag
  const both = cleanDiagnostics({ ...EXAMPLE3, milestones: [{ code: "ready", name: "servers_loaded", ms: 10 }, { name: "launch", ms: 0 }] });
  ok(both.ok && !both.stripped, "code + naam");
  if (both.ok) eq(both.value.milestones, [{ code: "ready", name: "servers_loaded", ms: 10 }, { name: "launch", ms: 0 }]);
});

Deno.test("schema 3: grenzen (updates 5 x 5 fasen, stack 30 regels) en opsommingen", () => {
  const phase = (code: string, i: number) => ({ code, ms: i, memMB: i });
  const r = cleanDiagnostics({
    schema: 3, kind: "app", app: { platform: "android", lang: "Nederlands" },
    start: { longestHang: { ms: -1, task: "Catalogus sorteren!", milestone: "ready", foreground: "ja", stack: Array.from({ length: 80 }, (_, i) => `${i} Bingr f()`) } },
    milestones: [{ code: "Klaar", ms: 1 }, { code: "ready", ms: 2 }, { code: "a.b", ms: 3 }],
    updates: [
      { server: "provider.example.com", phases: [phase("fetch", 1)] },
      { server: "s1", result: "boom", phases: [phase("fetch", 1), phase("download", 2), phase("parse", 3), phase("index", 4), phase("apply", 5), phase("save", 6), phase("save", 7)], totalMs: 99_999_999 },
      ...Array.from({ length: 10 }, (_, i) => ({ server: `s${i + 2}`, result: "cancelled", peakMB: 200_000 })),
    ],
    fetch: [{ server: "s1", kind: "movie", status: "ok", delivered: -4, visible: "12", hidden: { categories: 3, kids: "x", junk: 1 } }],
  });
  if (!r.ok) throw new Error(r.error);
  ok(r.stripped, "stripped");
  eq(r.value.app, { platform: "android" }, "lang weg");
  eq(r.value.start.longestHang.stack.length, 30, "stack max. 30");
  eq([r.value.start.longestHang.task, r.value.start.longestHang.milestone, r.value.start.longestHang.ms, r.value.start.longestHang.foreground], [undefined, "ready", undefined, undefined]);
  eq(r.value.milestones, [{ code: "ready", ms: 2 }]);
  eq(r.value.updates.length, 5, "max. 5 keer bijwerken");
  eq(r.value.updates[0].server, "s1");
  eq(r.value.updates[0].phases.map((p: { code: string }) => p.code), ["fetch", "parse", "index", "apply", "save"], "max. 5 fasen, onbekend weg");
  eq([r.value.updates[0].result, r.value.updates[0].totalMs, r.value.updates[1].peakMB], [undefined, undefined, undefined]);
  eq(r.value.fetch[0], { server: "s1", kind: "movie", status: "ok", visible: 12, hidden: { categories: 3 } });
});

Deno.test("schema 3: geen adressen in de stack van de langste hang; te groot blijft begrensd", () => {
  const r = cleanDiagnostics({ ...EXAMPLE3, start: { ...EXAMPLE3.start, longestHang: { ...EXAMPLE3.start.longestHang,
    stack: ["0 Bingr XtreamClient.get(http://provider.example:8080/get.php?username=leon&password=geheim) + 4", "1 /Users/leon/Bingr/Store.swift:9"] } } });
  if (!r.ok) throw new Error(r.error);
  eq(r.value.start.longestHang.stack, ["0 Bingr XtreamClient.get([url]) + 4", "1 …/Store.swift:9"]);
  const long = (i: number) => `${i} Bingr ${"Frame".repeat(38)}`;
  const big = cleanDiagnostics({ ...EXAMPLE3, crash: { type: "X", stack: Array.from({ length: 50 }, (_, i) => long(i)) },
    start: { ...EXAMPLE3.start, longestHang: { ...EXAMPLE3.start.longestHang, stack: Array.from({ length: 30 }, (_, i) => long(i)) },
      previous: { ...EXAMPLE3.start.previous, stack: Array.from({ length: 30 }, (_, i) => long(i)) } },
    updates: Array.from({ length: 5 }, (_, i) => ({ ...EXAMPLE3.updates[0], server: `s${i + 1}` })),
    milestones: Array.from({ length: 40 }, (_, i) => ({ code: `stap_${i}`, ms: i })) });
  if (!big.ok) throw new Error(big.error);
  ok(JSON.stringify(big.value).length <= DIAG_MAX_OUT, "binnen de grens");
  ok(big.value.start.longestHang.ms === 5500 && big.value.updates.length >= 1, "kern blijft");
});

Deno.test("schema 3: haperingen tijdens het afspelen (playback.stalls, max. 20)", () => {
  const pb = { stalls: [{ atMs: 125000, ms: 2300, engine: "vlc", format: "ts" }, { atMs: 300000, ms: 800 }] };
  const r = cleanDiagnostics({ ...EXAMPLE3, playback: pb });
  if (!r.ok) throw new Error(r.error);
  eq(r.value.playback, pb); eq(r.stripped, false);
  const bad = cleanDiagnostics({ ...EXAMPLE3, playback: { extra: 1, stalls: [
    { atMs: -1, ms: 10 }, { atMs: 5, ms: 99_999_999 }, { atMs: 5, ms: 10, engine: "http://p.example/live.ts", format: "hls", title: "Film" },
    ...Array.from({ length: 40 }, (_, i) => ({ atMs: i * 1000, ms: 100 })),
  ] } });
  if (!bad.ok) throw new Error(bad.error);
  ok(bad.stripped, "stripped");
  eq(bad.value.playback.stalls.length, 20, "max. 20");
  eq(bad.value.playback.stalls[0], { atMs: 5, ms: 10, format: "hls" });
  const v2 = cleanDiagnostics({ ...EXAMPLE2, playback: pb });
  ok(v2.ok && !v2.value.playback, "alleen schema 3");
  const none = cleanDiagnostics({ ...EXAMPLE3, playback: { stalls: [] } });
  ok(none.ok && !none.value.playback, "leeg weg");
});
