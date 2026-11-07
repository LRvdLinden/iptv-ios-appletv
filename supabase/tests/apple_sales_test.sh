#!/usr/bin/env bash
# Unittests van de Apple-omzet (App Store Connect, functie apple-sales): de blokken "unittest insights-bin", "unittest
# billing" en "unittest apple-sales" uit supabase/schema.sql in een lege, tijdelijke database met de nabootsing van Supabase
# uit lifetime_stub.sql, twee keer (herhaalbaar), daarna apple_sales_test.sql. Alleen verzonnen rapportregels.
# Nodig: psql en een Postgres (14+); verbinding via de PG*-omgevingsvariabelen.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_applesalestest_$$"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
for name in insights-bin billing apple-sales; do
  awk -v n="$name" '$0 == "-- >>> unittest " n {on=1} on {print} $0 == "-- <<< unittest " n {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $name" "$blocks" || { echo "blok unittest $name niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/lifetime_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/apple_sales_test.sql
echo "Apple-omzet (App Store Connect): alle unittests geslaagd"
