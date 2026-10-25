// deno test supabase/functions/_shared/geoip_test.ts
import { lookup, parseTable } from "./geoip.ts";
import { countryFor, visitorIp } from "./country.ts";
function eq(a: unknown, b: unknown, msg = "") { if (a !== b) throw new Error(`${msg} verwacht ${b}, kreeg ${a}`); }

// kleine tabel in het formaat van tools/geoip_build.py: codes [--, NL, US], IPv4 0.0.0.0 -> --, 1.0.0.0 -> NL,
// 1.0.1.0 -> --, 8.0.0.0 -> US; IPv6 :: -> --, 2001:db8:: -> NL, 2001:db9:: -> --
function tiny(): Uint8Array {
  const codes = ["--", "NL", "US"], v4 = [[0, 0], [0x01000000, 1], [0x01000100, 0], [0x08000000, 2]];
  const v6: [bigint, number][] = [[0n, 0], [0x20010db800000000n, 1], [0x20010db900000000n, 0]];
  const out = [..."BGEO1"].map((c) => c.charCodeAt(0));
  out.push(codes.length, ...codes.join("").split("").map((c) => c.charCodeAt(0)));
  const u32 = (n: number) => [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  out.push(...u32(v4.length), ...u32(v6.length));
  for (const [a] of v4) out.push(...u32(a));
  for (const [, i] of v4) out.push(i);
  for (const [a] of v6) for (let s = 56n; s >= 0n; s -= 8n) out.push(Number((a >> s) & 255n));
  for (const [, i] of v6) out.push(i);
  return new Uint8Array(out);
}

Deno.test("geoip: tabel lezen en opzoeken (IPv4, IPv6, gaten, ongeldig)", () => {
  const t = parseTable(tiny())!;
  eq(t.v4.length, 4, "IPv4-bereiken");
  eq(lookup(t, "1.0.0.7"), "NL", "binnen NL");
  eq(lookup(t, "1.0.1.0"), null, "gat");
  eq(lookup(t, "0.1.2.3"), null, "begin");
  eq(lookup(t, "8.8.8.8"), "US", "US");
  eq(lookup(t, "255.255.255.255"), "US", "laatste bereik loopt door");
  eq(lookup(t, "2001:db8::1"), "NL", "IPv6 met ::");
  eq(lookup(t, "2001:0db8:1234:5678:9abc:def0:1234:5678"), "NL", "IPv6 voluit");
  eq(lookup(t, "2001:db9::"), null, "IPv6-gat");
  eq(lookup(t, "::ffff:1.0.0.1"), "NL", "IPv4-gemapt");
  for (const bad of ["", "1.2.3", "256.1.1.1", "abc", "1::2::3", "2001:db8::g"]) eq(lookup(t, bad), null, `"${bad}"`);
  eq(parseTable(new Uint8Array([1, 2, 3])), null, "kapotte invoer");
  eq(parseTable(tiny().slice(0, -1)), null, "afgekapt");
});

Deno.test("land: header eerst, anders de tabel; alleen met een geldig IP", async () => {
  const t = parseTable(tiny())!, tab = () => Promise.resolve(t);
  const r = (h: Record<string, string>) => new Request("https://x.test/", { headers: h });
  eq(await countryFor(r({ "cf-ipcountry": "BE", "cf-connecting-ip": "1.0.0.1" }), tab), "BE", "header wint");
  eq(await countryFor(r({ "cf-connecting-ip": "1.0.0.1" }), tab), "NL", "cf-connecting-ip");
  eq(await countryFor(r({ "x-forwarded-for": "8.8.8.8, 1.0.0.1" }), tab), "NL", "laatste X-Forwarded-For");
  eq(await countryFor(r({ "cf-connecting-ip": "1.0.1.5" }), tab), null, "onbekend bereik");
  eq(await countryFor(r({}), tab), null, "geen IP");
  eq(await countryFor(r({ "cf-connecting-ip": "1.0.0.1" }), () => Promise.resolve(null)), null, "geen tabel");
  eq(visitorIp(r({ "cf-connecting-ip": "nep", "x-forwarded-for": "1.0.0.1" })), "1.0.0.1", "ongeldige cf-connecting-ip");
});
