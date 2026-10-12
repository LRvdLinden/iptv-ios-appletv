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

-- Eigen apparaatnaam (build 45): een zelfgekozen naam wordt niet meer overschreven bij het registreren.
alter table public.account_devices add column if not exists custom_name boolean not null default false;

-- Build 51: wie kijkt er nu (max. 6 tegelijk) en kijkgeschiedenis van het account (7 dagen).
alter table public.account_devices add column if not exists signed_in_at timestamptz;
create table if not exists public.account_streams (
  user_id      uuid not null references auth.users(id) on delete cascade,
  device_id    text not null,
  profile_id   text,
  profile_name text,
  title        text,
  kind         text,
  content_id   text,
  log_id       bigint,
  started_at   timestamptz not null default now(),
  last_ping    timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.account_streams enable row level security;
revoke all on public.account_streams from anon, authenticated;
create table if not exists public.account_watch_log (
  id           bigserial primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  device_id    text,
  device_name  text,
  platform     text,
  profile_id   text,
  profile_name text,
  title        text,
  kind         text,
  content_id   text,
  started_at   timestamptz not null default now(),
  ended_at     timestamptz not null default now()
);
create index if not exists account_watch_log_user_idx on public.account_watch_log (user_id, started_at desc);
alter table public.account_watch_log enable row level security;
revoke all on public.account_watch_log from anon, authenticated;

-- Wachtwoord gewijzigd: overal uitloggen. Alle sessies vervallen en alle gekoppelde apparaten worden ontkoppeld;
-- de apps zien bij hun volgende controle (heartbeat) dat ze verwijderd zijn en gaan naar het inlogscherm.
create or replace function public.bingr_on_password_change() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    delete from auth.sessions where user_id = new.id;
    delete from public.account_devices where user_id = new.id;
    delete from public.account_streams where user_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists bingr_password_change on auth.users;
create trigger bingr_password_change after update of encrypted_password on auth.users
  for each row execute function public.bingr_on_password_change();

-- Build 60: limieten atomair (gelijktijdige aanvragen kunnen de grens niet meer overschrijden), opruimen en groottegrenzen.
-- Alle functies hieronder zijn alleen voor de Edge Function (service role).
create index if not exists account_watch_log_started_idx on public.account_watch_log (started_at);
create index if not exists account_streams_ping_idx on public.account_streams (last_ping);

-- Profielenlijst begrenzen (512 KB); not valid = bestaande rijen worden niet opnieuw gecontroleerd.
alter table public.account_data drop constraint if exists account_data_profiles_size;
alter table public.account_data add constraint account_data_profiles_size check (octet_length(profiles::text) <= 524288) not valid;

-- Apparaat registreren met een slot per account: tellen + toevoegen gebeurt in één transactie.
create or replace function public.bingr_register_device(p_user uuid, p_device text, p_name text, p_platform text, p_session uuid, p_limit int)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare cur record; n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('bingr.devices:' || p_user::text, 0));
  select session_id, custom_name into cur from public.account_devices where user_id = p_user and device_id = p_device;
  if not found then
    select count(*) into n from public.account_devices where user_id = p_user;
    if n >= p_limit then return jsonb_build_object('ok', false, 'error', 'device_limit'); end if;
    insert into public.account_devices (user_id, device_id, name, platform, session_id, signed_in_at)
    values (p_user, p_device, p_name, p_platform, p_session, now());
    return jsonb_build_object('ok', true);
  end if;
  -- zelfde apparaat opnieuw ingelogd: oude sessie intrekken als die anders is
  if cur.session_id is not null and p_session is not null and cur.session_id <> p_session then
    delete from auth.sessions where id = cur.session_id;
  end if;
  update public.account_devices set
    platform = p_platform,
    session_id = coalesce(p_session, session_id),
    last_seen_at = now(),
    signed_in_at = case when p_session is not null and cur.session_id is distinct from p_session then now() else signed_in_at end,
    name = case when custom_name then name else p_name end
  where user_id = p_user and device_id = p_device;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.bingr_register_device(uuid, text, text, text, uuid, int) from public, anon, authenticated;
grant execute on function public.bingr_register_device(uuid, text, text, text, uuid, int) to service_role;

-- Stream starten met een slot per account: verlopen streams weg, tellen, geschiedenis en stream in één transactie.
create or replace function public.bingr_stream_start(p_user uuid, p_device text, p_profile_id text, p_profile_name text,
  p_title text, p_kind text, p_content_id text, p_limit int, p_ttl_seconds int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int; old_log bigint; dev_name text; dev_platform text; new_log bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('bingr.streams:' || p_user::text, 0));
  delete from public.account_streams where user_id = p_user and last_ping < now() - make_interval(secs => p_ttl_seconds);
  select count(*) into n from public.account_streams where user_id = p_user and device_id <> p_device;
  if n >= p_limit then return jsonb_build_object('ok', false, 'error', 'stream_limit'); end if;
  -- lopende stream op dit apparaat afsluiten in de geschiedenis
  select log_id into old_log from public.account_streams where user_id = p_user and device_id = p_device;
  if old_log is not null then update public.account_watch_log set ended_at = now() where id = old_log and user_id = p_user; end if;
  select name, platform into dev_name, dev_platform from public.account_devices where user_id = p_user and device_id = p_device;
  insert into public.account_watch_log (user_id, device_id, device_name, platform, profile_id, profile_name, title, kind, content_id)
  values (p_user, p_device, dev_name, dev_platform, p_profile_id, p_profile_name, p_title, p_kind, p_content_id)
  returning id into new_log;
  insert into public.account_streams (user_id, device_id, profile_id, profile_name, title, kind, content_id, log_id, started_at, last_ping)
  values (p_user, p_device, p_profile_id, p_profile_name, p_title, p_kind, p_content_id, new_log, now(), now())
  on conflict (user_id, device_id) do update set profile_id = excluded.profile_id, profile_name = excluded.profile_name,
    title = excluded.title, kind = excluded.kind, content_id = excluded.content_id, log_id = excluded.log_id,
    started_at = excluded.started_at, last_ping = excluded.last_ping;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.bingr_stream_start(uuid, text, text, text, text, text, text, int, int) from public, anon, authenticated;
grant execute on function public.bingr_stream_start(uuid, text, text, text, text, text, text, int, int) to service_role;

-- Opruimen voor alle accounts: verlopen tv-codes, streams zonder ping (> 1 dag) en kijkgeschiedenis ouder dan 8 dagen.
create or replace function public.bingr_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.device_codes where expires_at < now();
  delete from public.account_streams where last_ping < now() - interval '1 day';
  delete from public.account_watch_log where started_at < now() - interval '8 days';
$$;
revoke all on function public.bingr_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_cleanup() to service_role;
