-- Minimale nabootsing van Supabase voor recap_test.sh (rollen, auth.users, streams, statistieken, abonnementen, land en de
-- nieuwsbrief-instellingen). Alleen voor de unittests; nooit tegen de echte database draaien. Geen echte gegevens.
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
  email_opt_out boolean not null default false, newsletter_opt_out boolean not null default false, updated_at timestamptz not null default now()
);
create or replace function public.bingr_news_subscribed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users u
    where u.id = p_user and u.email is not null and u.email_confirmed_at is not null and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now())
      and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and (p.email_opt_out or p.newsletter_opt_out)));
$$;
create table public.account_streams (
  user_id uuid not null, device_id text not null, title text, tz text, stat_kind text, stat_key text,
  last_ping timestamptz not null default now(), primary key (user_id, device_id)
);
create table public.account_watch_stats (
  user_id uuid not null references auth.users(id) on delete cascade, profile_id text not null default '', profile_name text,
  day date not null, kind text not null, item_key text not null, title text, episodes text[] not null default '{}',
  minutes numeric not null default 0, plays int not null default 0, updated_at timestamptz not null default now(),
  primary key (user_id, profile_id, day, kind, item_key)
);
create table public.bingr_migrations (name text primary key, done_at timestamptz not null default now());
create table public.account_country (user_id uuid primary key references auth.users(id) on delete cascade, country text not null);
create table public.account_plans (user_id uuid primary key references auth.users(id) on delete cascade, plan text not null default 'free');
create table public.newsletter_settings (id int primary key default 1, enabled boolean not null default false);
insert into public.newsletter_settings (id) values (1);
