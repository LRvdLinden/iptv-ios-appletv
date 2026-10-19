-- Minimale nabootsing van Supabase (rollen, auth.users en de tabellen waar het blok naar verwijst) voor
-- signup_guard_test.sh. Alleen voor de unittests; nooit tegen de echte database draaien.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'supabase_auth_admin'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  created_at         timestamptz not null default now(),
  last_sign_in_at    timestamptz,
  invited_at         timestamptz,
  raw_user_meta_data jsonb
);
create table public.app_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now());
create table public.account_plans (user_id uuid primary key references auth.users(id) on delete cascade, plan text not null default 'free');
create table public.billing_purchases (id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade);
create table public.account_blocks (id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade);
create table public.support_tickets (id bigint generated always as identity primary key, user_id uuid references auth.users(id) on delete set null);
create table public.account_data (user_id uuid primary key references auth.users(id) on delete cascade, profiles jsonb);
create table public.account_devices (id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade);
