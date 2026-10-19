-- Minimale nabootsing van Supabase (rollen, auth.users, account_email_prefs) voor mailing_test.sh. Alleen voor de
-- unittests; nooit tegen de echte database draaien. Geen echte gegevens (example.invalid).
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz, deleted_at timestamptz,
  banned_until timestamptz, raw_user_meta_data jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create table public.account_email_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email_opt_out boolean not null default false,
  newsletter_opt_out boolean not null default false,
  updated_at timestamptz not null default now()
);
