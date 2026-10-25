// deno test --allow-net=127.0.0.1 supabase/functions/web-proxy/pinned_test.ts
// Security M2: verbinding naar een vast IP (hier 127.0.0.1) met de echte Host-header; Content-Length, chunked, gzip,
// doorverwijzing (niet gevolgd), 204, afbreken.
import { pinnedFetch } from "./pinned.ts";

function ok(v: unknown, msg: string) { if (!v) throw new Error(`niet waar: ${msg}`); }

async function withServer(fn: (port: number) => Promise<void>) {
  const ac = new AbortController();
  const srv = Deno.serve({ hostname: "127.0.0.1", port: 0, signal: ac.signal, onListen() {} }, async (req) => {
    const u = new URL(req.url);
    if (u.pathname === "/len") return new Response("hallo wereld", { headers: { "content-type": "text/plain", "x-host": req.headers.get("host") ?? "" } });
    if (u.pathname === "/chunked") {
      const body = new ReadableStream({ start(c) { for (let i = 0; i < 50; i++) c.enqueue(new TextEncoder().encode(`regel ${i}\n`)); c.close(); } });
      return new Response(body, { headers: { "content-type": "application/vnd.apple.mpegurl" } });
    }
    if (u.pathname === "/gzip") {
      const gz = new Response(new Blob(["gezipt ".repeat(100)]).stream().pipeThrough(new CompressionStream("gzip")));
      return new Response(await gz.arrayBuffer(), { headers: { "content-encoding": "gzip", "content-type": "application/json" } });
    }
    if (u.pathname === "/redir") return new Response(null, { status: 302, headers: { location: "/len" } });
    if (u.pathname === "/empty") return new Response(null, { status: 204 });
    if (u.pathname === "/big") return new Response(new Uint8Array(3 * 1024 * 1024).fill(7), { headers: { "content-type": "video/mp2t" } });
    if (u.pathname === "/range") return new Response("abc", { status: 206, headers: { "content-range": "bytes 0-2/10", "x-range": req.headers.get("range") ?? "" } });
    return new Response("nee", { status: 404 });
  });
  try { await fn((srv.addr as Deno.NetAddr).port); } finally { ac.abort(); await srv.finished; }
}
const sig = () => new AbortController().signal;

Deno.test("pinned: Content-Length, Host-header van de echte naam", () => withServer(async (port) => {
  const r = await pinnedFetch(new URL(`http://iptv.example:${port}/len`), { ip: "127.0.0.1", headers: { "User-Agent": "Bingr v1.0.0" }, signal: sig() });
  ok(r.status === 200, "status"); ok((await r.text()) === "hallo wereld", "body");
  ok(r.headers.get("x-host") === `iptv.example:${port}`, "Host = echte naam, verbinding = vast IP");
}));
Deno.test("pinned: chunked, gzip, 302 niet volgen, 204, Range", () => withServer(async (port) => {
  const base = `http://iptv.example:${port}`, o = { ip: "127.0.0.1", headers: {}, signal: sig() };
  const c = await pinnedFetch(new URL(base + "/chunked"), o);
  const t = await c.text();
  ok(t.split("\n").length === 51 && t.startsWith("regel 0"), "chunked");
  const g = await pinnedFetch(new URL(base + "/gzip"), o);
  ok((await g.text()) === "gezipt ".repeat(100) && !g.headers.get("content-encoding"), "gzip uitgepakt");
  const rd = await pinnedFetch(new URL(base + "/redir"), o);
  ok(rd.status === 302 && rd.headers.get("location") === "/len", "doorverwijzing terug, niet gevolgd"); await rd.body?.cancel();
  const e = await pinnedFetch(new URL(base + "/empty"), o);
  ok(e.status === 204 && e.body === null, "204");
  const rg = await pinnedFetch(new URL(base + "/range"), { ...o, headers: { Range: "bytes=0-2" } });
  ok(rg.status === 206 && rg.headers.get("x-range") === "bytes=0-2" && (await rg.text()) === "abc", "range");
  const b = await pinnedFetch(new URL(base + "/big"), o);
  ok((await b.arrayBuffer()).byteLength === 3 * 1024 * 1024, "3 MB");
}));
Deno.test("pinned: geen kopregel-injectie, afbreken", () => withServer(async (port) => {
  const r = await pinnedFetch(new URL(`http://iptv.example:${port}/len`), { ip: "127.0.0.1", headers: { "X-A": "x\r\nHost: evil" }, signal: sig() });
  ok(r.headers.get("x-host") === `iptv.example:${port}`, "CRLF uit waarde gehaald"); await r.body?.cancel();
  const ac = new AbortController(); ac.abort();
  let threw = false;
  try { await pinnedFetch(new URL(`http://iptv.example:${port}/len`), { ip: "127.0.0.1", headers: {}, signal: ac.signal }); } catch { threw = true; }
  ok(threw, "afgebroken");
}));

