// deno test supabase/functions/web-proxy/ip_test.ts
// build 95: interne adressen blokkeren in de web-proxy (SSRF), ook verstopt in IPv6-vormen en numerieke hostnamen.
import { ipLiteral, isBlockedIP, parseIPv6 } from "./ip.ts";

function blocked(list: string[]) {
  for (const ip of list) if (!isBlockedIP(ip)) throw new Error(`${ip} had geblokkeerd moeten zijn`);
}
function open(list: string[]) {
  for (const ip of list) if (isBlockedIP(ip)) throw new Error(`${ip} had toegestaan moeten zijn`);
}

Deno.test("IPv4: niet-publieke blokken dicht", () => {
  blocked([
    "0.0.0.0", "0.255.255.255", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1", "127.255.255.254",
    "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.1", "192.0.0.255", "192.168.1.1", "198.18.0.1", "198.19.255.255",
    "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255", "192.0.2.10", "203.0.113.5",
  ]);
});

Deno.test("IPv4: publieke adressen open (ook vlak naast de blokken)", () => {
  open([
    "1.1.1.1", "8.8.8.8", "9.255.255.255", "11.0.0.1", "100.63.255.255", "100.128.0.0", "126.255.255.255", "128.0.0.1",
    "169.253.255.255", "172.15.255.255", "172.32.0.0", "192.0.1.1", "192.167.255.255", "192.169.0.0", "198.17.255.255",
    "198.20.0.0", "223.255.255.255", "93.184.215.14",
  ]);
});

Deno.test("IPv6: loopback, ULA, link-local, multicast dicht", () => {
  blocked(["::", "::1", "[::1]", "fc00::1", "fd12:3456::1", "fe80::1", "fe80::1%eth0", "febf::1", "fec0::1", "ff02::1", "ff00::"]);
});

Deno.test("IPv6: IPv4-mapped en -compatibel, dotted en hex", () => {
  blocked([
    "::ffff:127.0.0.1", "::ffff:7f00:1", "0:0:0:0:0:ffff:7f00:1", "::ffff:10.0.0.1", "::ffff:a9fe:a9fe", "::ffff:0:0",
    "::127.0.0.1", "::7f00:1", "::10.1.2.3", "::ffff:0:7f00:1", "::ffff:0:127.0.0.1",
  ]);
  // IPv4-compatibel (::/96) is uitgefaseerd: ook met een publiek adres dicht
  blocked(["::8.8.8.8", "::808:808"]);
  // mapped/compatibel naar een publiek adres: het ingebedde adres telt
  open(["::ffff:8.8.8.8", "::ffff:808:808"]);
});

Deno.test("IPv6: NAT64, 6to4 en Teredo", () => {
  blocked(["64:ff9b::7f00:1", "64:ff9b::127.0.0.1", "64:ff9b::a00:1", "64:ff9b:1::8.8.8.8", "64:ff9b:1:abcd::1"]);
  open(["64:ff9b::808:808"]);
  blocked(["2002:7f00:1::1", "2002:a00:1::", "2002:c0a8:101::1"]);
  open(["2002:808:808::1"]);
  blocked(["2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2", "2001:db8::1"]);
});

Deno.test("IPv6: globale unicast open", () => {
  open(["2a00:1450:400e:80f::200e", "2606:4700:4700::1111", "2001:4860:4860::8888", "[2620:fe::fe]"]);
});

Deno.test("onleesbaar = dicht", () => {
  blocked(["", "localhost", "256.1.1.1", "1.2.3", "1.2.3.4.5", "::g", "1:2:3:4:5:6:7:8:9", "1::2::3", "abc", "0x7f.1"]);
});

Deno.test("parseIPv6 vult :: correct aan", () => {
  const eq = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`); };
  eq(parseIPv6("::1"), [0, 0, 0, 0, 0, 0, 0, 1]);
  eq(parseIPv6("1::"), [1, 0, 0, 0, 0, 0, 0, 0]);
  eq(parseIPv6("::ffff:1.2.3.4"), [0, 0, 0, 0, 0, 0xffff, 0x0102, 0x0304]);
  eq(parseIPv6("1:2:3:4:5:6:7:8"), [1, 2, 3, 4, 5, 6, 7, 8]);
  eq(parseIPv6("1:2:3:4:5:6:7::"), [1, 2, 3, 4, 5, 6, 7, 0]);
  eq(parseIPv6("1:2:3:4:5:6:7:8::"), null);
});

Deno.test("numerieke hostnamen: new URL() normaliseert, de rest wordt geweigerd", () => {
  for (const raw of ["http://2130706433/", "http://0x7f.1/", "http://017700000001/", "http://127.1/", "http://0x7f000001/", "http://%31%32%37.0.0.1/"]) {
    const h = new URL(raw).hostname;
    const lit = ipLiteral(h);
    if (!lit || !("ip" in lit) || !isBlockedIP(lit.ip)) throw new Error(`${raw} -> ${h} niet als intern IP herkend`);
  }
  for (const raw of ["http://[::ffff:127.0.0.1]/", "http://[64:ff9b::7f00:1]/", "http://[::127.0.0.1]/"]) {
    const lit = ipLiteral(new URL(raw).hostname);
    if (!lit || !("ip" in lit) || !isBlockedIP(lit.ip)) throw new Error(`${raw} niet als intern IP herkend`);
  }
  // wat new URL() niet normaliseert maar wel numeriek oogt: geweigerd
  for (const h of ["0x7f.1", "017700000001", "1.2.3", "0x"]) {
    const lit = ipLiteral(h);
    if (!lit || !("bad" in lit)) throw new Error(`${h} had als onleesbaar IP-literal geweigerd moeten worden`);
  }
  // gewone namen zijn geen literal; publieke IP's wel
  if (ipLiteral("tv.example.com") !== null || ipLiteral("127.0.0.1.nip.io") !== null) throw new Error("hostnaam als literal gezien");
  const pub = ipLiteral("8.8.8.8");
  if (!pub || !("ip" in pub) || isBlockedIP(pub.ip)) throw new Error("8.8.8.8 hoort open te zijn");
});
