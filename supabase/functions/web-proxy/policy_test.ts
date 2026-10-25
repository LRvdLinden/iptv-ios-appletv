// deno test supabase/functions/web-proxy/policy_test.ts
// Security M1/L8: alleen eigen IPTV-servers en de paden die de webspeler gebruikt; antwoorden nooit als pagina.
import { allowFromSources, hostAllowed, mediaLike, overQuota, pathAllowed, portAllowed, quotaSettings, safeContentType, safetyHeaders } from "./policy.ts";

function ok(v: unknown, msg: string) { if (!v) throw new Error(`niet waar: ${msg}`); }
const allow = allowFromSources([
  { serverURL: "http://tv.provider.example:8080", username: "u", password: "p" },
  { m3uURL: "https://lists.example.org/raw/abc123", epgURL: "https://epg.example.net/guide.xml.gz" },
  { serverURL: "https://deleted.example", deleted: true },
]);

Deno.test("hosts: eigen servers en subdomeinen, verwijderde niet", () => {
  ok(hostAllowed("tv.provider.example", allow), "server");
  ok(hostAllowed("cdn2.provider.example", allow), "subdomein");
  ok(hostAllowed("lists.example.org", allow), "m3u-host");
  ok(!hostAllowed("deleted.example", allow), "verwijderde bron");
  ok(!hostAllowed("evil.example.com", allow), "vreemde host");
});

Deno.test("paden: API's, streams, media, eigen M3U/EPG; de rest niet", () => {
  const yes = [
    "http://tv.provider.example:8080/player_api.php?username=u&password=p&action=get_live_streams",
    "http://tv.provider.example:8080/get.php?username=u&password=p&type=m3u_plus",
    "http://tv.provider.example:8080/xmltv.php?username=u&password=p",
    "http://tv.provider.example:8080/portal.php?type=stb&action=handshake",
    "http://tv.provider.example:8080/stalker_portal/server/load.php?type=itv",
    "http://tv.provider.example:8080/c/",
    "http://tv.provider.example:8080/live/u/p/123.ts",
    "http://tv.provider.example:8080/live/u/p/123.m3u8",
    "http://tv.provider.example:8080/movie/u/p/456.mkv",
    "http://tv.provider.example:8080/series/u/p/789.mp4",
    "http://tv.provider.example:8080/timeshift/u/p/60/2026-10-23:10-00/123.ts",
    "http://tv.provider.example:8080/u/p/123",
    "http://tv.provider.example:8080/12345",
    "http://cdn2.provider.example/hls/abc/seg-1.ts",
    "http://tv.provider.example:8080/images/logo.png",
    "https://lists.example.org/raw/abc123",
    "http://lists.example.org/raw/abc123",
    "https://epg.example.net/guide.xml.gz",
  ];
  for (const u of yes) ok(pathAllowed(new URL(u), allow, false).ok, u);
  const no = [
    "http://tv.provider.example:8080/",
    "http://tv.provider.example:8080/admin/login",
    "http://tv.provider.example:8080/index.html",
    "http://tv.provider.example:8080/wp-login.php",
    "https://lists.example.org/raw/other",
    "https://lists.example.org/",
  ];
  for (const u of no) ok(!pathAllowed(new URL(u), allow, false).ok, u);
  ok(pathAllowed(new URL("https://any.cdn.example/whatever"), allow, true).ok, "ondertekend: elk pad (inhoud wordt gecontroleerd)");
});

Deno.test("poorten: 80, 443, >= 1024 behalve interne diensten", () => {
  for (const u of ["http://a.example/", "https://a.example/", "http://a.example:8080/", "http://a.example:25461/", "http://a.example:2095/"]) ok(portAllowed(new URL(u)), u);
  for (const u of ["http://a.example:22/", "http://a.example:25/", "http://a.example:6379/", "http://a.example:3306/", "http://a.example:11211/", "http://a.example:9200/", "http://a.example:2375/"]) ok(!portAllowed(new URL(u)), u);
});

