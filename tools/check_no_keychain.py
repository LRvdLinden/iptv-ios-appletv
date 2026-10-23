#!/usr/bin/env python3
"""Build 144: geen sleutelhanger of iCloud meer als opslag. SecItem*- en NSUbiquitousKeyValueStore-aanroepen mogen alleen
nog in de eenmalige overzetting (Shared/Storage/Keychain.swift → LegacySecrets, CloudStore.importFromICloudOnce)."""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
bad = []
for f in sorted((root / "Shared").rglob("*.swift")):
    text = f.read_text()
    for i, line in enumerate(text.splitlines(), 1):
        code = line.split("//", 1)[0]
        if re.search(r"\bSecItem(Add|Update|Delete|CopyMatching)\b", code) and f.name != "Keychain.swift":
            bad.append(f"{f.relative_to(root)}:{i}: {line.strip()}")
        if "NSUbiquitousKeyValueStore" in code and f.name not in ("Keychain.swift", "CloudStore.swift"):
            bad.append(f"{f.relative_to(root)}:{i}: {line.strip()}")
cs = (root / "Shared/Storage/CloudStore.swift").read_text()
uses = [l for l in cs.splitlines() if "NSUbiquitousKeyValueStore" in l.split("//", 1)[0]]
if len(uses) != 1 or ".default" not in uses[0]:
    bad.append("CloudStore.swift: iCloud KV alleen in importFromICloudOnce (precies één keer NSUbiquitousKeyValueStore.default)")
kc = (root / "Shared/Storage/Keychain.swift").read_text()
legacy = kc.split("private enum LegacySecrets", 1)[0]
if re.search(r"\bSecItem\w+\(", legacy.replace("SecItemDelete(q", "")) or "NSUbiquitousKeyValueStore.default" in legacy:
    bad.append("Keychain.swift: SecItem/iCloud alleen in LegacySecrets (de eenmalige overzetting)")
if bad:
    print("Sleutelhanger/iCloud buiten de overzetting:", *bad, sep="\n  "); sys.exit(1)
print("Geen sleutelhanger of iCloud buiten de eenmalige overzetting")