// ---- spoedfix 25-10-2026 (http_502 in de webspeler): foutsoort per stap, tolerante kop, doorstromen zonder bufferen ----
import { PinnedError, pinnedKind } from "./pinned.ts";

/** Ruwe TCP-server: per verbinding `handle` (leest de aanvraag, schrijft wat de test wil). */
async function withRaw(handle: (c: Deno.Conn) => Promise<void>, fn: (port: number) => Promise<void>) {
  const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (l.addr as Deno.NetAddr).port;
  const conns: Deno.Conn[] = [];
  const loop = (async () => {
    for await (const c of l) {
      conns.push(c);
      (async () => {
        const buf = new Uint8Array(8192); await c.read(buf).catch(() => null); // aanvraag (past in één read)
        await handle(c).catch(() => {});
      })();
    }
  })().catch(() => {});
  try { await fn(port); } finally { l.close(); for (const c of conns) { try { c.close(); } catch { /* dicht */ } } await loop; }
}
const te = new TextEncoder();
async function kindOf(p: Promise<unknown>): Promise<string> {
  try { const r = await p as Response; await r.body?.cancel(); return "ok"; } catch (e) { return e instanceof PinnedError ? e.kind : "other:" + (e as Error)?.name; }
}

Deno.test("pinned: kop met alleen LF, zonder reden, kleine letters en ICY", async () => {
  for (const [head, want] of [
    ["HTTP/1.1 200 OK\nContent-Type: application/json\nContent-Length: 2\n\n{}", 200],
    ["HTTP/1.0 200\r\nContent-Length: 2\r\n\r\n{}", 200],
    ["http/1.1 404 Not Found\r\ncontent-length: 2\r\n\r\n{}", 404],
    ["ICY 200 OK\r\nicy-name: radio\r\n\r\nxx", 200],
  ] as const) {
    await withRaw(async (c) => { await c.write(te.encode(head)); c.close(); }, async (port) => {
      const r = await pinnedFetch(new URL(`http://iptv.example:${port}/player_api.php`), { ip: "127.0.0.1", headers: {}, signal: sig() });
      ok(r.status === want, `status ${r.status} voor ${JSON.stringify(head.slice(0, 20))}`);
      ok((await r.text()).length === 2, "body");
    });
  }
});
Deno.test("pinned: chunked met alleen LF", () => withRaw(async (c) => {
  await c.write(te.encode("HTTP/1.1 200 OK\nTransfer-Encoding: chunked\n\n5\nhallo\n0\n\n")); c.close();
}, async (port) => {
  const r = await pinnedFetch(new URL(`http://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() });
  ok((await r.text()) === "hallo", "chunked LF");
}));
Deno.test("pinned: foutsoorten (geweigerd, geen antwoord, onzin, status buiten bereik, TLS naar een gewone server)", async () => {
  // geweigerd: poort die net dicht ging
  const l = Deno.listen({ hostname: "127.0.0.1", port: 0 }); const dead = (l.addr as Deno.NetAddr).port; l.close();
  ok(await kindOf(pinnedFetch(new URL(`http://iptv.example:${dead}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() })) === "connect_refused", "connect_refused");
  await withRaw(async (c) => { c.close(); }, async (port) => {
    ok(await kindOf(pinnedFetch(new URL(`http://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() })) === "no_response", "no_response");
  });
  await withRaw(async (c) => { await c.write(te.encode("SSH-2.0-OpenSSH\r\n\r\n")); c.close(); }, async (port) => {
    ok(await kindOf(pinnedFetch(new URL(`http://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() })) === "bad_response", "bad_response");
  });
  await withRaw(async (c) => { await c.write(te.encode("HTTP/1.1 999 Raar\r\n\r\n")); c.close(); }, async (port) => {
    ok(await kindOf(pinnedFetch(new URL(`http://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() })) === "bad_response", "status 999");
  });
  await withRaw(async (c) => { await c.write(te.encode("HTTP/1.1 400 Bad Request\r\n\r\n")); c.close(); }, async (port) => {
    ok(await kindOf(pinnedFetch(new URL(`https://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig() })) === "tls_failed", "tls_failed");
  });
  // verbinden duurt te lang: time-out van 1 ms op een server die niets doet (verbinden lukt wel; dan TLS-time-out)
  await withRaw(async () => { await new Promise((r) => setTimeout(r, 300)); }, async (port) => {
    const k = await kindOf(pinnedFetch(new URL(`https://iptv.example:${port}/x`), { ip: "127.0.0.1", headers: {}, signal: sig(), connectTimeoutMs: 50 }));
    ok(k === "tls_timeout", "tls_timeout: " + k);
  });
});
Deno.test("pinned: pinnedKind (pure functie)", () => {
  ok(pinnedKind(new PinnedError("connect_timeout"), "connect") === "connect_timeout", "eigen fout");
  ok(pinnedKind(Object.assign(new Error("x"), { name: "ConnectionRefused" }), "connect") === "connect_refused", "refused");
  ok(pinnedKind(Object.assign(new Error("x"), { name: "ConnectionReset" }), "connect") === "connect_reset", "reset");
  ok(pinnedKind(new Error("invalid peer certificate: UnknownIssuer"), "read") === "tls_failed", "certificaat");
  ok(pinnedKind(new Error("Network is unreachable"), "connect") === "connect_failed", "onbereikbaar");
  ok(pinnedKind(new Error("connection timed out"), "connect") === "connect_timeout", "OS-time-out");
});
Deno.test("pinned: groot antwoord stroomt door zonder te bufferen", () => {
  // de server stuurt 1 MB, wacht tot de client dat gelezen heeft, en stuurt pas dan de rest (samen 40 MB)
  let firstRead!: () => void;
  const gotFirst = new Promise<void>((r) => { firstRead = r; });
  const MB = 1024 * 1024, total = 40 * MB;
  return withRaw(async (c) => {
    await c.write(te.encode(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${total}\r\n\r\n`));
    const block = new Uint8Array(MB).fill(32);
    await c.write(block);
    await gotFirst; // zonder doorstromen komt de client hier nooit (deadlock -> time-out van de test)
    for (let i = 1; i < 40; i++) { let o = 0; while (o < block.length) o += await c.write(block.subarray(o)); }
    c.close();
  }, async (port) => {
    const r = await pinnedFetch(new URL(`http://iptv.example:${port}/player_api.php?action=get_vod_streams`), { ip: "127.0.0.1", headers: {}, signal: sig() });
    const reader = r.body!.getReader();
    let n = 0, signalled = false;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.byteLength;
      if (!signalled && n >= MB) { signalled = true; firstRead(); }
    }
    ok(n === total, `alles binnen (${n})`);
  });
});
