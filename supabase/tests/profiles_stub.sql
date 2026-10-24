-- Minimale nabootsing van Supabase voor profiles_test.sh (build 146): rollen, auth.users/auth.uid(), app_settings en de
-- tabellen waar de blokken "unittest profiles", "unittest stats-item" en "unittest stats-seal" naar verwijzen, met RLS
-- zoals in schema.sql. Alleen voor de unittests; nooit tegen de echte database draaien.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
grant usage on schema auth to authenticated, anon, service_role;
grant usage on schema public to authenticated, anon, service_role;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'sub', '')::uuid $$;
grant execute on function auth.uid() to authenticated, anon;
create table public.app_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now());
alter table public.app_settings enable row level security;
create table public.account_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  profiles jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.account_data enable row level security;
create policy "eigen gegevens lezen"    on public.account_data for select to authenticated using (user_id = (select auth.uid()));
create policy "eigen gegevens schrijven" on public.account_data for insert to authenticated with check (user_id = (select auth.uid()));
create policy "eigen gegevens wijzigen" on public.account_data for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert, update on public.account_data to authenticated;
grant all on public.account_data to service_role;
create table public.account_devices (user_id uuid not null references auth.users(id) on delete cascade, device_id text not null,
  app_version text, primary key (user_id, device_id));
create table public.account_watch_stats (
  user_id uuid not null references auth.users(id) on delete cascade, profile_id text not null default '', profile_name text,
  day date not null, kind text not null, item_key text not null, title text, episodes text[] not null default '{}',
  minutes numeric not null default 0, plays int not null default 0, updated_at timestamptz not null default now(),
  primary key (user_id, profile_id, day, kind, item_key));
