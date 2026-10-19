#!/usr/bin/env bash
# Unittests van de registratiebescherming (build 134): de blokken "unittest person-name" en "unittest signup-guard" uit
# supabase/schema.sql in een lege, tijdelijke database met een nabootsing van Supabase (signup_guard_stub.sql), daarna
# signup_guard_test.sql. Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
# Verbinding via de gewone PG*-omgevingsvariabelen (bv. PGHOST, PGUSER); de database heet bingr_unittest_<pid>.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_$$"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
for name in person-name signup-guard; do
  awk -v n="$name" '$0 == "-- >>> unittest " n {on=1} on {print} $0 == "-- <<< unittest " n {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $name" "$blocks" || { echo "blok unittest $name niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/signup_guard_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
# twee keer: het schema moet herhaalbaar zijn (elke deploy draait het opnieuw). Daartussen de check op signup_attempts.reason
# terug naar die van vóór build 138 (zonder honeypot/too_fast): de tweede ronde moet hem bijwerken.
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "alter table public.signup_attempts drop constraint signup_attempts_reason_check;
  alter table public.signup_attempts add constraint signup_attempts_reason_check check (reason is null or reason in ('rate_limit', 'disposable', 'name'))"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/signup_guard_test.sql
echo "registratiebescherming: alle unittests geslaagd"
