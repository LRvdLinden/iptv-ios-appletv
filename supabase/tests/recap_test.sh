#!/usr/bin/env bash
# Unittests van de maandaggregatie (watch_month) en de wachtrij van de maandrecap: de blokken "unittest watch-month" en
# "unittest recap" uit supabase/schema.sql in een lege, tijdelijke database met een nabootsing van Supabase (recap_stub.sql),
# twee keer (herhaalbaar), daarna recap_test.sql (een serie met afleveringen, films, live tv, statistieken wissen, 13 maanden,
# één keer per account en maand, opnieuw proberen, afmelden, alleen Lifetime: Gratis = geen aggregatie en geen mail, upgrade vult 8 dagen aan). Verbinding via de gewone PG*-variabelen.
set -euo pipefail
cd "$(dirname "$0")/../.."
db="bingr_recaptest_$$"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database $db" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1 || true' EXIT
blocks=$(mktemp)
for b in watch-month recap; do
  awk -v b="$b" '$0 == "-- >>> unittest " b {on=1} on {print} $0 == "-- <<< unittest " b {on=0}' supabase/schema.sql >> "$blocks"
  grep -q -- "-- <<< unittest $b" "$blocks" || { echo "blok unittest $b niet gevonden in supabase/schema.sql"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f supabase/tests/recap_stub.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f "$blocks"
rm -f "$blocks"
psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -d "$db" -f supabase/tests/recap_test.sql
echo "maandrecap: alle unittests geslaagd"