Deno.test("content-type: nooit HTML/script; media blijft", () => {
  ok(safeContentType("text/html; charset=utf-8").startsWith("text/plain"), "html");
  ok(safeContentType("application/xhtml+xml").startsWith("text/plain"), "xhtml");
  ok(safeContentType("application/javascript").startsWith("text/plain"), "js");
  ok(safeContentType("text/css").startsWith("text/plain"), "css");
  ok(safeContentType("weird").startsWith("text/plain"), "onzin");
  ok(safeContentType("video/mp2t") === "video/mp2t", "ts");
  ok(safeContentType("application/vnd.apple.mpegurl") === "application/vnd.apple.mpegurl", "hls");
  ok(safeContentType("application/json") === "application/json", "json");
  ok(safeContentType("image/png") === "image/png", "png");
  ok(safeContentType("") === "application/octet-stream", "leeg");
  const h = safetyHeaders("text/plain; charset=utf-8");
  ok(h["X-Content-Type-Options"] === "nosniff" && h["Content-Security-Policy"].startsWith("sandbox") && h["Content-Disposition"] === "attachment", "niet-media: sandbox + attachment");
  ok(!("Content-Disposition" in safetyHeaders("video/mp4")), "media zonder attachment");
  ok(mediaLike("video/mp2t") && mediaLike("application/octet-stream") && mediaLike("") && !mediaLike("text/html"), "mediaLike");
});

Deno.test("limieten: standaard, grenzen en noodrem", () => {
  const d = quotaSettings(null);
  ok(d.enabled && d.free.bytes_day < d.lifetime.bytes_day && d.free.requests_hour < d.lifetime.requests_hour, "Gratis lager dan Lifetime");
  ok(quotaSettings({ enabled: false }).enabled === false, "noodrem");
  ok(quotaSettings({ free: { requests_hour: -5 } }).free.requests_hour === d.free.requests_hour, "ongeldig = standaard");
  ok(quotaSettings({ free: { requests_hour: 500 } }).free.requests_hour === 500, "eigen waarde");
  ok(overQuota({ requests_hour: 501, bytes_day: 0 }, { requests_hour: 500, bytes_day: 10 }), "boven aantal");
  ok(!overQuota({ requests_hour: 500, bytes_day: 10 }, { requests_hour: 500, bytes_day: 10 }), "precies op de grens mag");
});

// ---- spoedfix 25-10-2026 (http_502 in de webspeler) ----
import { actionName, failLog, pathKind, UPSTREAM_ERRORS, upstreamStatus } from "./policy.ts";

