#!/usr/bin/env bash
# Unittests van de eigen mailing vanuit het beheer: het blok "unittest mailing" uit supabase/schema.sql in een lege,
# tijdelijke database met een nabootsing van Supabase (mailing_stub.sql), twee keer (herhaalbaar), daarna mailing_test.sql
# (doelgroep: opt-out, geblokkeerd, onbevestigd, verwijderd, taal; idempotent aanmaken; wachtrij; annuleren).
# Nodig: psql en een Postgres (14+) waarop een database aangemaakt mag worden. Verbinding via de gewone PG*-variabelen.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_mailtest_$$"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
awk '$0 == "-- >>> unittest mailing" {on=1} on {print} $0 == "-- <<< unittest mailing" {on=0}' supabase/schema.sql > "$blocks"
grep -q -- "-- <<< unittest mailing" "$blocks" || { echo "blok unittest mailing niet gevonden in supabase/schema.sql"; exit 1; }
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/mailing_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/mailing_test.sql
echo "eigen mailing: alle unittests geslaagd"
