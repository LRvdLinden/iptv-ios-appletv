#!/usr/bin/env bash
# Unittests van build 157 (apparatenlimiet Gratis direct afdwingen): het blok "unittest devices157" uit supabase/schema.sql
# in een lege, tijdelijke database met een nabootsing van Supabase (devices_stub.sql), daarna devices_test.sql.
# Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_dev_$$"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
awk '$0 == "-- >>> unittest devices157" {on=1} on {print} $0 == "-- <<< unittest devices157" {on=0}' supabase/schema.sql > "$blocks"
grep -q -- "-- <<< unittest devices157" "$blocks" || { echo "blok unittest devices157 niet gevonden in supabase/schema.sql"; exit 1; }
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/devices_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"   # twee keer: herhaalbaar
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/devices_test.sql
echo "build 157 (apparatenlimiet Gratis): alle unittests geslaagd"
