// Bingr web-proxy: HLS-afspeellijsten herschrijven, zodat de browser ook varianten, segmenten, sleutels en
// renditions via de proxy ophaalt (een https-pagina mag niets van http laden, en Safari's eigen HLS-speler kan geen
// headers meesturen). Los bestand zodat het zonder Supabase te testen is (deno test / node).

/** Is dit een HLS-mediaplaylist of master (en geen IPTV-zenderlijst in M3U-vorm)? */
export function isHlsPlaylist(text: string): boolean {
  const head = text.replace(/^﻿/, "").trimStart();
  if (!head.startsWith("#EXTM3U")) return false;
  return /^#EXT-X-(TARGETDURATION|STREAM-INF|MEDIA-SEQUENCE|VERSION|MEDIA|I-FRAME-STREAM-INF|KEY|MAP|PLAYLIST-TYPE|ENDLIST|INDEPENDENT-SEGMENTS|PART-INF|SERVER-CONTROL)\b/m.test(head);
}

/**
 * Elke URI in de afspeellijst absoluut maken (t.o.v. `base`, het adres na doorverwijzingen) en door `wrap` halen.
 * - regels zonder # zijn URI's (varianten, segmenten);
 * - in #-regels de attributen URI="…" (EXT-X-KEY, -MAP, -MEDIA, -I-FRAME-STREAM-INF, -SESSION-KEY, -PART,
 *   -PRELOAD-HINT, -RENDITION-REPORT, -SESSION-DATA).
 * Alleen http(s); andere schema's (skd://, data:) blijven staan.
 */
export function rewritePlaylist(text: string, base: string, wrap: (absUrl: string) => string): string {
  const conv = (raw: string): string => {
    const v = raw.trim();
    if (!v) return raw;
    let abs: URL;
    try { abs = new URL(v, base); } catch { return raw; }
    if (abs.protocol !== "http:" && abs.protocol !== "https:") return raw;
    return wrap(abs.toString());
  };
  return text.split(/\r?\n/).map((line) => {
    if (!line.trim()) return line;
    if (line.startsWith("#")) {
      if (!/URI="/i.test(line)) return line;
      return line.replace(/(URI=")([^"]*)(")/gi, (_m, a: string, u: string, c: string) => a + conv(u) + c);
    }
    return conv(line);
  }).join("\n");
}

/** base64url zonder opvulling (voor de u-parameter en tokens). */
export function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function unb64url(s: string): string {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(t + "===".slice((t.length + 3) % 4));
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}
