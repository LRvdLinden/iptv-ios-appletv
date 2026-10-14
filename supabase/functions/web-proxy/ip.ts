// build 95: welke IP-adressen mag de web-proxy nooit benaderen (SSRF)? Pure functies, getest in ip_test.ts (deno test).
// Alles wat niet als IPv4 of IPv6 te lezen is, telt als geblokkeerd (liever dicht dan open).

/** "a.b.c.d" (precies vier decimale delen 0-255) -> 32-bits getal, anders null. */
export function parseIPv4(s: string): number | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return null;
  let n = 0;
  for (let i = 1; i <= 4; i++) {
    const p = Number(m[i]);
    if (p > 255) return null;
    n = n * 256 + p;
  }
  return n;
}

/** IPv6 (ook met :: , een ingebed IPv4-deel, [haken] en %zone) -> 8 groepen van 16 bits, anders null. */
export function parseIPv6(s: string): number[] | null {
  let v = s.trim().toLowerCase().replace(/^\[|\]$/g, "");
  const pct = v.indexOf("%");
  if (pct >= 0) v = v.slice(0, pct);
  if (!v.includes(":")) return null;
  // ingebed IPv4 aan het eind (::ffff:127.0.0.1) -> twee groepen
  const last = v.lastIndexOf(":");
  const tail = v.slice(last + 1);
  if (tail.includes(".")) {
    const n = parseIPv4(tail);
    if (n == null) return null;
    v = v.slice(0, last + 1) + ((n >>> 16) & 0xffff).toString(16) + ":" + (n & 0xffff).toString(16);
  }
  const dbl = v.split("::");
  if (dbl.length > 2) return null;
  const part = (x: string) => (x === "" ? [] : x.split(":"));
  const head = part(dbl[0]), rest = dbl.length === 2 ? part(dbl[1]) : [];
  const fill = 8 - head.length - rest.length;
  if (dbl.length === 2 ? fill < 1 : fill !== 0) return null;
  const all = [...head, ...Array(dbl.length === 2 ? fill : 0).fill("0"), ...rest];
  const out: number[] = [];
  for (const g of all) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    out.push(parseInt(g, 16));
  }
  return out.length === 8 ? out : null;
}

const inV4 = (n: number, base: string, bits: number) => {
  const b = parseIPv4(base)!;
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return ((n & mask) >>> 0) === ((b & mask) >>> 0);
};

// niet-publieke IPv4-blokken (RFC 6890 e.a.)
const V4_BLOCKED: [string, number][] = [
  ["0.0.0.0", 8], // "dit netwerk"
  ["10.0.0.0", 8], // privé
  ["100.64.0.0", 10], // carrier-grade NAT
  ["127.0.0.0", 8], // loopback
  ["169.254.0.0", 16], // link-local (ook cloud-metadata 169.254.169.254)
  ["172.16.0.0", 12], // privé
  ["192.0.0.0", 24], // IETF-protocoltoewijzingen
  ["192.0.2.0", 24], // documentatie (TEST-NET-1)
  ["192.88.99.0", 24], // 6to4-relay (uitgefaseerd)
  ["192.168.0.0", 16], // privé
  ["198.18.0.0", 15], // benchmarks
  ["198.51.100.0", 24], // documentatie (TEST-NET-2)
  ["203.0.113.0", 24], // documentatie (TEST-NET-3)
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // gereserveerd, incl. broadcast 255.255.255.255
];

export function isBlockedIPv4(n: number): boolean {
  return V4_BLOCKED.some(([b, bits]) => inV4(n >>> 0, b, bits));
}

/** IPv4 uit twee groepen van 16 bits. */
const v4of = (hi: number, lo: number) => ((hi << 16) >>> 0) + lo;

export function isBlockedIPv6(g: number[]): boolean {
  const zero = (from: number, to: number) => g.slice(from, to).every((x) => x === 0);
  // :: en ::1, en IPv4-compatibel ::a.b.c.d (::/96, uitgefaseerd sinds RFC 4291): altijd dicht
  if (zero(0, 6)) return true;
  // IPv4-mapped ::ffff:a.b.c.d (::ffff:0:0/96), ook in hex-vorm (::ffff:7f00:1)
  if (zero(0, 5) && g[5] === 0xffff) return isBlockedIPv4(v4of(g[6], g[7]));
  // SIIT ::ffff:0:a.b.c.d (::ffff:0:0:0/96)
  if (zero(0, 4) && g[4] === 0xffff && g[5] === 0) return isBlockedIPv4(v4of(g[6], g[7]));
  // NAT64 64:ff9b::/96 (bekend prefix): ingebed adres controleren
  if (g[0] === 0x64 && g[1] === 0xff9b && zero(2, 6)) return isBlockedIPv4(v4of(g[6], g[7]));
  // NAT64 64:ff9b:1::/48 (lokaal gebruik, RFC 8215): het netwerk van de beheerder zelf -> altijd dicht
  if (g[0] === 0x64 && g[1] === 0xff9b && g[2] === 1) return true;
  // 6to4 2002::/16: IPv4 staat in groep 1 en 2
  if (g[0] === 0x2002) return isBlockedIPv4(v4of(g[1], g[2]));
  // Teredo 2001::/32: tunnel naar een (verhuld) IPv4-adres -> altijd dicht
  if (g[0] === 0x2001 && g[1] === 0) return true;
  // documentatie 2001:db8::/32
  if (g[0] === 0x2001 && g[1] === 0x0db8) return true;
  // discard 100::/64
  if (g[0] === 0x0100 && zero(1, 4)) return true;
  // ULA fc00::/7, link-local fe80::/10, site-local fec0::/10, multicast ff00::/8: vallen allemaal buiten 2000::/3,
  // net als alles wat nog niet is uitgegeven; alleen globale unicast (2000::/3) mag
  return (g[0] & 0xe000) !== 0x2000;
}

/** true = dit adres (IPv4 of IPv6, als tekst) mag de proxy nooit benaderen. Onleesbaar = geblokkeerd. */
export function isBlockedIP(ip: string): boolean {
  const s = String(ip ?? "").trim().replace(/^\[|\]$/g, "");
  const v4 = parseIPv4(s);
  if (v4 != null) return isBlockedIPv4(v4);
  const v6 = parseIPv6(s);
  if (v6 != null) return isBlockedIPv6(v6);
  return true;
}

/**
 * Hostnaam uit `new URL()` die er als IP-adres uitziet. new URL() maakt van 2130706433, 0x7f.1, 017700000001, 127.1 en
 * %31%32%37.0.0.1 al "127.0.0.1" en van IPv6 de korte vorm tussen haken; wat dan nog alleen uit cijfers/hex/punten
 * bestaat maar geen geldig a.b.c.d is (bv. uit een eigen parser), behandelen we als IP-literal dat niet te lezen is.
 */
export function ipLiteral(host: string): { ip: string } | { bad: true } | null {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (h.startsWith("[") || h.includes(":")) {
    const v = h.replace(/^\[|\]$/g, "");
    return parseIPv6(v) ? { ip: v } : { bad: true };
  }
  if (parseIPv4(h) != null) return { ip: h };
  // alleen cijfers, hex (0x..) en punten: numerieke vorm die new URL() niet normaliseerde -> niet toestaan
  if (/^(0x[0-9a-f]*|\d+)(\.(0x[0-9a-f]*|\d+))*$/i.test(h)) return { bad: true };
  return null;
}
