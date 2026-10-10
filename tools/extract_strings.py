#!/usr/bin/env python3
"""Haalt alle L("...")-sleutels uit de Swift-bronnen en controleert Translations.json."""
import json, re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
pat = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
keys, bad = {}, []
for f in sorted((root / "Shared").rglob("*.swift")):
    if "Localization" in f.parts: continue
    for m in pat.finditer(f.read_text()):
        raw = m.group(1)
        if "\\(" in raw: bad.append((f.name, raw)); continue
        key = raw.encode().decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in raw else raw
        keys.setdefault(key, f.name)
if bad:
    print("Interpolatie in L()-sleutel (niet toegestaan):", *bad, sep="\n  "); sys.exit(1)
if "--list" in sys.argv:
    json.dump(sorted(keys), sys.stdout, ensure_ascii=False, indent=1); sys.exit(0)
tfile = root / "Shared/Resources/Translations.json"
t = json.loads(tfile.read_text()) if tfile.exists() else {}
langs = ["nl", "de", "fr", "es", "it", "pt", "tr", "pl", "ar", "zh-Hans"]
missing = {l: [k for k in keys if k not in t.get(l, {})] for l in langs}
fmt = re.compile(r'%(?:\d+\$)?[@dlfs]|%ld')
wrong = [(l, k) for l in langs for k, v in t.get(l, {}).items() if k in keys and sorted(fmt.findall(k)) != sorted(fmt.findall(v))]
print(f"{len(keys)} sleutels")
for l in langs: print(f"  {l}: {len(missing[l])} ontbrekend")
if wrong: print("Opmaakcodes komen niet overeen:", *wrong[:20], sep="\n  ")
sys.exit(1 if any(missing.values()) or wrong else 0)
