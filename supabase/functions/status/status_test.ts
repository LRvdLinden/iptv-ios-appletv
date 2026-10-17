// Tests voor de statuscontroles (geen database of internet nodig):
//   deno test --allow-net --allow-env --allow-read supabase/functions/status/status_test.ts
// Optioneel een echte TLS-handshake tegen een lokale server: TLS_TEST_CERT=<pem> TLS_TEST_KEY=<pem> (CN mag alles zijn).
import { addDays, daySeries, evaluate, isDue, type MonitorState, overall, uptimePct, windowUptime } from "./logic.ts";
import { certNotAfter, checkBuild, checkGhWorkflow, runCheck, signBuildToken, checkHttp, checkTls, type Ctx, tlsResult } from "./checks.ts";

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
        tizen: { build: 106, file: "B.wgt", path: "tizen/B.wgt", size: 10 },
        apple: { build: 106, file: "B.zip", path: "apple/B.zip", size: 10 },
      } });
    }
    if (p.f === "tizen/B.wgt") return new Response(null, { status: 404 });
    if (p.f === "apple/B.zip") return new Response(null, { status: 200, headers: { "content-length": "3" } });
    return new Response(null, { status: 200, headers: { "content-length": "10" } });
  };
  const ctx = ctxWith(h, { BINGR_BUILDS_KEY: KEY });
  const apk = await checkBuild("android", ctx);
  eq([apk.ok, apk.detail], [true, "build 106 (2026-10-16)"]);
  eq(calls[1], { path: "android/B.apk", method: "HEAD" });
  const wgt = await checkBuild("tizen", ctx);
  eq([wgt.ok, wgt.code], [false, 404]);
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

Deno.test("GitHub: Apple-build", async () => {
  const run = (concl: string) => ctxWith(() => Response.json({ workflow_runs: [{ conclusion: concl, run_number: 9, head_sha: "abcdef123" }] }));
  eq((await checkGhWorkflow("o/r|build.yml|main", run("success"))).ok, true);
  eq((await checkGhWorkflow("o/r|build.yml|main", run("failure"))).error, "laatste build: failure");
  const mixed = ctxWith(() => Response.json({ workflow_runs: [{ conclusion: "cancelled", run_number: 11 }, { conclusion: "success", run_number: 10 }] }));
  eq((await checkGhWorkflow("o/r|build.yml|main", mixed)).ok, true); // geannuleerd telt niet
  const badge = (txt: string) => ctxWith((u) => u.includes("api.github.com")
    ? new Response("", { status: 429 }) : new Response(`<svg><text>Build</text><text>${txt}</text></svg>`));
  eq((await checkGhWorkflow("o/r|build.yml", badge("passing"))).ok, true);
  eq((await checkGhWorkflow("o/r|build.yml", badge("failing"))).ok, false);
  eq((await checkGhWorkflow("o/r|build.yml", badge("no status"))).skip, true);
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
