#!/usr/bin/env python3
"""Start-rooktest (build 141): een crashrapport (.ips) samenvatten voor het (openbare) CI-log.

Gebruik: smoke_crash.py <rapport.ips> [<rapport.ips> ...]

Alleen het soort fout, de reden en de stack van de gecrashte thread (image + symbool). Geen paden, geen
apparaat- of gebruikersgegevens (die staan in de kop van het rapport en worden niet getoond).
"""
import json
import re
import sys


def scrub(s):
    s = str(s)
    s = re.sub(r"/Users/[^/\s]+", "~", s)
    s = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", s)
    s = re.sub(r"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b", "<id>", s, flags=re.I)
    return s


def summarize(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    # .ips: eerste regel is een JSON-kop, de rest het rapport (JSON). Ouder formaat: platte tekst.
    first, _, rest = raw.partition("\n")
    try:
        head = json.loads(first)
        body = json.loads(rest)
    except Exception:
        lines = [l for l in raw.splitlines() if re.match(r"^(Exception Type|Termination Reason|Crashed Thread|\d+\s+\S+\s+0x)", l)]
        return [scrub(l) for l in lines[:40]]
    out = []
    app = head.get("app_name") or body.get("procName") or "?"
    out.append(f"app: {app} {head.get('app_version', '')} ({head.get('build_version', '')}) os: {head.get('os_version', '')}")
    exc = body.get("exception") or {}
    if exc:
        out.append(f"exception: {exc.get('type', '')} {exc.get('signal', '')} {exc.get('subtype', '')}".strip())
    term = body.get("termination") or {}
    if term:
        out.append(f"termination: {term.get('namespace', '')} {term.get('indicator', '')} {term.get('code', '')}".strip())
        for r in (term.get("reasons") or [])[:3]:
            out.append("reason: " + str(r)[:300])
    asi = body.get("asi") or {}
    for k, v in asi.items():
        for line in (v if isinstance(v, list) else [v])[:3]:
            out.append(f"asi {k}: {str(line)[:400]}")
    images = body.get("usedImages") or []
    threads = body.get("threads") or []
    ci = body.get("faultingThread")
    crashed = None
    if isinstance(ci, int) and 0 <= ci < len(threads):
        crashed = threads[ci]
    else:
        crashed = next((t for t in threads if t.get("triggered")), threads[0] if threads else None)
    if crashed:
        name = crashed.get("name") or crashed.get("queue") or ""
        out.append(f"thread {ci}: {name}")
        for i, f in enumerate((crashed.get("frames") or [])[:30]):
            img = images[f["imageIndex"]].get("name", "?") if "imageIndex" in f and f["imageIndex"] < len(images) else "?"
            sym = f.get("symbol", "")
            loc = f.get("symbolLocation", f.get("imageOffset", ""))
            src = ""
            if f.get("sourceFile"):
                src = f"  ({f['sourceFile']}:{f.get('sourceLine', '')})"
            out.append(f"  {i:2d} {img:<28} {sym} + {loc}{src}")
    return [scrub(l) for l in out]


def main():
    for p in sys.argv[1:]:
        print(f"--- {p.split('/')[-1].split('-')[0]}")
        for l in summarize(p):
            print(l)


if __name__ == "__main__":
    main()
