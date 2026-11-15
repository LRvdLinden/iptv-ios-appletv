-- Minimale nabootsing van Supabase voor crash_test.sh (build 171): rollen en auth.users (voor account_stream_stops).
-- Alleen voor de unittests; nooit tegen de echte database draaien. Geen echte gegevens.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
