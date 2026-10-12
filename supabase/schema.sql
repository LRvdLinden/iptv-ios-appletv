-- Bingr-accounts: tabel voor tv-koppelcodes (QR-login op Apple TV, Android TV en Fire TV).
-- Alleen de Edge Function (service role) leest en schrijft hierin; RLS zonder policies houdt alle anderen buiten.
create table if not exists public.device_codes (
  code        text primary key,
  poll_secret text not null,
  device      text,
  user_id     uuid references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
alter table public.device_codes enable row level security;
revoke all on public.device_codes from anon, authenticated;
create index if not exists device_codes_expires_idx on public.device_codes (expires_at);

-- Profielen per account (migratie van bestaande profielen + delen tussen iOS, tvOS, macOS en Android).
-- Eén rij per account; `profiles` is een JSON-lijst (zie docs/ACCOUNT.md). Pincodes en eigen foto's gaan hier niet in.
create table if not exists public.account_data (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  profiles   jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.account_data enable row level security;
drop policy if exists "eigen gegevens lezen" on public.account_data;
drop policy if exists "eigen gegevens schrijven" on public.account_data;
drop policy if exists "eigen gegevens wijzigen" on public.account_data;
create policy "eigen gegevens lezen"    on public.account_data for select to authenticated using (user_id = auth.uid());
create policy "eigen gegevens schrijven" on public.account_data for insert to authenticated with check (user_id = auth.uid());
create policy "eigen gegevens wijzigen" on public.account_data for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.account_data to authenticated;

-- Gekoppelde apparaten per account (max. 10). Alleen de Edge Function (service role) schrijft hierin.
create table if not exists public.account_devices (
  user_id      uuid not null references auth.users(id) on delete cascade,
  device_id    text not null,
  name         text not null default '',
  platform     text not null default '',
  session_id   uuid,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.account_devices enable row level security;
revoke all on public.account_devices from anon, authenticated;

-- Sessie van een verwijderd apparaat intrekken (refresh tokens vervallen mee), zodat het apparaat uitlogt.
create or replace function public.revoke_session(sid uuid) returns void
language sql security definer set search_path = auth, public as $$
  delete from auth.sessions where id = sid;
$$;
revoke all on function public.revoke_session(uuid) from public, anon, authenticated;
grant execute on function public.revoke_session(uuid) to service_role;

-- Profielfoto's per account: privé-bucket "avatars", pad <user_id>/<profiel_id>.jpg; alleen de eigenaar kan erbij.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];
drop policy if exists "avatars eigen lezen" on storage.objects;
drop policy if exists "avatars eigen toevoegen" on storage.objects;
drop policy if exists "avatars eigen wijzigen" on storage.objects;
drop policy if exists "avatars eigen verwijderen" on storage.objects;
create policy "avatars eigen lezen" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars eigen toevoegen" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars eigen wijzigen" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars eigen verwijderen" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Servers en afspeellijsten per account, versleuteld (AES-GCM) door de Edge Function met BINGR_SOURCES_KEY.
-- Alleen de Edge Function (service role) leest en schrijft hierin.
create table if not exists public.account_sources (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       text not null,
  updated_at timestamptz not null default now()
);
alter table public.account_sources enable row level security;
revoke all on public.account_sources from anon, authenticated;

-- Overige accountgegevens per onderdeel (koppelingen, instellingen, gegevens per profiel, herinneringen), versleuteld door de Edge Function.
create table if not exists public.account_state (
  user_id    uuid not null references auth.users(id) on delete cascade,
  section    text not null,
  data       text not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, section)
);
alter table public.account_state enable row level security;
revoke all on public.account_state from anon, authenticated;
