// deno test supabase/functions/web-proxy/hls_test.ts
// HLS voor films en afleveringen (build 83): Xtream-panels sturen /movie/…/<id>.m3u8 door naar een load balancer en
// zetten relatieve of absolute segmenten (vaak met een token) in de afspeellijst; alles moet via de proxy lopen.
import { b64url, isHlsPlaylist, rewritePlaylist, unb64url } from "./hls.ts";

function eq(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`verwacht ${JSON.stringify(b)}, kreeg ${JSON.stringify(a)}`);
}
const wrap = (u: string) => `P(${u})`;

Deno.test("VOD-mediaplaylist: relatieve, root-relatieve en absolute segmenten, sleutel en map", () => {
  const text = [
    "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "#EXT-X-PLAYLIST-TYPE:VOD",
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin?t=abc"',
    '#EXT-X-MAP:URI="/hls/tok123/init.mp4"',
    "#EXTINF:10.0,", "seg_0.ts",
    "#EXTINF:10.0,", "/hls/tok123/seg_1.ts",
    "#EXTINF:10.0,", "http://cdn.example.net:8080/v/seg_2.ts?token=x",
    "#EXT-X-ENDLIST", "",
  ].join("\n");
  const base = "http://lb.example.com:25461/movie/abc/def/77/index.m3u8"; // eindadres na de doorverwijzing
  eq(isHlsPlaylist(text), true);
  const out = rewritePlaylist(text, base, wrap).split("\n");
  eq(out[4], '#EXT-X-KEY:METHOD=AES-128,URI="P(http://lb.example.com:25461/movie/abc/def/77/key.bin?t=abc)"');
  eq(out[5], '#EXT-X-MAP:URI="P(http://lb.example.com:25461/hls/tok123/init.mp4)"');
  eq(out[7], "P(http://lb.example.com:25461/movie/abc/def/77/seg_0.ts)");
  eq(out[9], "P(http://lb.example.com:25461/hls/tok123/seg_1.ts)");
  eq(out[11], "P(http://cdn.example.net:8080/v/seg_2.ts?token=x)");
  eq(out[12], "#EXT-X-ENDLIST");
});

Deno.test("master met varianten en audio-rendition", () => {
  const text = [
    "#EXTM3U",
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="NL",URI="audio/nl.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="a"', "720/index.m3u8",
  ].join("\r\n");
  const out = rewritePlaylist(text, "https://h.example.com/series/u/p/9.m3u8", wrap).split("\n");
  eq(out[1], '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="NL",URI="P(https://h.example.com/series/u/p/audio/nl.m3u8)"');
  eq(out[3], "P(https://h.example.com/series/u/p/720/index.m3u8)");
});

Deno.test("geen HLS: M3U-zenderlijst, HTML, Matroska", () => {
  eq(isHlsPlaylist("#EXTM3U\n#EXTINF:-1 tvg-id=\"x\",Zender\nhttp://a/b.ts\n"), false);
  eq(isHlsPlaylist("<html><body>403</body></html>"), false);
  eq(isHlsPlaylist("\u001aEß£"), false);
  eq(isHlsPlaylist("﻿#EXTM3U\n#EXT-X-TARGETDURATION:6\n"), true);
});

Deno.test("base64url heen en terug (ook niet-ASCII)", () => {
  const u = "http://h.example.com/movie/ü/p/1.m3u8?x=a+b/c";
  eq(unb64url(b64url(u)), u);
});
