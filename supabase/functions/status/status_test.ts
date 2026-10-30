// Tests voor de statuscontroles (geen database of internet nodig):
//   deno test --allow-net --allow-env --allow-read supabase/functions/status/status_test.ts
// Optioneel een echte TLS-handshake tegen een lokale server: TLS_TEST_CERT=<pem> TLS_TEST_KEY=<pem> (CN mag alles zijn).
import { addDays, daySeries, evaluate, isDue, type MonitorState, overall, uptimePct, windowUptime } from "./logic.ts";
import { certNotAfter, checkBuild, checkGhWorkflow, runCheck, signBuildToken, checkHttp, checkTls, type Ctx, tlsResult } from "./checks.ts";

function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("storing opent na 2 fouten en sluit na 2 goede controles", () => {
  let s: MonitorState = { fail_streak: 0, ok_streak: 0, open: false };
  const seq: [boolean, string, string, boolean, boolean][] = [
    // ok?, checkState, current, open, close
    [true, "up", "up", false, false],
    [false, "degraded", "degraded", false, false], // losse fout = verminderd
    [true, "up", "up", false, false], // hersteld, geen storing
    [false, "degraded", "degraded", false, false],
    [false, "down", "down", true, false], // tweede fout op rij: storing open
    [false, "down", "down", false, false], // blijft open, niet opnieuw openen
    [true, "up", "down", false, false], // eerste goede: storing nog niet dicht
    [false, "down", "down", false, false], // terugval: teller opnieuw
    [true, "up", "down", false, false],
    [true, "up", "up", false, true], // tweede goede op rij: dicht
    [true, "up", "up", false, false],
  ];
  seq.forEach(([ok, cs, cur, op, cl], i) => {
    const ev = evaluate(s, { ok });
    eq([ev.checkState, ev.current, ev.open, ev.close], [cs, cur, op, cl], `stap ${i}`);
    s = { fail_streak: ev.fail_streak, ok_streak: ev.ok_streak, open: (s.open || ev.open) && !ev.close };
  });
  eq(evaluate({ fail_streak: 0, ok_streak: 3, open: false }, { ok: true, degraded: true }).checkState, "degraded");
});

Deno.test("uptime-berekening", () => {
  eq(uptimePct(0, 0), null);
  eq(uptimePct(288, 0), 100);
  eq(uptimePct(288, 1), 99.65); // 287/288 = 99.6527 -> naar beneden
  eq(uptimePct(100000, 1), 99.99); // nooit 100 als er iets uit was
  eq(uptimePct(4, 4), 0);
  eq(uptimePct(4, 9), 0);
  const rows = [
    { m: "a", d: "2026-10-13", n: 100, g: 0, x: 0 },
    { m: "a", d: "2026-10-10", n: 100, g: 5, x: 10 },
    { m: "a", d: "2026-09-01", n: 100, g: 0, x: 50 },
  ];
  eq(windowUptime(rows, "2026-10-13", 1), 100);
  eq(windowUptime(rows, "2026-10-13", 7), 95); // 190/200
  eq(windowUptime(rows, "2026-10-13", 90), 80); // 240/300
  eq(windowUptime([], "2026-10-13", 30), null);
});

Deno.test("90-dagenreeks", () => {
  eq(addDays("2026-03-01", -1), "2026-02-28");
  eq(addDays("2026-10-25", 1), "2026-10-26"); // overgang wintertijd speelt geen rol (UTC-datums)
  const rows = [
    { m: "a", d: "2026-10-13", n: 10, g: 0, x: 0 },
    { m: "a", d: "2026-10-12", n: 10, g: 2, x: 0 },
    { m: "a", d: "2026-10-11T00:00:00", n: 10, g: 0, x: 1 },
    { m: "a", d: "2026-07-16", n: 10, g: 0, x: 0 }, // dag 90 (oudste)
    { m: "a", d: "2026-07-15", n: 10, g: 0, x: 10 }, // buiten de reeks
  ];
  const s = daySeries(rows, "2026-10-13", 90);
  eq(s.length, 90);
  eq(s[0], { d: "2026-07-16", u: 100, s: "up", n: 10 });
  eq(s[89], { d: "2026-10-13", u: 100, s: "up", n: 10 });
  eq(s[88].s, "degraded");
  eq([s[87].s, s[87].u], ["down", 90]);
  eq(s[50], { d: addDays("2026-07-16", 50), u: null, s: "none", n: 0 });
  eq(daySeries([], "2026-10-13", 30).filter((d) => d.s === "none").length, 30);
});

