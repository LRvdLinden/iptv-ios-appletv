#!/usr/bin/env bash
# Unittests van de inlogbescherming per account: het blok "unittest password-guard" uit supabase/schema.sql in een lege,
# tijdelijke database met een nabootsing van Supabase (signup_guard_stub.sql: rollen en auth.users), daarna
# password_guard_test.sql. Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_pw_$$"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
awk '$0 == "-- >>> unittest password-guard" {on=1} on {print} $0 == "-- <<< unittest password-guard" {on=0}' supabase/schema.sql > "$blocks"
grep -q -- "-- <<< unittest password-guard" "$blocks" || { echo "blok unittest password-guard niet gevonden in supabase/schema.sql"; exit 1; }
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/signup_guard_stub.sql
# twee keer: het schema moet herhaalbaar zijn (elke deploy draait het opnieuw)
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/password_guard_test.sql
echo "inlogbescherming: alle unittests geslaagd"