Deno.test("allowlist: alle aanroepen van de webspeler (login, categorieën, lijsten, series, EPG, M3U, streams)", () => {
  const base = "http://tv.provider.example:8080";
  for (const p of [
    "/player_api.php?username=u&password=p",
    ...["get_live_categories", "get_live_streams", "get_vod_categories", "get_vod_streams", "get_series_categories", "get_series",
      "get_series_info&series_id=1", "get_vod_info&vod_id=1", "get_short_epg&stream_id=1", "get_simple_data_table&stream_id=1"]
      .map((a) => `/player_api.php?username=u&password=p&action=${a}`),
    "/xmltv.php?username=u&password=p", "/get.php?username=u&password=p&type=m3u_plus&output=ts",
    "/live/u/p/1.ts", "/live/u/p/1.m3u8", "/movie/u/p/2.mkv", "/series/u/p/3.mp4", "/timeshift/u/p/60/2026-10-25:12-00/1.ts", "/u/p/1",
  ]) ok(pathAllowed(new URL(base + p), allow, false).ok, p);
  // M3U/EPG van de eigen bron, http én https
  ok(pathAllowed(new URL("http://lists.example.org/raw/abc123"), allow, false).ok, "M3U op http");
  ok(pathAllowed(new URL("https://epg.example.net/guide.xml.gz"), allow, false).ok, "EPG");
  // wat niet nodig is blijft dicht
  for (const p of ["/admin", "/", "/index.php", "/api/v1/users", "/player_api.php.bak", "/.env"]) ok(!pathAllowed(new URL(base + p), allow, false).ok, "dicht: " + p);
});
Deno.test("allowlist: serverURL met een pad ervoor (panel in een map)", () => {
  const a = allowFromSources([{ serverURL: "http://panel.example.com:2095/xc/" }]);
  ok(pathAllowed(new URL("http://panel.example.com:2095/xc/player_api.php?username=u&password=p&action=get_vod_streams"), a, false).ok, "API onder het pad");
  ok(pathAllowed(new URL("http://panel.example.com:2095/xc/movie/u/p/1.mp4"), a, false).ok, "film onder het pad");
  ok(!pathAllowed(new URL("http://panel.example.com:2095/xc/admin/login"), a, false).ok, "beheer onder het pad blijft dicht");
  ok(!pathAllowed(new URL("http://panel.example.com:2095/andere/admin"), a, false).ok, "ander pad");
  ok(!pathAllowed(new URL("http://other.example.org/xc/admin"), a, false).ok, "andere host");
  ok(!hostAllowed("evil.example.org", a), "geen andere hosts (SSRF)");
  const b = allowFromSources([{ serverURL: "http://panel.example.com/xc/player_api.php" }]);
  ok(pathAllowed(new URL("http://panel.example.com/xc/player_api.php?action=get_series"), b, false).ok, "serverURL met player_api.php erin");
});
Deno.test("foutsoorten: 504 voor time-outs, anders 502", () => {
  for (const k of UPSTREAM_ERRORS) ok(upstreamStatus(k) === (/timeout/.test(k) ? 504 : 502), k);
});
Deno.test("logregel: nooit host, gebruiker, wachtwoord of URL", () => {
  const t = new URL("https://geheim-panel.example.com:8443/player_api.php?username=jan%40mail.nl&password=Wachtwoord123&action=get_vod_streams");
  const l = failLog({ error: "tls_failed", target: t, ms: 512.4, form: "post" });
  ok(l === "web-proxy fout=tls_failed upstream=- vorm=post pad=api actie=get_vod_streams https=1 ms=512 bytes=0 doorverwijzingen=0", l);
  for (const bad of ["geheim", "example", "8443", "jan", "mail", "Wachtwoord", "player_api"]) ok(!l.includes(bad), "lekt " + bad);
  ok(actionName(new URL("http://h.example/player_api.php?username=u&password=p")) === "login", "login");
  ok(actionName(new URL("http://h.example/player_api.php?action=<script>")) === "?", "vreemde actie");
  ok(failLog({ error: "x y", target: t, ms: 1, form: "get" }).includes("fout=?"), "vreemde code");
  ok(failLog({ upstream: 502, target: new URL("http://h.example/movie/u/p/1.mkv"), ms: 3, redirects: 2, form: "post" }).includes("upstream=502 vorm=post pad=vod actie=-"), "upstream-status");
  ok(pathKind(new URL("http://h.example/xmltv.php")) === "epg" && pathKind(new URL("http://h.example/live/u/p/1.ts")) === "live", "padsoort");
});
Deno.test("limieten: boven de limiet is 429 quota_exceeded (overQuota), Lifetime ruimer", () => {
  const q = quotaSettings(null);
  ok(!overQuota({ requests_hour: q.free.requests_hour, bytes_day: 0 }, q.free), "op de grens mag");
  ok(overQuota({ requests_hour: q.free.requests_hour + 1, bytes_day: 0 }, q.free), "erboven niet");
  ok(overQuota({ requests_hour: 0, bytes_day: q.free.bytes_day + 1 }, q.free), "bytes");
  ok(!overQuota({ requests_hour: q.free.requests_hour + 1, bytes_day: 0 }, q.lifetime), "Lifetime ruimer");
  // een lijst van 200 MB past ruim in de daglimiet van Gratis
  ok(!overQuota({ requests_hour: 10, bytes_day: 200 * 1024 ** 2 }, q.free), "grote lijst");
});