Deno.test("totaalbeeld en planning", () => {
  eq(overall([{ id: "a", state: "up" }, { id: "b", state: "up" }]).state, "up");
  eq(overall([{ id: "a", state: "degraded" }, { id: "b", state: "up" }]), { state: "degraded", down: [], degraded: ["a"] });
  eq(overall([{ id: "a", state: "degraded" }, { id: "b", state: "down" }]).state, "down");
  const now = Date.parse("2026-10-13T12:00:00Z");
  eq(isDue(null, 5, now), true);
  eq(isDue("2026-10-13T11:55:10Z", 5, now), true); // cron-tik iets vroeger dan precies 5 min
  eq(isDue("2026-10-13T11:58:00Z", 5, now), false);
  eq(isDue("2026-10-13T11:50:00Z", 15, now), false);
  eq(isDue("2026-10-13T11:45:30Z", 15, now), true);
});

// ---- controles met nep-fetch ----
type Handler = (url: string, init?: RequestInit) => Response | Promise<Response>;
const ctxWith = (h: Handler, envs: Record<string, string> = {}): Ctx => ({
  db: null as never, env: (k) => envs[k] ?? "", cache: new Map(),
  fetch: ((input: string | URL | Request, init?: RequestInit) => Promise.resolve(h(String(input), init))) as typeof fetch,
});

Deno.test({ name: "http-controle: status, trefwoord, traag, timeout", sanitizeOps: false, sanitizeResources: false }, async () => {
  eq((await checkHttp("https://x/", "data-build", ctxWith(() => new Response('<span data-build>1</span>')))).ok, true);
  const kw = await checkHttp("https://x/", "data-build", ctxWith(() => new Response("leeg")));
  eq([kw.ok, kw.code], [false, 200]);
  const e = await checkHttp("https://x/", null, ctxWith(() => new Response("", { status: 503 })));
  eq([e.ok, e.code, e.error], [false, 503, "HTTP 503"]);
  const t = await import("./checks.ts").then((m) => m.withTimeout(() => new Promise((r) => setTimeout(r, 300)), 50).then(() => "ok", (x) => x.message));
  eq(t, "timeout");
});

