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
