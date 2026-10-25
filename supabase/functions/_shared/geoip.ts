// Landcode uit het IP-adres van de aanvraag, zonder derde partij: een eigen land-IP-tabel ("IP to Country Lite" van DB-IP,
// https://db-ip.com, CC BY 4.0) die tools/geoip_build.py compact maakt en de workflow GeoIP maandelijks in de privé-bucket
// "geoip" van Storage zet (country.bin.gz). De functie laadt hem één keer per koude start in het geheugen en zoekt daar binair
// in. Het IP-adres verlaat de functie niet, wordt nergens bewaard en komt nooit in een log; alleen de landcode gaat verder.
// Indeling: zie tools/geoip_build.py.

export type GeoTable = { codes: string[]; v4: Uint32Array; c4: Uint8Array; v6: BigUint64Array; c6: Uint8Array };

export function parseTable(raw: Uint8Array): GeoTable | null {
  if (raw.length < 15 || new TextDecoder().decode(raw.subarray(0, 5)) !== "BGEO1") return null;
  const dv = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  let o = 5;
  const nc = raw[o++];
  const codes: string[] = [];
  for (let i = 0; i < nc; i++, o += 2) codes.push(String.fromCharCode(raw[o], raw[o + 1]));
  const n4 = dv.getUint32(o), n6 = dv.getUint32(o + 4);
  o += 8;
  if (raw.length !== o + n4 * 5 + n6 * 9) return null;
  const v4 = new Uint32Array(n4);
  for (let i = 0; i < n4; i++, o += 4) v4[i] = dv.getUint32(o);
  const c4 = raw.slice(o, o + n4); o += n4;
  const v6 = new BigUint64Array(n6);
  for (let i = 0; i < n6; i++, o += 8) v6[i] = dv.getBigUint64(o);
  const c6 = raw.slice(o, o + n6);
  return { codes, v4, c4, v6, c6 };
}

// laatste index met begin <= x (de tabel begint altijd bij 0)
function floorIndex<T extends number | bigint>(arr: ArrayLike<T>, x: T): number {
  let lo = 0, hi = arr.length - 1;
  if (hi < 0 || x < arr[0]) return -1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (arr[mid] <= x) lo = mid; else hi = mid - 1;
  }
  return lo;
}

function v4Num(ip: string): number | null {
  const p = ip.split(".");
  if (p.length !== 4) return null;
  let n = 0;
  for (const s of p) {
    if (!/^\d{1,3}$/.test(s) || Number(s) > 255) return null;
    n = n * 256 + Number(s);
  }
  return n;
}

// bovenste 64 bits van een IPv6-adres (ook :: en IPv4-gemapte adressen)
function v6High(ip: string): bigint | null {
  const s = ip.toLowerCase().replace(/%.*$/, "");
  if (!/^[0-9a-f:.]+$/.test(s) || (s.match(/::/g) ?? []).length > 1) return null;
  let tail = s;
  const extra: string[] = [];
  const m = s.match(/^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (m) {
    const n = v4Num(m[2]);
    if (n === null) return null;
    tail = m[1].endsWith("::") ? m[1] : m[1].slice(0, -1);
    extra.push((n >>> 16).toString(16), (n & 0xffff).toString(16));
  }
  const [a, b] = tail.split("::");
  const left = a ? a.split(":") : [], right = b !== undefined && b !== "" ? b.split(":") : [];
  const groups = tail.includes("::")
    ? [...left, ...Array(8 - left.length - right.length - extra.length).fill("0"), ...right, ...extra]
    : [...left, ...extra];
  if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  let h = 0n;
  for (let i = 0; i < 4; i++) h = (h << 16n) | BigInt(parseInt(groups[i], 16));
  return h;
}

export function lookup(t: GeoTable, ip: string): string | null {
  let code = 0;
  const n = v4Num(ip);
  if (n !== null) {
    const i = floorIndex(t.v4, n);
    code = i < 0 ? 0 : t.c4[i];
  } else {
    const mapped = ip.toLowerCase().match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
    if (mapped) return lookup(t, mapped[1]);
    const h = v6High(ip);
    if (h === null) return null;
    const i = floorIndex(t.v6, h);
    code = i < 0 ? 0 : t.c6[i];
  }
  const cc = t.codes[code] ?? "--";
  return /^[A-Z]{2}$/.test(cc) ? cc : null;
}

// Eén keer per koude start laden (gedeelde belofte); mislukt het, dan na 10 minuten opnieuw proberen.
let pending: Promise<GeoTable | null> | null = null;
let failedAt = 0;
export function loadTable(fetchRaw: () => Promise<Uint8Array | null>): Promise<GeoTable | null> {
  if (pending) return pending;
  if (failedAt && Date.now() - failedAt < 10 * 60 * 1000) return Promise.resolve(null);
  pending = (async () => {
    try {
      const raw = await fetchRaw();
      const t = raw ? parseTable(raw) : null;
      if (!t) { failedAt = Date.now(); pending = null; }
      return t;
    } catch {
      failedAt = Date.now(); pending = null;
      return null;
    }
  })();
  return pending;
}

export async function gunzip(data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