Deno.test("Downloads: builds in de afgesloten opslag (dl.php)", async () => {
  const KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; // testwaarde
  const calls: { path: string; method: string }[] = [];
  const h: Handler = (u, init) => {
    const t = new URL(u).searchParams.get("t") ?? "";
    const p = JSON.parse(atob(t.split(".")[0].replace(/-/g, "+").replace(/_/g, "/")));
    calls.push({ path: p.f, method: init?.method ?? "GET" });
    if (p.f === "manifest.json") {
      return Response.json({ platforms: {
        android: { build: 106, date: "2026-10-16", file: "B.apk", path: "android/B.apk", size: 10 },
        windows: { build: 106, file: "B.exe", path: "windows/B.exe", size: 10 },
        apple: { build: 106, file: "B.zip", path: "apple/B.zip", size: 10 },
      } });
    }
    if (p.f === "windows/B.exe") return new Response(null, { status: 404 });
    if (p.f === "apple/B.zip") return new Response(null, { status: 200, headers: { "content-length": "3" } });
    return new Response(null, { status: 200, headers: { "content-length": "10" } });
  };
  const ctx = ctxWith(h, { BINGR_BUILDS_KEY: KEY });
  const apk = await checkBuild("android", ctx);
  eq([apk.ok, apk.detail], [true, "build 106 (2026-10-16)"]);
  eq(calls[1], { path: "android/B.apk", method: "HEAD" });
  const win = await checkBuild("windows", ctx);
  eq([win.ok, win.code], [false, 404]);
  // Samsung TV en LG-tv vervallen: geen platform meer
  eq((await checkBuild("tizen", ctx)).ok, false);
  eq((await checkBuild("webos", ctx)).ok, false);
  eq((await checkBuild("apple", ctx)).error, "bestand is onvolledig");
  eq((await checkBuild("beheer", ctx)).error, "geen build in de opslag");
  eq(calls.filter((c) => c.path === "manifest.json").length, 1); // manifest maar één keer per run
  eq((await checkBuild("x", ctx)).ok, false);
  eq((await checkBuild("android", ctxWith(h))).error, "opslag niet ingericht (BINGR_BUILDS_KEY ontbreekt)");
  // oude monitor (gh_asset) gaat naar dezelfde controle
  const old = await runCheck({ kind: "gh_asset", target: "LRvdLinden/bingr-beheer|.apk" } as never, ctxWith(h, { BINGR_BUILDS_KEY: KEY }));
  eq(old.ok, true);
});

Deno.test("Downloads: token gelijk aan dl.php (HMAC-SHA256, base64url)", async () => {
  const tok = await signBuildToken("k".repeat(64), "manifest.json", 60, 1000);
  const [p, s] = tok.split(".");
  eq(JSON.parse(atob(p)), { f: "manifest.json", e: 1060 });
  eq(/^[A-Za-z0-9_-]{43}$/.test(s), true);
});

Deno.test("Pushdiensten: elk HTTP-antwoord = bereikbaar; geen verbinding = fout; functie push geeft een VAPID-sleutel", async () => {
  const seen: { url: string; auth: string | null }[] = [];
  const reach = (status: number) => ctxWith((u, init) => {
    seen.push({ url: u, auth: new Headers(init?.headers).get("authorization") });
    return new Response("{}", { status });
  });
  const a = await runCheck({ kind: "reach", target: "https://api.push.apple.com/" } as never, reach(404));
  eq([a.ok, a.code], [true, 404]);
  eq((await runCheck({ kind: "reach", target: "https://fcm.googleapis.com/" } as never, reach(200))).ok, true);
  eq(seen.every((x) => x.auth === null), true); // geen sleutel of token in de controle
  const down = await runCheck({ kind: "reach", target: "https://api.push.apple.com/" } as never, ctxWith(() => { throw new TypeError("dns error"); }));
  eq(down.ok, false);
  const key = "B" + "A".repeat(86);
  eq((await runCheck({ kind: "push", target: "" } as never, ctxWith(() => Response.json({ key })))).ok, true);
  eq((await runCheck({ kind: "push", target: "" } as never, ctxWith(() => Response.json({ error: "not_configured" }, { status: 503 })))).ok, false);
  eq((await runCheck({ kind: "push", target: "" } as never, ctxWith(() => Response.json({ key: "kort" })))).error, "geen VAPID-sleutel");
});

