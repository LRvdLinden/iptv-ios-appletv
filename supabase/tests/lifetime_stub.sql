-- Minimale nabootsing van Supabase (rollen, auth.users, auth.uid(), app_settings, account_plans en account_blocks) voor
-- lifetime_test.sh (build 167). Alleen voor de unittests; nooit tegen de echte database draaien. Geen echte gegevens
-- (example.invalid).
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
grant usage on schema auth to authenticated;
create table auth.users (
  id uuid primary key default gen_random_uuid(), email text, created_at timestamptz not null default now(),
  email_confirmed_at timestamptz, banned_until timestamptz, deleted_at timestamptz, raw_user_meta_data jsonb not null default '{}'::jsonb
);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
grant execute on function auth.uid() to authenticated;
create table public.app_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now());
insert into public.app_settings (key, value) values ('upgrade_link', '{"apple": false, "android": true, "androidtv": true, "tizen": true, "web": true}');
create table public.account_plans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'lifetime')),
  max_streams int, max_devices int,
  source text check (source is null or source in ('legacy', 'admin', 'purchase')),
  note text, granted_by text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.account_blocks (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, reason text not null,
  until timestamptz, created_at timestamptz not null default now(), lifted_at timestamptz
);
