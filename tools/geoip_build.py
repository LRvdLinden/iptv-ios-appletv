#!/usr/bin/env python3
"""Compacte land-IP-tabel voor device-auth (_shared/geoip.ts) uit "IP to Country Lite" van DB-IP (https://db-ip.com, CC BY 4.0).

Invoer: de CSV (ook .csv.gz) met regels  begin,eind,landcode  (IPv4 en IPv6 door elkaar, zoals dbip-country-lite-JJJJ-MM.csv.gz).
Uitvoer (gzip): "BGEO1", u8 aantal landen, landcodes (2 bytes; index 0 = onbekend), u32 n4, u32 n6, dan n4 x u32 begin (IPv4),
n4 x u8 land, n6 x u64 begin (bovenste 64 bits van IPv6), n6 x u8 land. Alles big-endian, oplopend gesorteerd; een begin geldt
tot het volgende begin. Gaten tussen bereiken krijgen index 0, aangrenzende bereiken met hetzelfde land worden samengevoegd.
Alleen landcodes, geen IP-adressen van gebruikers. Gebruik: geoip_build.py <invoer.csv[.gz]> <uitvoer.bin.gz>
"""
import gzip, ipaddress, re, struct, sys

def build(lines):
    v4, v6 = [], []
    for line in lines:
        parts = line.strip().split(",")
        if len(parts) < 3: continue
        cc = parts[2].strip().strip('"').upper()
        if not re.fullmatch(r"[A-Z]{2}", cc) or cc in ("ZZ", "XX"): continue
        try: a, b = ipaddress.ip_address(parts[0].strip().strip('"')), ipaddress.ip_address(parts[1].strip().strip('"'))
        except ValueError: continue
        if a.version != b.version or int(b) < int(a): continue
        if a.version == 4: v4.append((int(a), int(b), cc))
        else: v6.append((int(a) >> 64, int(b) >> 64, cc))
    codes = ["--"] + sorted({r[2] for r in v4 + v6})
    if len(codes) > 255: raise SystemExit("te veel landcodes")
    idx = {c: i for i, c in enumerate(codes)}

    def table(ranges):
        ranges.sort()
        out = []  # [(begin, index)]
        nxt = 0   # eerste adres na het vorige bereik
        for a, b, cc in ranges:
            if b < nxt: continue            # valt binnen een eerder bereik (IPv6 kleiner dan /64)
            a = max(a, nxt)
            if a > nxt and (not out or out[-1][1] != 0): out.append((nxt, 0))
            i = idx[cc]
            if not out or out[-1][1] != i:
                if out and out[-1][0] == a: out[-1] = (a, i)
                else: out.append((a, i))
            nxt = b + 1
        if not out or out[0][0] != 0: out.insert(0, (0, 0))
        return out

    t4, t6 = table(v4), table(v6)
    raw = bytearray(b"BGEO1")
    raw += struct.pack(">B", len(codes)) + "".join(codes).encode("ascii")
    raw += struct.pack(">II", len(t4), len(t6))
    raw += b"".join(struct.pack(">I", a) for a, _ in t4) + bytes(i for _, i in t4)
    raw += b"".join(struct.pack(">Q", a) for a, _ in t6) + bytes(i for _, i in t6)
    return bytes(raw), len(t4), len(t6), len(codes) - 1

def main():
    if len(sys.argv) != 3: raise SystemExit(__doc__)
    src = sys.argv[1]
    opener = gzip.open if src.endswith(".gz") else open
    with opener(src, "rt", encoding="utf-8", errors="replace") as f:
        raw, n4, n6, nc = build(f)
    if n4 < 50000 or n6 < 10000 or nc < 200: raise SystemExit(f"tabel te klein ({n4}/{n6}/{nc}): invoer niet in orde")
    with open(sys.argv[2], "wb") as f: f.write(gzip.compress(raw, 9, mtime=0))
    print(f"{n4} IPv4- en {n6} IPv6-bereiken, {nc} landen, {len(raw)} bytes")

if __name__ == "__main__":
    main()