// build 147: alleen de echte build-job(s) tellen; 1 mislukte run = verminderd, storing na 2 op rij of > 2 uur
const H = 3600_000;
const iso = (msAgo: number) => new Date(Date.now() - msAgo).toISOString();
type FakeRun = { id: number; conclusion: string; jobs: [string, string][]; ago?: number };
function ghCtx(runs: FakeRun[], opts: { limitJobs?: boolean } = {}) {
  const calls: string[] = [];
  const ctx = ctxWith((u) => {
    calls.push(u);
    const m = u.match(/\/actions\/runs\/(\d+)\/jobs/);
    if (m) {
      if (opts.limitJobs) return new Response("", { status: 403, headers: { "x-ratelimit-remaining": "0" } });
      const r = runs.find((x) => x.id === Number(m[1]))!;
      return Response.json({ jobs: r.jobs.map(([name, conclusion]) => ({ name, status: "completed", conclusion })) });
    }
    return Response.json({ workflow_runs: runs.map((r) => ({ id: r.id, run_number: r.id, head_sha: `abc${r.id}def`, status: "completed",
      conclusion: r.conclusion, updated_at: iso(r.ago ?? 10 * 60_000) })) });
  });
  return { ctx, calls };
}
const APPLE = "o/r|build.yml|main|build";

Deno.test("GitHub-build: alleen de echte build telt (24 okt: sdk27 rood, build goed = up)", async () => {
  const { ctx } = ghCtx([{ id: 9, conclusion: "failure", jobs: [["build", "success"], ["sdk27", "failure"]] }]);
  const r = await checkGhWorkflow(APPLE, ctx);
  eq([r.ok, r.degraded ?? false, r.skip ?? false], [true, false, false]);
  eq(r.detail, "run 9 (abc9def)");
  // Android: build- en aanleverjob apk; de rooktest telt niet
  const a = ghCtx([{ id: 5, conclusion: "failure", jobs: [["apk", "success"], ["emulator", "failure"]] }]);
  eq((await checkGhWorkflow("o/a|build.yml|main|apk", a.ctx)).ok, true);
  // matrix-job "build (ios)" telt bij "build"
  const mx = ghCtx([{ id: 3, conclusion: "failure", jobs: [["build (ios)", "success"], ["build (tvos)", "failure"]] }]);
  eq((await checkGhWorkflow(APPLE, mx.ctx)).degraded, true);
});

Deno.test("GitHub-build: één mislukte run = verminderd, twee op rij = storing", async () => {
  const one = ghCtx([{ id: 11, conclusion: "failure", jobs: [["build", "failure"]] }, { id: 10, conclusion: "success", jobs: [["build", "success"]] }]);
  const r1 = await checkGhWorkflow(APPLE, one.ctx);
  eq([r1.ok, r1.degraded, r1.confirmed ?? false], [true, true, false]);
  const two = ghCtx([{ id: 12, conclusion: "failure", jobs: [["build", "failure"]] }, { id: 11, conclusion: "failure", jobs: [["build", "failure"]] }]);
  const r2 = await checkGhWorkflow(APPLE, two.ctx);
  eq([r2.ok, r2.confirmed, r2.error], [false, true, "build mislukt (2 runs op rij)"]);
  // test-job rood in de vorige run telt niet: dan is het weer één mislukte run
  const mixed = ghCtx([{ id: 12, conclusion: "failure", jobs: [["build", "failure"]] }, { id: 11, conclusion: "failure", jobs: [["build", "success"], ["sdk27", "failure"]] }]);
  eq((await checkGhWorkflow(APPLE, mixed.ctx)).degraded, true);
});

Deno.test("GitHub-build: mislukt en al langer dan 2 uur de laatste = storing", async () => {
  const { ctx } = ghCtx([{ id: 20, conclusion: "failure", jobs: [["build", "failure"]], ago: 2 * H + 60_000 }, { id: 19, conclusion: "success", jobs: [["build", "success"]] }]);
  const r = await checkGhWorkflow(APPLE, ctx);
  eq([r.ok, r.confirmed, r.error], [false, true, "build mislukt (al langer dan 2 uur de laatste)"]);
});

