#!/usr/bin/env bash
# Unittests van build 171 (crashrapporten en "Stoppen op dat apparaat"): het blok "unittest crash" uit supabase/schema.sql in
# een lege, tijdelijke database met een nabootsing van Supabase (crash_stub.sql), twee keer (herhaalbaar), daarna
# crash_test.sql. Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_crash_$$"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
awk '$0 == "-- >>> unittest crash" {on=1} on {print} $0 == "-- <<< unittest crash" {on=0}' supabase/schema.sql > "$blocks"
grep -q -- "-- <<< unittest crash" "$blocks" || { echo "blok unittest crash niet gevonden in supabase/schema.sql"; exit 1; }
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/crash_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"   # twee keer: herhaalbaar
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/crash_test.sql
echo "build 171 (crashrapporten, stoppen op een ander apparaat): alle unittests geslaagd"
