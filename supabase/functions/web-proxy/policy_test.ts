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