Deno.test("GitHub-build: geannuleerde runs en overgeslagen jobs tellen niet; de laatste afgeronde run geldt", async () => {
  const { ctx, calls } = ghCtx([
    { id: 31, conclusion: "cancelled", jobs: [["build", "cancelled"]] },
    { id: 30, conclusion: "success", jobs: [["build", "skipped"]] }, // build overgeslagen: telt niet
    { id: 29, conclusion: "failure", jobs: [["build", "failure"]] },
    { id: 28, conclusion: "success", jobs: [["build", "success"]] },
  ]);
  const r = await checkGhWorkflow(APPLE, ctx);
  eq([r.ok, r.degraded], [true, true], "run 29 is de laatste die telt: 1 mislukt");
  ok(!calls.some((u) => u.includes("/runs/31/")), "geannuleerde run: geen jobs opgevraagd");
  const none = ghCtx([{ id: 1, conclusion: "cancelled", jobs: [] }]);
  eq((await checkGhWorkflow(APPLE, none.ctx)).skip, true, "alleen geannuleerd: telt niet");
});

Deno.test("GitHub-build: zonder jobnamen tellen alle jobs behalve tests; geen workflow = telt niet; limiet", async () => {
  const { ctx } = ghCtx([{ id: 7, conclusion: "failure", jobs: [["build", "success"], ["unit tests", "failure"], ["smoke", "failure"]] }]);
  eq((await checkGhWorkflow("o/r|build.yml|main", ctx)).ok, true);
  // onbekende jobnaam opgegeven -> terugval op alle niet-test-jobs
  const w = ghCtx([{ id: 2, conclusion: "success", jobs: [["ipk", "success"]] }]);
  eq((await checkGhWorkflow("o/w|build.yml|main|build", w.ctx)).ok, true);
  const missing = ctxWith(() => new Response("{}", { status: 404 }));
  const m = await checkGhWorkflow("o/nieuw|build.yml|main|build", missing);
  eq([m.ok, m.skip, m.error], [true, true, "workflow nog niet aanwezig"]);
  const lim = ghCtx([{ id: 4, conclusion: "failure", jobs: [] }], { limitJobs: true });
  eq((await checkGhWorkflow(APPLE, lim.ctx)).skip, true, "limiet bij de jobs: overslaan");
  const badge = (txt: string) => ctxWith((u) => u.includes("api.github.com")
    ? new Response("", { status: 429 }) : new Response(`<svg><text>Build</text><text>${txt}</text></svg>`));
  eq((await checkGhWorkflow("o/r|build.yml", badge("passing"))).ok, true);
  const bf = await checkGhWorkflow("o/r|build.yml", badge("failing"));
  eq([bf.ok, bf.degraded], [true, true], "badge kent geen jobs: hoogstens verminderd");
  eq((await checkGhWorkflow("o/r|build.yml", badge("no status"))).skip, true);
});

Deno.test("GitHub-build: verloop van de monitor (geen storing bij één rode build, oude storing sluit vanzelf)", () => {
  // oude logica liet een storing open staan; nu geeft dezelfde run "verminderd" (ok + degraded) -> na 2 controles dicht
  let st: MonitorState = { fail_streak: 3, ok_streak: 0, open: true };
  const deg = { ok: true, degraded: true };
  let ev = evaluate(st, deg);
  eq([ev.current, ev.close], ["down", false]);
  st = { fail_streak: ev.fail_streak, ok_streak: ev.ok_streak, open: true };
  ev = evaluate(st, deg);
  eq([ev.checkState, ev.current, ev.close], ["degraded", "degraded", true], "tweede controle: storing dicht, verminderd");
  // een bevestigde storing (2 runs op rij) opent meteen
  const c = evaluate({ fail_streak: 0, ok_streak: 5, open: false }, { ok: false, confirmed: true });
  eq([c.open, c.current], [true, "down"]);
  // één rode build blijft verminderd, ook bij elke volgende controle van dezelfde run
  let s2: MonitorState = { fail_streak: 0, ok_streak: 0, open: false };
  for (let i = 0; i < 5; i++) { const e = evaluate(s2, deg); eq([e.current, e.open], ["degraded", false]); s2 = { ...s2, ok_streak: e.ok_streak }; }
});

