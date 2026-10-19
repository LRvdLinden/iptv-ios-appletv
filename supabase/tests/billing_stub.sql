-- Minimale nabootsing van Supabase (rollen, auth.users, auth.uid() en app_settings) voor billing_test.sh, met
-- billing_purchases zoals vóór de bewaarplicht (user_id not null, on delete cascade) om de migratie te testen.
-- Alleen voor de unittests; nooit tegen de echte database draaien. Geen echte gegevens (example.invalid).
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema auth;
grant usage on schema auth to authenticated;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz not null default now());
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
grant execute on function auth.uid() to authenticated;
create table public.app_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now());
-- oude vorm (build 133)
create table public.billing_purchases (
  id                bigint generated always as identity primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  stripe_session_id text not null unique check (stripe_session_id ~ '^cs_[A-Za-z0-9_]+$' and char_length(stripe_session_id) <= 255),
  payment_intent    text check (payment_intent is null or (payment_intent ~ '^pi_[A-Za-z0-9_]+$' and char_length(payment_intent) <= 255)),
  amount            int not null check (amount >= 0),
  currency          text not null default 'eur' check (currency ~ '^[a-z]{3}$'),
  status            text not null check (status in ('pending', 'paid', 'failed', 'refunded', 'disputed')),
  paid_at           timestamptz,
  refunded_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
-- een aankoop van vóór de migratie
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000000a', 'a@example.invalid');
insert into public.billing_purchases (user_id, stripe_session_id, payment_intent, amount, status, paid_at)
values ('00000000-0000-4000-8000-00000000000a', 'cs_test_old', 'pi_old', 499, 'paid', now() - interval '2 days');
