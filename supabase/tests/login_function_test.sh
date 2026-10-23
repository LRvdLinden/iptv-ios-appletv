#!/usr/bin/env bash
# Unittests van inloggen via de functie login (build 141): de limieten (rate_limits/bingr_rate_hit), het blok
# "unittest password-guard" en het blok "unittest login-function" uit supabase/schema.sql in een lege, tijdelijke database
# met een nabootsing van Supabase (signup_guard_stub.sql), daarna login_function_test.sql.
# Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_unittest_login_$$"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
awk '$0 == "create table if not exists public.rate_limits (" {on=1} on {print} $0 == "grant execute on function public.bingr_rate_hit(text, int, int) to service_role;" {on=0}' supabase/schema.sql > "$blocks"
grep -q "function public.bingr_rate_hit(p_key text" "$blocks" || { echo "bingr_rate_hit niet gevonden in supabase/schema.sql"; exit 1; }
for b in password-guard login-function; do
  awk -v b="$b" '$0 == "-- >>> unittest " b {on=1} on {print} $0 == "-- <<< unittest " b {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $b" "$blocks" || { echo "blok unittest $b niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/signup_guard_stub.sql
# twee keer: het schema moet herhaalbaar zijn (elke deploy draait het opnieuw)
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/login_function_test.sql
echo "inloggen via de functie login: alle unittests geslaagd"