// openbaar testcertificaat (zelfondertekend, CN=test.bingr, geldig tot 12 nov 2026); bevat geen sleutel
const TEST_CERT = `-----BEGIN CERTIFICATE-----
MIIBfzCCASWgAwIBAgIUfjORIMf42KqGZOJ11PNrjpOVIkQwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKdGVzdC5iaW5ncjAeFw0yNjEwMTMxMzEwMTFaFw0yNjExMTIx
MzEwMTFaMBUxEzARBgNVBAMMCnRlc3QuYmluZ3IwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAAQORD8cJMiS/KSB9Xo1aLK1TWxKbgUnllVEEblh1J3sadQ3hdC3ShAk
fjmxD+kMuXWbbqG4p7UIfUg07gkkJgiqo1MwUTAdBgNVHQ4EFgQUtsjL5cRcX6wj
2iOln0vkEjKebOAwHwYDVR0jBBgwFoAUtsjL5cRcX6wj2iOln0vkEjKebOAwDwYD
VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAiGFTPHFaLgKljewQJsdt
fZXTaQQqFykNk3xEmpDktPgCIDOH0nRnowU+zdQLG8xnods0yMPTQ/GKoFol4cXj
HVrh
-----END CERTIFICATE-----`;

Deno.test("TLS: notAfter uit het certificaat en de waarschuwing onder 14 dagen", () => {
  const der = Uint8Array.from(atob(TEST_CERT.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const na = certNotAfter(der);
  eq(na.toISOString().slice(0, 10), "2026-11-12");
  const r30 = tlsResult(na, 5, Date.parse("2026-10-13T12:00:00Z"));
  eq([r30.ok, r30.degraded], [true, false]);
  const r10 = tlsResult(na, 5, Date.parse("2026-11-01T12:00:00Z"));
  eq([r10.ok, r10.degraded], [true, true]);
  eq(tlsResult(na, 5, Date.parse("2026-12-01T00:00:00Z")).ok, false);
});

Deno.test({
  name: "TLS: echte handshake met een lokale TLS 1.2-server",
  ignore: !Deno.env.get("TLS_TEST_CERT"),
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const cert = Deno.readTextFileSync(Deno.env.get("TLS_TEST_CERT")!), key = Deno.readTextFileSync(Deno.env.get("TLS_TEST_KEY")!);
    const l = Deno.listenTls({ hostname: "127.0.0.1", port: 0, cert, key });
    const port = (l.addr as Deno.NetAddr).port;
    const srv = (async () => { for await (const c of l) { c.handshake().catch(() => {}).finally(() => setTimeout(() => { try { c.close(); } catch { /* */ } }, 200)); } })();
    const r = await checkTls("127.0.0.1", ctxWith(() => new Response()), port);
    l.close(); await srv.catch(() => {});
    if (!r.ok || !/dagen geldig/.test(r.detail ?? "")) throw new Error(JSON.stringify(r));
    console.log("   ", r.detail, `${r.ms} ms`);
  },
});

Deno.test("Openbare download: alleen HEAD (telt niet als download), 200 = up", async () => {
  const seen: string[] = [];
  const head = (status: number) => ctxWith((_u, init) => { seen.push(String(init?.method ?? "GET")); return new Response(null, { status, headers: { "content-length": String(8 * 1048576) } }); });
  const ok = await runCheck({ kind: "head", target: "https://beheer.bingr.online/dl.php?app=windows" } as never, head(200));
  eq([ok.ok, ok.code, ok.detail], [true, 200, "8 MB"]);
  const gone = await runCheck({ kind: "head", target: "https://beheer.bingr.online/dl.php?app=windows" } as never, head(404));
  eq([gone.ok, gone.error], [false, "HTTP 404"]);
  eq(seen, ["HEAD", "HEAD"]);
});
