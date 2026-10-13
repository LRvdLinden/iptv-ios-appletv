// Tests voor de statuscontroles (geen database of internet nodig):
//   deno test --allow-net --allow-env --allow-read supabase/functions/status/status_test.ts
// Optioneel een echte TLS-handshake tegen een lokale server: TLS_TEST_CERT=<pem> TLS_TEST_KEY=<pem> (CN mag alles zijn).
import { addDays, daySeries, evaluate, isDue, type MonitorState, overall, uptimePct, windowUptime } from "./logic.ts";
import { certNotAfter, checkGhAsset, checkGhWorkflow, checkHttp, checkTls, type Ctx, tlsResult } from "./checks.ts";

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

Deno.test("GitHub: release-bestanden via API en via de webpagina bij de limiet", async () => {
  const calls: string[] = [];
  const api: Handler = (u) => {
    calls.push(u);
    if (u.includes("api.github.com")) {
      return Response.json({ tag_name: "v1", assets: [{ browser_download_url: "https://github.com/o/r/releases/download/v1/Bingr-1.apk" }] });
    }
    return new Response("", { status: 206 });
  };
  const ctx = ctxWith(api);
  eq((await checkGhAsset("o/r|.apk", ctx)).ok, true);
  const wgt = await checkGhAsset("o/r|.wgt", ctx);
  eq([wgt.ok, wgt.error], [false, "geen .wgt-bestand in release v1"]);
  eq(calls.filter((c) => c.includes("api.github.com")).length, 1); // release maar één keer opgehaald per run

  const html: Handler = (u) => {
    if (u.includes("api.github.com")) return new Response("{}", { status: 403, headers: { "x-ratelimit-remaining": "0" } });
    if (u.endsWith("/releases/latest")) return new Response(null, { status: 302, headers: { location: "https://github.com/o/r/releases/tag/v2" } });
    if (u.includes("expanded_assets/v2")) return new Response('<a href="/o/r/releases/download/v2/B.apk">x</a><a href="/o/r/releases/download/v2/B.wgt">y</a>');
    return new Response("", { status: u.endsWith(".wgt") ? 404 : 200 });
  };
  const c2 = ctxWith(html);
  eq((await checkGhAsset("o/r|.apk", c2)).ok, true);
  const w2 = await checkGhAsset("o/r|.wgt", c2);
  eq([w2.ok, w2.code], [false, 404]);
});

Deno.test("GitHub: Apple-build", async () => {
  const run = (concl: string) => ctxWith(() => Response.json({ workflow_runs: [{ conclusion: concl, run_number: 9, head_sha: "abcdef123" }] }));
  eq((await checkGhWorkflow("o/r|build.yml|main", run("success"))).ok, true);
  eq((await checkGhWorkflow("o/r|build.yml|main", run("failure"))).error, "laatste build: failure");
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
