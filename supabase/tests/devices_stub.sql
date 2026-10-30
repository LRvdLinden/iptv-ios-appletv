-- Minimale nabootsing van Supabase voor devices_test.sh (build 157): rollen, auth.users, auth.sessions en de tabellen
-- waar het blok "unittest devices157" uit schema.sql naar verwijst. Alleen voor de unittests; nooit tegen de echte database.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create table auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade);
create table public.account_devices (
  user_id uuid not null references auth.users(id) on delete cascade, device_id text not null, name text not null default '',
  platform text not null default '', session_id uuid, created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(), primary key (user_id, device_id)
);
create table public.account_streams (user_id uuid not null, device_id text not null, primary key (user_id, device_id));
create table public.account_plans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free', max_streams int, max_devices int
);
