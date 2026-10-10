#!/usr/bin/env python3
"""Bouwt app-sleutels uit GitHub Secrets in Secrets.swift (alleen gebruikt als de repo privé is)."""
import os, pathlib, re
p = pathlib.Path(__file__).resolve().parent.parent / "Shared/Config/Secrets.swift"
s = p.read_text()
env = {"traktClientID": "TRAKT_CLIENT_ID", "traktClientSecret": "TRAKT_CLIENT_SECRET",
       "openSubtitlesAPIKey": "OPENSUBTITLES_API_KEY", "omdbAPIKey": "OMDB_API_KEY", "tmdbAPIKey": "TMDB_API_KEY"}
n = 0
for key, var in env.items():
    v = os.environ.get(var, "").strip()
    if v:
        s, c = re.subn(rf'(\.{key}: )"[^"]*"', lambda m: m.group(1) + '"' + v.replace('"', '') + '"', s)
        n += c
p.write_text(s)
print(f"{n} sleutel(s) ingebouwd")
