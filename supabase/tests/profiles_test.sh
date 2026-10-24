#!/usr/bin/env bash
# Unittests van build 146 (alles versleuteld): de blokken "unittest profiles", "unittest stats-item" en "unittest stats-seal"
# uit supabase/schema.sql in een lege, tijdelijke database met een nabootsing van Supabase (profiles_stub.sql), daarna
# profiles_test.sql. Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_$$"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
for name in profiles stats-item stats-seal; do
  awk -v n="$name" '$0 == "-- >>> unittest " n {on=1} on {print} $0 == "-- <<< unittest " n {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $name" "$blocks" || { echo "blok unittest $name niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/profiles_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"   # twee keer: herhaalbaar (elke deploy draait het schema opnieuw)
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/profiles_test.sql
echo "build 146 (profielen, statistieken): alle unittests geslaagd"
