#!/usr/bin/env bash
# Unittests van de bewaarplicht van aankopen: de blokken "unittest billing" en "unittest insights-bin" uit
# supabase/schema.sql in een lege, tijdelijke database met een nabootsing van Supabase (billing_stub.sql, met de oude
# tabel om de migratie te testen), twee keer (herhaalbaar), daarna billing_test.sql. Nodig: psql en een Postgres (14+)
# waarop een database aangemaakt mag worden. Verbinding via de gewone PG*-omgevingsvariabelen.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_billtest_$$"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
for name in insights-bin billing; do
  awk -v n="$name" '$0 == "-- >>> unittest " n {on=1} on {print} $0 == "-- <<< unittest " n {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $name" "$blocks" || { echo "blok unittest $name niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/billing_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/billing_test.sql
echo "bewaarplicht aankopen: alle unittests geslaagd"
