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

-- build 95: groottegrens voor account_data als trigger (de apps schrijven hier rechtstreeks via PostgREST/RLS). Geldt ook
-- voor jsonb-kolommen die er later bij komen: profiles max. 512 KB, elke andere JSON-waarde (object/lijst) max. 2 MB,
-- de hele rij max. 8 MB. Te groot -> fout 54000 "account_data_too_large". Idempotent (create or replace + drop trigger).
create or replace function public.bingr_account_data_size() returns trigger
language plpgsql set search_path = public as $$
declare row_j jsonb := to_jsonb(new); k text; v jsonb; lim int;
begin
  if octet_length(row_j::text) > 8 * 1024 * 1024 then
    raise exception 'account_data_too_large' using errcode = '54000', detail = 'row > 8 MB';
  end if;
  for k, v in select * from jsonb_each(row_j) loop
    lim := 2 * 1024 * 1024;
    if k = 'profiles' then lim := 512 * 1024; end if;
    if jsonb_typeof(v) in ('object', 'array') and octet_length(v::text) > lim then
      raise exception 'account_data_too_large' using errcode = '54000', detail = k;
    end if;
  end loop;
  return new;
end $$;
revoke all on function public.bingr_account_data_size() from public, anon, authenticated;
drop trigger if exists bingr_account_data_size on public.account_data;
create trigger bingr_account_data_size before insert or update on public.account_data
  for each row execute function public.bingr_account_data_size();

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

-- Build 62: appversie per apparaat, berichten, webproxy-limiet en beheer.
alter table public.account_devices add column if not exists app_version text;
alter table public.account_devices add column if not exists os_version text;

-- Eén rij per account per dag dat het account actief was (register_device/heartbeat); voor de statistieken.
create table if not exists public.account_logins (
  user_id uuid not null references auth.users(id) on delete cascade,
  day     date not null default (now() at time zone 'utc')::date,
  primary key (user_id, day)
);
create index if not exists account_logins_day_idx on public.account_logins (day);
alter table public.account_logins enable row level security;
revoke all on public.account_logins from anon, authenticated;

-- Register_device krijgt app_version/os_version (oude handtekening eerst weg, anders is de aanroep dubbelzinnig).
drop function if exists public.bingr_register_device(uuid, text, text, text, uuid, int);
create or replace function public.bingr_register_device(p_user uuid, p_device text, p_name text, p_platform text, p_session uuid, p_limit int,
  p_app_version text default null, p_os_version text default null)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare cur record; n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('bingr.devices:' || p_user::text, 0));
  insert into public.account_logins (user_id) values (p_user) on conflict do nothing;
  select session_id, custom_name into cur from public.account_devices where user_id = p_user and device_id = p_device;
  if not found then
    select count(*) into n from public.account_devices where user_id = p_user;
    if n >= p_limit then return jsonb_build_object('ok', false, 'error', 'device_limit'); end if;
    insert into public.account_devices (user_id, device_id, name, platform, session_id, signed_in_at, app_version, os_version)
    values (p_user, p_device, p_name, p_platform, p_session, now(), p_app_version, p_os_version);
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
    name = case when custom_name then name else p_name end,
    app_version = coalesce(p_app_version, app_version),
    os_version = coalesce(p_os_version, os_version)
  where user_id = p_user and device_id = p_device;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.bingr_register_device(uuid, text, text, text, uuid, int, text, text) from public, anon, authenticated;
grant execute on function public.bingr_register_device(uuid, text, text, text, uuid, int, text, text) to service_role;

-- Eigen naam bij het koppelen (bingr.online/koppelen): approve bewaart de naam bij de code; bij het goedkeuren (poll) komt hij
-- in device_pending_names en register_device van dat apparaat (zelfde soort, binnen 15 minuten) neemt hem over met
-- custom_name = true. Alleen de functie device-auth (service role) leest en schrijft hierin.
alter table public.device_codes add column if not exists name text;
create table if not exists public.device_pending_names (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null default 'other',
  name       text not null,
  created_at timestamptz not null default now()
);
create index if not exists device_pending_names_user_idx on public.device_pending_names (user_id, kind, created_at);
alter table public.device_pending_names enable row level security;
revoke all on public.device_pending_names from anon, authenticated;

-- Beheer: de tabellen announcements, account_email_prefs, admin_login_attempts en admin_audit en de functies bingr_admin_*
-- horen bij dit gedeelde schema, maar worden gebruikt door de Edge Function admin in de (sinds build 97 openbare) repo LRvdLinden/bingr-beheer
-- (beheer.bingr.online). device-auth leest announcements sinds build 117 niet meer (berichten alleen als pushmelding).
-- Berichten van de beheerder aan alle gebruikers (in de apps één keer getoond; eventueel ook per e-mail).
create table if not exists public.announcements (
  id            uuid primary key default gen_random_uuid(),
  title_nl      text not null,
  body_nl       text not null,
  title_en      text not null default '',
  body_en       text not null default '',
  created_at    timestamptz not null default now(),
  expires_at    timestamptz,
  email         boolean not null default false,
  email_total   int not null default 0,
  email_sent    int not null default 0,
  email_failed  int not null default 0,
  email_cursor  uuid,
  email_done_at timestamptz
);
create index if not exists announcements_created_idx on public.announcements (created_at desc);
alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;

-- Afmelden voor e-mails van Bingr (berichten); accountmails (bevestigen, wachtwoord) gaan altijd.
create table if not exists public.account_email_prefs (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  email_opt_out boolean not null default false,
  updated_at    timestamptz not null default now()
);
alter table public.account_email_prefs enable row level security;
revoke all on public.account_email_prefs from anon, authenticated;

-- Beheer: mislukte inlogpogingen per IP en een logboek van acties.
create table if not exists public.admin_login_attempts (
  ip           text primary key,
  failures     int not null default 0,
  window_start timestamptz not null default now(),
  locked_until timestamptz
);
alter table public.admin_login_attempts enable row level security;
revoke all on public.admin_login_attempts from anon, authenticated;
create table if not exists public.admin_audit (
  id          bigserial primary key,
  action      text not null,
  target_user uuid,
  detail      jsonb,
  ip          text,
  created_at  timestamptz not null default now()
);
create index if not exists admin_audit_created_idx on public.admin_audit (created_at desc);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;

-- Beheer: blokkades van accounts (functie admin in bingr-beheer). De inlogblokkade zelf is de ban van het auth-account
-- (banned_until); deze tabel bewaart reden, einddatum en geschiedenis. until = null: onbepaalde tijd. Een blokkade
-- eindigt door opheffen (lifted_by 'beheer'), door een nieuwe blokkade ('vervangen') of vanzelf na until ('verlopen',
-- bijgewerkt bij het lezen). Gaat mee als het account wordt verwijderd.
create table if not exists public.account_blocks (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  reason      text not null,
  until       timestamptz,
  notified    boolean not null default false,
  created_at  timestamptz not null default now(),
  created_by  text not null default 'beheer',
  lifted_at   timestamptz,
  lifted_by   text
);
create index if not exists account_blocks_user_idx on public.account_blocks (user_id, created_at desc);
create index if not exists account_blocks_active_idx on public.account_blocks (user_id) where lifted_at is null;
alter table public.account_blocks enable row level security;
revoke all on public.account_blocks from anon, authenticated;

-- verlopen blokkades afsluiten (lui: bij het lezen in het beheer)
create or replace function public.bingr_blocks_expire() returns void
language sql security definer set search_path = public as $$
  update public.account_blocks set lifted_at = until, lifted_by = 'verlopen'
  where lifted_at is null and until is not null and until <= now();
$$;
-- alle sessies van een account intrekken. NIET gebruiken bij blokkeren (sinds build 83): dan blijven de sessies bestaan,
-- zodat vernieuwen door de ban de fout user_banned geeft en de apps de melding "geblokkeerd" tonen (docs/ACCOUNT.md).
-- Blijft beschikbaar voor het beheer (bijv. alle apparaten uitloggen zonder blokkade).
create or replace function public.bingr_revoke_user_sessions(p_user uuid) returns int
language plpgsql security definer set search_path = auth, public as $$
declare n int;
begin
  delete from auth.sessions where user_id = p_user;
  get diagnostics n = row_count;
  delete from public.account_streams where user_id = p_user;
  return n;
end $$;
revoke all on function public.bingr_blocks_expire() from public, anon, authenticated;
revoke all on function public.bingr_revoke_user_sessions(uuid) from public, anon, authenticated;
grant execute on function public.bingr_blocks_expire() to service_role;
grant execute on function public.bingr_revoke_user_sessions(uuid) to service_role;

-- Tellers voor limieten (webproxy): per sleutel per minuut.
create table if not exists public.rate_limits (
  key    text not null,
  bucket timestamptz not null,
  hits   int not null default 0,
  primary key (key, bucket)
);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;

-- build 95: optioneel venster in seconden (p_window, standaard 60 = per minuut zoals vroeger). De functie support rekende
-- met "per uur" maar telde per minuut. Een venster langer dan een minuut slaat het EINDE van het venster op als bucket:
-- bingr_cleanup ruimt buckets 10 minuten na de bucket-tijd op, zo blijft een lopend uurvenster staan. De oude versie met
-- twee argumenten eerst weg (anders zijn er twee versies en is een aanroep met twee argumenten dubbelzinnig).
drop function if exists public.bingr_rate_hit(text, int);
create or replace function public.bingr_rate_hit(p_key text, p_max int, p_window int default 60) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int; w int := greatest(coalesce(p_window, 60), 1); b timestamptz;
begin
  if w = 60 then b := date_trunc('minute', now());
  else b := to_timestamp(floor(extract(epoch from now()) / w) * w + case when w > 60 then w else 0 end);
  end if;
  insert into public.rate_limits (key, bucket, hits) values (p_key, b, 1)
  on conflict (key, bucket) do update set hits = public.rate_limits.hits + 1
  returning hits into n;
  return n <= p_max;
end $$;
revoke all on function public.bingr_rate_hit(text, int, int) from public, anon, authenticated;
grant execute on function public.bingr_rate_hit(text, int, int) to service_role;

-- Security M1/L6: gebruik van de web-proxy per account (aanvragen en bytes per uur), in de database zodat de limiet geldt
-- over alle instanties van de functie heen. De functie web-proxy telt in het geheugen en schrijft in porties
-- (bingr_proxy_usage); terug: aanvragen in het huidige uur en bytes in de laatste 24 uur. Oude rijen van dat account
-- (> 2 dagen) gaan meteen weg. Limieten en noodrem: app_settings.proxy_limits (zie web-proxy/policy.ts).
create table if not exists public.proxy_usage (
  user_id  uuid not null references auth.users(id) on delete cascade,
  bucket   timestamptz not null,
  requests int not null default 0,
  bytes    bigint not null default 0,
  primary key (user_id, bucket)
);
alter table public.proxy_usage enable row level security;
revoke all on public.proxy_usage from anon, authenticated;
create or replace function public.bingr_proxy_usage(p_user uuid, p_requests int, p_bytes bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b timestamptz := date_trunc('hour', now()); r int; nb bigint;
begin
  if p_user is null then return null; end if;
  insert into public.proxy_usage (user_id, bucket, requests, bytes)
  values (p_user, b, greatest(coalesce(p_requests, 0), 0), greatest(coalesce(p_bytes, 0), 0))
  on conflict (user_id, bucket) do update
    set requests = public.proxy_usage.requests + excluded.requests, bytes = public.proxy_usage.bytes + excluded.bytes
  returning requests into r;
  select coalesce(sum(bytes), 0) into nb from public.proxy_usage where user_id = p_user and bucket > b - interval '24 hours';
  delete from public.proxy_usage where user_id = p_user and bucket < b - interval '2 days';
  return jsonb_build_object('requests_hour', r, 'bytes_day', nb);
end $$;
revoke all on function public.bingr_proxy_usage(uuid, int, bigint) from public, anon, authenticated;
grant execute on function public.bingr_proxy_usage(uuid, int, bigint) to service_role;

-- build 95: globale teller voor beheer-inlogpogingen (alle IP's samen), los van de teller per IP. Elke poging is een
-- rij; die wordt nooit teruggezet als een IP geblokkeerd raakt (vroeger zette dat failures op 0, waardoor een geblokkeerd
-- IP niet meer meetelde voor de globale grens). Meer dan 60 pogingen in een uur = alles 15 min dicht (admin_login_lock).
create table if not exists public.admin_login_events (
  id         bigserial primary key,
  ip         text not null,
  created_at timestamptz not null default now()
);
create index if not exists admin_login_events_created_idx on public.admin_login_events (created_at);
alter table public.admin_login_events enable row level security;
revoke all on public.admin_login_events from anon, authenticated;
-- build 95: één rij (id = 1) met de globale blokkade; ook het slot waarop alle pogingen na elkaar gaan (for update)
create table if not exists public.admin_login_lock (
  id           int primary key default 1 check (id = 1),
  locked_until timestamptz
);
alter table public.admin_login_lock enable row level security;
revoke all on public.admin_login_lock from anon, authenticated;
insert into public.admin_login_lock (id) values (1) on conflict do nothing;

-- build 95: één atomaire stap vóór de wachtwoordcontrole. Telt de poging alvast als fout (per IP en globaal) en zegt of
-- hij door mag; gelukt daarna = bingr_admin_result(ip, true) zet het IP terug. Alle pogingen gaan via de rij in
-- admin_login_lock na elkaar, dus parallelle verzoeken kunnen de grenzen niet omzeilen.
-- Per IP: 5 pogingen per 15 min; de 5e zet de blokkade van 15 min meteen (gaat die 5e goed, dan vervalt hij weer).
-- Globaal: meer dan 60 pogingen in het laatste uur (sinds het einde van de vorige globale blokkade) = alles 15 min dicht.
create or replace function public.bingr_admin_attempt(p_ip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g timestamptz; r public.admin_login_attempts%rowtype; total int;
begin
  insert into public.admin_login_lock (id) values (1) on conflict do nothing;
  select locked_until into g from public.admin_login_lock where id = 1 for update;
  if g is not null and g > now() then
    return jsonb_build_object('allowed', false, 'locked', true, 'retry_after', ceil(extract(epoch from g - now())));
  end if;
  insert into public.admin_login_attempts (ip, failures, window_start) values (p_ip, 0, now()) on conflict (ip) do nothing;
  select * into r from public.admin_login_attempts where ip = p_ip for update;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('allowed', false, 'locked', true, 'retry_after', ceil(extract(epoch from r.locked_until - now())));
  end if;
  if r.window_start < now() - interval '15 minutes' or r.locked_until is not null then
    r.failures := 0; r.window_start := now();
  end if;
  delete from public.admin_login_events where created_at < now() - interval '1 day';
  select count(*) into total from public.admin_login_events
  where created_at > greatest(now() - interval '1 hour', coalesce(g, '-infinity'::timestamptz));
  if total >= 60 then
    update public.admin_login_lock set locked_until = now() + interval '15 minutes' where id = 1;
    return jsonb_build_object('allowed', false, 'locked', true, 'retry_after', 900);
  end if;
  insert into public.admin_login_events (ip) values (p_ip);
  update public.admin_login_attempts set failures = r.failures + 1, window_start = r.window_start,
    locked_until = case when r.failures + 1 >= 5 then now() + interval '15 minutes' else null end
  where ip = p_ip;
  return jsonb_build_object('allowed', true, 'locked', false);
end $$;
revoke all on function public.bingr_admin_attempt(text) from public, anon, authenticated;
grant execute on function public.bingr_admin_attempt(text) to service_role;

-- Beheer-login: is dit IP (of alles samen, bij een aanval van veel IP's) geblokkeerd?
-- build 95: alleen nog voor een oudere functie `admin`; de nieuwe gebruikt bingr_admin_attempt. Kijkt nu ook naar de
-- globale blokkade en de globale teller (admin_login_events), die niet terugspringt als een IP geblokkeerd raakt.
create or replace function public.bingr_admin_gate(p_ip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare until_ts timestamptz; g timestamptz; total int;
begin
  select locked_until into g from public.admin_login_lock where id = 1;
  if g is not null and g > now() then
    return jsonb_build_object('locked', true, 'retry_after', ceil(extract(epoch from g - now())));
  end if;
  select locked_until into until_ts from public.admin_login_attempts where ip = p_ip;
  if until_ts is not null and until_ts > now() then
    return jsonb_build_object('locked', true, 'retry_after', ceil(extract(epoch from until_ts - now())));
  end if;
  select count(*) into total from public.admin_login_events
  where created_at > greatest(now() - interval '1 hour', coalesce(g, '-infinity'::timestamptz));
  if total >= 60 then
    update public.admin_login_lock set locked_until = now() + interval '15 minutes' where id = 1;
    return jsonb_build_object('locked', true, 'retry_after', 900);
  end if;
  return jsonb_build_object('locked', false);
end $$;
-- Resultaat van een poging: na 5 fouten binnen 15 min is het IP 15 min geblokkeerd; gelukt = teller weg.
-- build 95: gelukt haalt ook de laatste globale poging van dit IP weg; mislukt (alleen nog van een oudere functie
-- `admin`) telt ook globaal mee, en de blokkade zet failures niet meer op 0.
create or replace function public.bingr_admin_result(p_ip text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_ok then
    delete from public.admin_login_attempts where ip = p_ip;
    delete from public.admin_login_events where id = (select max(id) from public.admin_login_events where ip = p_ip);
    return;
  end if;
  insert into public.admin_login_events (ip) values (p_ip);
  insert into public.admin_login_attempts as a (ip, failures, window_start) values (p_ip, 1, now())
  on conflict (ip) do update set
    failures = case when a.window_start < now() - interval '15 minutes' or a.locked_until is not null then 1 else a.failures + 1 end,
    window_start = case when a.window_start < now() - interval '15 minutes' or a.locked_until is not null then now() else a.window_start end,
    locked_until = null;
  update public.admin_login_attempts set locked_until = now() + interval '15 minutes'
  where ip = p_ip and failures >= 5;
end $$;
revoke all on function public.bingr_admin_gate(text) from public, anon, authenticated;
revoke all on function public.bingr_admin_result(text, boolean) from public, anon, authenticated;
grant execute on function public.bingr_admin_gate(text) to service_role;
grant execute on function public.bingr_admin_result(text, boolean) to service_role;

-- Inlogs per dag uit het auth-logboek (als dat bestaat en gevuld wordt), anders leeg.
create or replace function public.bingr_audit_logins(p_days int) returns table(day date, n bigint)
language plpgsql security definer set search_path = public, auth as $$
begin
  if to_regclass('auth.audit_log_entries') is null then return; end if;
  return query execute
    'select (created_at at time zone ''utc'')::date, count(*) from auth.audit_log_entries
      where created_at > now() - make_interval(days => $1) and payload->>''action'' = ''login'' group by 1'
    using p_days;
exception when others then return;
end $$;
revoke all on function public.bingr_audit_logins(int) from public, anon, authenticated;
grant execute on function public.bingr_audit_logins(int) to service_role;

-- Statistieken voor het beheer-dashboard (functie admin, repo bingr-beheer).
create or replace function public.bingr_admin_stats() returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare res jsonb; days jsonb; audit_total bigint;
begin
  perform public.bingr_blocks_expire();
  select coalesce(sum(n), 0) into audit_total from public.bingr_audit_logins(30);
  with d as (select generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day')::date as day),
  nu as (select (created_at at time zone 'utc')::date as day, count(*) n from auth.users where created_at > now() - interval '31 days' group by 1),
  al as (select day, count(*) n from public.account_logins where day > (now() at time zone 'utc')::date - 31 group by 1),
  au as (select * from public.bingr_audit_logins(31))
  select jsonb_agg(jsonb_build_object('day', d.day, 'new_users', coalesce(nu.n, 0), 'active_users', coalesce(al.n, 0),
           'signins', case when audit_total > 0 then coalesce(au.n, 0) else coalesce(al.n, 0) end) order by d.day)
  into days from d left join nu on nu.day = d.day left join al on al.day = d.day left join au on au.day = d.day;
  res := jsonb_build_object(
    'total_users', (select count(*) from auth.users),
    'confirmed_users', (select count(*) from auth.users where email_confirmed_at is not null),
    'new_users_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'active_today', (select count(*) from public.account_logins where day = (now() at time zone 'utc')::date),
    'active_30d', (select count(distinct user_id) from public.account_logins where day > (now() at time zone 'utc')::date - 30),
    'devices_total', (select count(*) from public.account_devices),
    'watching_now', (select count(*) from public.account_streams where last_ping > now() - interval '90 seconds'),
    'opted_out', (select count(*) from public.account_email_prefs where email_opt_out),
    'blocked_users', (select count(distinct user_id) from public.account_blocks where lifted_at is null),
    -- abonnementen: geen rij = gratis (account_plans staat onderaan dit bestand)
    'plan_lifetime', (select count(*) from public.account_plans p join auth.users u on u.id = p.user_id where p.plan = 'lifetime'),
    'plan_free', (select count(*) from auth.users u where not exists (select 1 from public.account_plans p where p.user_id = u.id and p.plan = 'lifetime')),
    'plan_custom', (select count(*) from public.account_plans p where p.max_streams is not null or p.max_devices is not null),
    -- build 133: aankopen (Stripe). Omzet = som van de betaalde aankopen (terugbetaald en chargeback tellen niet mee), in centen
    'purchases_paid', (select count(*) from public.billing_purchases where status = 'paid'),
    'purchases_refunded', (select count(*) from public.billing_purchases where status in ('refunded', 'disputed')),
    'purchases_7d', (select count(*) from public.billing_purchases where status = 'paid' and paid_at > now() - interval '7 days'),
    'revenue_cents', (select coalesce(sum(amount), 0) from public.billing_purchases where status = 'paid' and currency = 'eur'),
    'signins_source', case when audit_total > 0 then 'audit' else 'activity' end,
    'days', coalesce(days, '[]'::jsonb),
    'platforms', coalesce((select jsonb_agg(jsonb_build_object('platform', platform, 'devices', n) order by n desc)
       from (select coalesce(nullif(platform, ''), '?') platform, count(*) n from public.account_devices
             where last_seen_at > now() - interval '30 days' group by 1) p), '[]'::jsonb),
    'versions', coalesce((select jsonb_agg(jsonb_build_object('platform', platform, 'app_version', app_version, 'devices', n) order by n desc)
       from (select coalesce(nullif(platform, ''), '?') platform, coalesce(app_version, '?') app_version, count(*) n
             from public.account_devices where last_seen_at > now() - interval '30 days' group by 1, 2) v), '[]'::jsonb)
  );
  return res;
end $$;
revoke all on function public.bingr_admin_stats() from public, anon, authenticated;
grant execute on function public.bingr_admin_stats() to service_role;

-- Gebruikers (hoofdaccounts), nieuwste eerst, zoeken op begin van het e-mailadres, de voornaam, de achternaam of
-- "voornaam achternaam" (user_metadata first_name / last_name; beheer). De functie admin maskeert de e-mail.
-- p_filter: '' = alle, 'blocked' = alleen geblokkeerde accounts, 'free' / 'lifetime' = abonnement, 'custom' = eigen limieten.
drop function if exists public.bingr_admin_users(text, int, int);
-- Filter van de gebruikerslijst (beheer). account_plans staat onderaan dit bestand (plpgsql controleert dat pas bij het uitvoeren).
create or replace function public.bingr_admin_user_match(p_user uuid, p_filter text) returns boolean
language plpgsql stable security definer set search_path = public, auth as $$
begin
  return case coalesce(p_filter, '')
    when 'blocked' then exists (select 1 from public.account_blocks b where b.user_id = p_user and b.lifted_at is null)
    when 'lifetime' then exists (select 1 from public.account_plans p where p.user_id = p_user and p.plan = 'lifetime')
    when 'free' then not exists (select 1 from public.account_plans p where p.user_id = p_user and p.plan = 'lifetime')
    when 'custom' then exists (select 1 from public.account_plans p where p.user_id = p_user and (p.max_streams is not null or p.max_devices is not null))
    else true end;
end $$;
revoke all on function public.bingr_admin_user_match(uuid, text) from public, anon, authenticated;
grant execute on function public.bingr_admin_user_match(uuid, text) to service_role;
-- Zoeken in de gebruikerslijst (beheer): p_pat is de ge-escapete zoekterm + '%' (begin van). Zonder zoekterm alleen accounts
-- met een e-mailadres, zoals vroeger; met zoekterm ook op naam (ilike, zelfde escaping): het begin van een woord in
-- "voornaam achternaam", dus de voornaam, de achternaam (ook "vries" in "de Vries") en de combinatie ("jan de v").
create or replace function public.bingr_admin_user_search(p_email text, p_meta jsonb, p_q text, p_pat text) returns boolean
language sql immutable set search_path = public as $$
  select lower(p_email) like p_pat or (coalesce(p_q, '') <> '' and
    (' ' || btrim(regexp_replace(coalesce(p_meta->>'first_name', '') || ' ' || coalesce(p_meta->>'last_name', ''), '\s+', ' ', 'g')))
      ilike ('% ' || p_pat))
$$;
revoke all on function public.bingr_admin_user_search(text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.bingr_admin_user_search(text, jsonb, text, text) to service_role;
create or replace function public.bingr_admin_users(p_search text, p_limit int, p_offset int, p_filter text default '') returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare q text := lower(coalesce(p_search, ''));
  pat text := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  f text := coalesce(p_filter, '');
begin
  perform public.bingr_blocks_expire();
  return jsonb_build_object(
    'total', (select count(*) from auth.users u where public.bingr_admin_user_search(u.email, u.raw_user_meta_data, q, pat) and public.bingr_admin_user_match(u.id, f)),
    'blocked_total', (select count(distinct user_id) from public.account_blocks where lifted_at is null),
    'lifetime_total', (select count(*) from public.account_plans p join auth.users u on u.id = p.user_id where p.plan = 'lifetime'),
    'free_total', (select count(*) from auth.users u where not exists (select 1 from public.account_plans p where p.user_id = u.id and p.plan = 'lifetime')),
    'items', coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.created_at desc) from (
      select u.id, u.email, u.created_at, u.last_sign_in_at, u.email_confirmed_at is not null as confirmed,
        nullif(btrim(u.raw_user_meta_data->>'first_name'), '') as first_name, nullif(btrim(u.raw_user_meta_data->>'last_name'), '') as last_name,
        (select count(*) from public.account_devices d where d.user_id = u.id) as device_count,
        (select coalesce(jsonb_agg(distinct d.platform), '[]'::jsonb) from public.account_devices d where d.user_id = u.id) as platforms,
        (select coalesce(jsonb_agg(distinct d.app_version), '[]'::jsonb) from public.account_devices d where d.user_id = u.id and d.app_version is not null) as app_versions,
        (select max(d.last_seen_at) from public.account_devices d where d.user_id = u.id) as last_seen_at,
        (select count(*) from public.account_data a, jsonb_array_elements(case when jsonb_typeof(a.profiles) = 'array' then a.profiles else '[]'::jsonb end) e
          where a.user_id = u.id and coalesce(e->>'deleted', 'false') <> 'true') as profile_count,
        coalesce((select p.email_opt_out from public.account_email_prefs p where p.user_id = u.id), false) as email_opt_out,
        (select jsonb_build_object('until', b.until, 'created_at', b.created_at) from public.account_blocks b
          where b.user_id = u.id and b.lifted_at is null order by b.created_at desc limit 1) as blocked,
        (coalesce((select jsonb_build_object('plan', p.plan, 'max_streams', p.max_streams, 'max_devices', p.max_devices, 'source', p.source)
          from public.account_plans p where p.user_id = u.id), jsonb_build_object('plan', 'free'))
          || coalesce(public.bingr_admin_purchase(u.id), '{}'::jsonb)) as plan
      from auth.users u where public.bingr_admin_user_search(u.email, u.raw_user_meta_data, q, pat) and public.bingr_admin_user_match(u.id, f)
      order by u.created_at desc limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)) x), '[]'::jsonb)
  );
end $$;
revoke all on function public.bingr_admin_users(text, int, int, text) from public, anon, authenticated;
grant execute on function public.bingr_admin_users(text, int, int, text) to service_role;

create or replace function public.bingr_admin_user(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare u record;
begin
  perform public.bingr_blocks_expire();
  select id, email, created_at, last_sign_in_at, email_confirmed_at, banned_until, raw_user_meta_data->>'lang' as lang,
    nullif(btrim(raw_user_meta_data->>'first_name'), '') as first_name, nullif(btrim(raw_user_meta_data->>'last_name'), '') as last_name
    into u from auth.users where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'confirmed', u.email_confirmed_at is not null, 'lang', u.lang, 'banned_until', u.banned_until,
    'first_name', u.first_name, 'last_name', u.last_name,
    'block', (select jsonb_build_object('id', b.id, 'reason', b.reason, 'until', b.until, 'created_at', b.created_at, 'notified', b.notified)
      from public.account_blocks b where b.user_id = u.id and b.lifted_at is null order by b.created_at desc limit 1),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'reason', b.reason, 'until', b.until, 'created_at', b.created_at,
        'notified', b.notified, 'lifted_at', b.lifted_at, 'lifted_by', b.lifted_by) order by b.created_at desc)
      from (select * from public.account_blocks where user_id = u.id order by created_at desc limit 20) b), '[]'::jsonb),
    'profile_count', (select count(*) from public.account_data a, jsonb_array_elements(case when jsonb_typeof(a.profiles) = 'array' then a.profiles else '[]'::jsonb end) e
          where a.user_id = u.id and coalesce(e->>'deleted', 'false') <> 'true'),
    'email_opt_out', coalesce((select p.email_opt_out from public.account_email_prefs p where p.user_id = u.id), false),
    'plan', coalesce((select jsonb_build_object('plan', p.plan, 'max_streams', p.max_streams, 'max_devices', p.max_devices, 'source', p.source,
        'note', p.note, 'granted_by', p.granted_by, 'created_at', p.created_at, 'updated_at', p.updated_at)
      from public.account_plans p where p.user_id = u.id), jsonb_build_object('plan', 'free'))
      || coalesce(public.bingr_admin_purchase(u.id), '{}'::jsonb),
    -- build 133: aankopen van dit account (Stripe), nieuwste eerst; zonder Stripe-id's of betaalgegevens
    'purchases', coalesce((select jsonb_agg(jsonb_build_object('created_at', b.created_at, 'paid_at', b.paid_at, 'amount', b.amount,
        'currency', b.currency, 'status', b.status, 'refunded_at', b.refunded_at) order by b.created_at desc)
      from (select * from public.billing_purchases where user_id = u.id order by created_at desc limit 10) b), '[]'::jsonb),
    'watching_now', (select count(*) from public.account_streams s where s.user_id = u.id and s.last_ping > now() - interval '90 seconds'),
    'active_days_30d', (select count(*) from public.account_logins l where l.user_id = u.id and l.day > (now() at time zone 'utc')::date - 30),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('name', d.name, 'platform', d.platform, 'app_version', d.app_version,
        'os_version', d.os_version, 'created_at', d.created_at, 'last_seen_at', d.last_seen_at) order by d.last_seen_at desc)
      from public.account_devices d where d.user_id = u.id), '[]'::jsonb)
  );
end $$;
revoke all on function public.bingr_admin_user(uuid) from public, anon, authenticated;
grant execute on function public.bingr_admin_user(uuid) to service_role;

-- Bulkmail: de volgende ontvangers claimen (cursor schuift meteen door, dus twee tabbladen versturen nooit dubbel).
-- build 97: verouderd, alleen nog voor een oudere functie admin; de nieuwe gebruikt bingr_announce_take / bingr_announce_mark
-- (onderaan dit bestand), die per ontvanger bijhouden wat verstuurd is.
create or replace function public.bingr_announce_claim(p_id uuid, p_batch int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare a record; rows jsonb; last_id uuid;
begin
  select * into a from public.announcements where id = p_id for update;
  if not found or not a.email or a.email_done_at is not null then return jsonb_build_object('items', '[]'::jsonb, 'done', true); end if;
  select jsonb_agg(jsonb_build_object('id', r.id, 'email', r.email, 'lang', r.lang) order by r.id), max(r.id::text)::uuid into rows, last_id from (
    select u.id, u.email, u.raw_user_meta_data->>'lang' as lang from auth.users u
    where u.email is not null and u.email_confirmed_at is not null
      and (a.email_cursor is null or u.id > a.email_cursor)
      and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and p.email_opt_out)
    order by u.id limit greatest(least(p_batch, 100), 1)) r;
  if rows is null then
    update public.announcements set email_done_at = now() where id = p_id;
    return jsonb_build_object('items', '[]'::jsonb, 'done', true);
  end if;
  update public.announcements set email_cursor = last_id where id = p_id;
  return jsonb_build_object('items', rows, 'done', false);
end $$;
create or replace function public.bingr_announce_report(p_id uuid, p_sent int, p_failed int) returns jsonb
language sql security definer set search_path = public as $$
  update public.announcements set email_sent = email_sent + p_sent, email_failed = email_failed + p_failed where id = p_id
  returning jsonb_build_object('email_total', email_total, 'email_sent', email_sent, 'email_failed', email_failed, 'done', email_done_at is not null);
$$;
create or replace function public.bingr_email_recipients() returns int
language sql security definer set search_path = public, auth as $$
  select count(*)::int from auth.users u where u.email is not null and u.email_confirmed_at is not null
    and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and p.email_opt_out);
$$;
revoke all on function public.bingr_announce_claim(uuid, int) from public, anon, authenticated;
revoke all on function public.bingr_announce_report(uuid, int, int) from public, anon, authenticated;
revoke all on function public.bingr_email_recipients() from public, anon, authenticated;
grant execute on function public.bingr_announce_claim(uuid, int) to service_role;
grant execute on function public.bingr_announce_report(uuid, int, int) to service_role;
grant execute on function public.bingr_email_recipients() to service_role;

-- Opruimen uitgebreid: ook oude limiettellers, inlogpogingen, actieve dagen (> 400 dagen) en het beheerlogboek (> 1 jaar).
create or replace function public.bingr_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.device_codes where expires_at < now();
  delete from public.account_streams where last_ping < now() - interval '1 day';
  delete from public.account_watch_log where started_at < now() - interval '8 days';
  delete from public.rate_limits where bucket < now() - interval '10 minutes';
  delete from public.admin_login_attempts where window_start < now() - interval '1 day' and (locked_until is null or locked_until < now());
  delete from public.account_logins where day < (now() at time zone 'utc')::date - 400;
  delete from public.admin_audit where created_at < now() - interval '1 year';
$$;
revoke all on function public.bingr_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_cleanup() to service_role;

-- ============================================================================================================
-- Statuspagina (bingr.online/status) en de tab Status in het beheer. Alleen de Edge Function `status` (service role)
-- leest en schrijft hierin. Monitors worden één keer klaargezet (on conflict do nothing): wijzigingen uit het beheer
-- blijven bij een nieuwe deploy staan; een verwijderde standaardmonitor komt wel terug (uitzetten kan altijd).
create table if not exists public.status_monitors (
  id              text primary key,
  name_nl         text not null,
  name_en         text not null,
  grp             text not null default 'website',
  kind            text not null default 'http',
  target          text not null default '',
  keyword         text,
  interval_min    int  not null default 5,
  public          boolean not null default true,
  enabled         boolean not null default true,
  builtin         boolean not null default false,
  sort            int  not null default 100,
  created_at      timestamptz not null default now(),
  last_checked_at timestamptz,
  last_state      text,
  last_ms         int,
  last_error      text,
  fail_streak     int not null default 0,
  ok_streak       int not null default 0
);
alter table public.status_monitors enable row level security;
revoke all on public.status_monitors from anon, authenticated;
do $$ begin
  alter table public.status_monitors add constraint status_monitors_grp_chk check (grp in ('server', 'website', 'apps'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.status_monitors add constraint status_monitors_interval_chk check (interval_min between 1 and 1440);
exception when duplicate_object then null; end $$;

insert into public.status_monitors (id, name_nl, name_en, grp, kind, target, keyword, interval_min, public, builtin, sort) values
  ('auth',       'Accounts & inloggen',          'Accounts & sign-in',           'server',  'auth',        '',                                       null,         5,  true,  true, 10),
  ('db',         'Database',                     'Database',                     'server',  'db',          '',                                       null,         5,  true,  true, 20),
  ('api',        'API apps',                     'App API',                      'server',  'fn',          'device-auth',                            null,         5,  true,  true, 30),
  ('proxy',      'Webspeler-doorgifte',          'Web player relay',             'server',  'fn',          'web-proxy',                              null,         5,  true,  true, 40),
  ('storage',    'Opslag (profielfoto''s)',      'Storage (profile photos)',     'server',  'storage',     'avatars',                                null,         5,  false, true, 50),
  ('smtp',       'E-mail (SMTP)',                'Email (SMTP)',                 'server',  'smtp',        '',                                       null,         5,  true,  true, 60),
  ('site',       'Website',                      'Website',                      'website', 'http',        'https://bingr.online/',                  'data-build', 5,  true,  true, 10),
  ('site-web',   'Webspeler',                    'Web player',                   'website', 'http',        'https://bingr.online/web/',              null,         5,  true,  true, 20),
  ('site-log',   'Changelog',                    'Changelog',                    'website', 'http',        'https://bingr.online/changelog/',        null,         5,  true,  true, 30),
  ('site-link',  'Tv koppelen',                  'TV linking',                   'website', 'http',        'https://bingr.online/koppelen/',         null,         5,  true,  true, 40),
  ('site-acc',   'Mijn Bingr',                   'My Bingr',                     'website', 'http',        'https://bingr.online/account/',          null,         5,  true,  true, 50),
  ('tls',        'TLS-certificaat',              'TLS certificate',              'website', 'tls',         'bingr.online',                           null,         60, true,  true, 60),
  ('apk',        'Android',                      'Android',                      'apps',    'build',       'android',                                null,         15, true,  true, 10),
  ('wgt',        'Samsung TV',                   'Samsung TV',                   'apps',    'build',       'tizen',                                  null,         15, true,  true, 20),
  ('apple',      'Apple (iOS, iPadOS, tvOS, macOS)', 'Apple (iOS, iPadOS, tvOS, macOS)', 'apps',    'gh_workflow', 'LRvdLinden/iptv-ios-appletv|build.yml|main', null,     15, true,  true, 30),
  ('devices',    'Actieve apparaten',            'Active devices',               'apps',    'devices',     '',                                       null,         5,  false, true, 90)
on conflict (id) do nothing;
-- downloads staan sinds build 69 in bingr-beheer/versions (niet meer als GitHub-release)
update public.status_monitors set target = replace(target, 'LRvdLinden/bingr-android|', 'LRvdLinden/bingr-beheer|') where kind = 'gh_asset' and target like 'LRvdLinden/bingr-android|%';
-- build 107: pakketten staan niet meer op GitHub maar in de afgesloten opslag van beheer.bingr.online (dl.php);
-- de downloadmonitors controleren die opslag (soort build, doel = platform)
update public.status_monitors
   set kind = 'build',
       target = case when target like '%.apk' then 'android' when target like '%.wgt' then 'tizen' when target like '%.zip' then 'apple' else target end
 where kind = 'gh_asset';

create table if not exists public.status_checks (
  id          bigserial primary key,
  monitor_id  text not null references public.status_monitors(id) on delete cascade,
  at          timestamptz not null default now(),
  ok          boolean not null,
  state       text not null default 'up',        -- up | degraded | down (een losse fout = degraded, bevestigd = down)
  status_code int,
  ms          int,
  error       text,
  detail      text
);
create index if not exists status_checks_monitor_at_idx on public.status_checks (monitor_id, at desc);
create index if not exists status_checks_at_idx on public.status_checks (at);
alter table public.status_checks enable row level security;
revoke all on public.status_checks from anon, authenticated;

-- Dagtotalen (Nederlandse tijd) voor de 90-dagenbalk en uptime over 7/30/90 dagen; bijgewerkt door een trigger.
create table if not exists public.status_daily (
  monitor_id  text not null references public.status_monitors(id) on delete cascade,
  day         date not null,
  n           int not null default 0,
  n_degraded  int not null default 0,
  n_down      int not null default 0,
  ms_sum      bigint not null default 0,
  ms_n        int not null default 0,
  primary key (monitor_id, day)
);
alter table public.status_daily enable row level security;
revoke all on public.status_daily from anon, authenticated;

create or replace function public.bingr_status_rollup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.status_daily as d (monitor_id, day, n, n_degraded, n_down, ms_sum, ms_n)
  values (new.monitor_id, (new.at at time zone 'Europe/Amsterdam')::date, 1,
          (new.state = 'degraded')::int, (new.state = 'down')::int, coalesce(new.ms, 0), (new.ms is not null)::int)
  on conflict (monitor_id, day) do update set
    n = d.n + 1, n_degraded = d.n_degraded + excluded.n_degraded, n_down = d.n_down + excluded.n_down,
    ms_sum = d.ms_sum + excluded.ms_sum, ms_n = d.ms_n + excluded.ms_n;
  return new;
end $$;
drop trigger if exists status_checks_rollup on public.status_checks;
create trigger status_checks_rollup after insert on public.status_checks for each row execute function public.bingr_status_rollup();

create table if not exists public.status_incidents (
  id          bigserial primary key,
  monitor_id  text not null references public.status_monitors(id) on delete cascade,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  cause       text
);
-- per monitor hooguit één open storing (ook als twee controles tegelijk lopen)
create unique index if not exists status_incidents_open_idx on public.status_incidents (monitor_id) where ended_at is null;
create index if not exists status_incidents_started_idx on public.status_incidents (started_at desc);
alter table public.status_incidents enable row level security;
revoke all on public.status_incidents from anon, authenticated;

-- Eén controle tegelijk: een run claimt het slot voor 90 s.
create table if not exists public.status_runner (
  id            int primary key default 1,
  running_until timestamptz not null default 'epoch',
  last_run_at   timestamptz,
  last_source   text
);
insert into public.status_runner (id) values (1) on conflict (id) do nothing;
alter table public.status_runner enable row level security;
revoke all on public.status_runner from anon, authenticated;

create or replace function public.bingr_status_lock(p_source text) returns boolean
language plpgsql security definer set search_path = public as $$
declare got int;
begin
  update public.status_runner set running_until = now() + interval '90 seconds', last_run_at = now(), last_source = left(p_source, 20)
  where id = 1 and running_until < now();
  get diagnostics got = row_count;
  return got > 0;
end $$;
create or replace function public.bingr_status_unlock() returns void
language sql security definer set search_path = public as $$
  update public.status_runner set running_until = 'epoch' where id = 1;
$$;

-- Alles wat de statuspagina nodig heeft in één jsonb (geen limiet van 1000 rijen zoals bij gewone REST).
create or replace function public.bingr_status_data(p_days int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'today', (now() at time zone 'Europe/Amsterdam')::date,
    'daily', coalesce((select jsonb_agg(jsonb_build_object('m', monitor_id, 'd', day, 'n', n, 'g', n_degraded, 'x', n_down,
               'ms', case when ms_n > 0 then round(ms_sum::numeric / ms_n) end) order by monitor_id, day)
             from public.status_daily where day > (now() at time zone 'Europe/Amsterdam')::date - p_days), '[]'::jsonb),
    'last24', coalesce((select jsonb_agg(jsonb_build_object('m', monitor_id, 'n', n, 'x', x, 'ms', ms))
             from (select monitor_id, count(*) n, count(*) filter (where state = 'down') x, round(avg(ms)) ms
                   from public.status_checks where at > now() - interval '24 hours' group by monitor_id) t), '[]'::jsonb),
    'incidents', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'm', monitor_id, 'started_at', started_at,
               'ended_at', ended_at, 'cause', cause) order by started_at desc)
             from public.status_incidents where started_at > now() - make_interval(days => p_days) or ended_at is null), '[]'::jsonb)
  );
$$;

-- Actieve apparaten per platform (laatste 15 minuten), alleen voor het beheer.
create or replace function public.bingr_status_devices() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('platform', platform, 'devices', n) order by n desc), '[]'::jsonb)
  from (select coalesce(nullif(platform, ''), '?') platform, count(*) n from public.account_devices
        where last_seen_at > now() - interval '15 minutes' group by 1) p;
$$;

-- Planning (pg_cron): bestaat de taak, en hoe ging de laatste uitvoering. Werkt ook zonder pg_cron (dan null).
create or replace function public.bingr_status_cron() returns jsonb
language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  execute $q$
    select jsonb_build_object('active', j.active, 'schedule', j.schedule,
      'last_run', (select jsonb_build_object('start', d.start_time, 'status', d.status) from cron.job_run_details d
                   where d.jobid = j.jobid order by d.start_time desc limit 1))
    from cron.job j where j.jobname = 'bingr-status' limit 1 $q$ into res;
  return res;
exception when others then
  return null;
end $$;

-- Opruimen: ruwe controles 90 dagen, dagtotalen 400 dagen, afgesloten storingen 1 jaar.
create or replace function public.bingr_status_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.status_checks where at < now() - interval '90 days';
  delete from public.status_daily where day < (now() at time zone 'Europe/Amsterdam')::date - 400;
  delete from public.status_incidents where ended_at is not null and ended_at < now() - interval '1 year';
$$;
revoke all on function public.bingr_status_lock(text) from public, anon, authenticated;
revoke all on function public.bingr_status_unlock() from public, anon, authenticated;
revoke all on function public.bingr_status_data(int) from public, anon, authenticated;
revoke all on function public.bingr_status_devices() from public, anon, authenticated;
revoke all on function public.bingr_status_cron() from public, anon, authenticated;
revoke all on function public.bingr_status_cleanup() from public, anon, authenticated;
revoke all on function public.bingr_status_rollup() from public, anon, authenticated;
grant execute on function public.bingr_status_lock(text) to service_role;
grant execute on function public.bingr_status_unlock() to service_role;
grant execute on function public.bingr_status_data(int) to service_role;
grant execute on function public.bingr_status_devices() to service_role;
grant execute on function public.bingr_status_cron() to service_role;
grant execute on function public.bingr_status_cleanup() to service_role;

-- Planning: pg_cron + pg_net (de taak zelf, met het geheim, zet de Backend-workflow klaar; nooit in de repo).
do $$ begin
  execute 'create extension if not exists pg_cron with schema pg_catalog';
  execute 'create extension if not exists pg_net with schema extensions';
exception when others then
  raise notice 'pg_cron/pg_net niet beschikbaar: %', sqlerrm;
end $$;

-- ============================================================================================================
-- Build 68: kijkstatistieken (zoals Trakt). De server telt de kijktijd zelf op uit stream_start/ping/stop:
-- per account, profiel, lokale dag (tijdzone van de app), soort (movie | episode | live) en titel (item_key).
-- Alleen de Edge Function device-auth (service role) leest en schrijft hierin. Bewaard: 400 dagen.
alter table public.account_streams add column if not exists series_id text;
alter table public.account_streams add column if not exists series_title text;
alter table public.account_streams add column if not exists tz text;
alter table public.account_streams add column if not exists last_accounted_at timestamptz;

create table if not exists public.account_watch_stats (
  user_id      uuid not null references auth.users(id) on delete cascade,
  profile_id   text not null default '',            -- '' = onbekend profiel (oude apps zonder profile_id)
  profile_name text,
  day          date not null,                       -- lokale dag in de tijdzone van de app (tz), anders Europe/Amsterdam
  kind         text not null,                       -- movie | episode | live (catchup telt als live)
  item_key     text not null,                       -- movie: content_id; episode: series_id (of 't:<serietitel>'); live: content_id van de zender
  title        text,                                -- filmtitel, serietitel of zendernaam
  episodes     text[] not null default '{}',        -- episode: unieke content_id's van afleveringen (max. 500)
  minutes      numeric not null default 0,
  plays        int not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (user_id, profile_id, day, kind, item_key)
);
create index if not exists account_watch_stats_user_day_idx on public.account_watch_stats (user_id, day);
create index if not exists account_watch_stats_day_idx on public.account_watch_stats (day);
alter table public.account_watch_stats enable row level security;
revoke all on public.account_watch_stats from anon, authenticated;

-- Eenmalige stappen (zoals het vullen van de statistieken uit de bestaande kijkgeschiedenis).
create table if not exists public.bingr_migrations (
  name    text primary key,
  done_at timestamptz not null default now()
);
alter table public.bingr_migrations enable row level security;
revoke all on public.bingr_migrations from anon, authenticated;

-- Welke titel telt een stream: soort, sleutel en weergavenaam. Oude apps sturen geen series_id: dan de serietitel uit de
-- streamtitel ("Serie · S1:E2 · Naam", "Serie S01E02", "Serie - S1E2") met sleutel 't:<serietitel in kleine letters>'.
-- Live: de zendernaam vóór " · " (de apps zetten het programma erachter). Onbekende soort = niet tellen (kind null).
create or replace function public.bingr_stats_item(p_kind text, p_content_id text, p_series_id text, p_series_title text, p_title text)
returns table(kind text, item_key text, title text)
language plpgsql immutable set search_path = public as $$
declare k text := lower(btrim(coalesce(p_kind, ''))); t text := btrim(coalesce(p_title, ''));
        cid text := nullif(btrim(coalesce(p_content_id, '')), ''); base text; pre text;
begin
  base := btrim(split_part(t, ' · ', 1));
  if k in ('live', 'catchup', 'channel') then kind := 'live';
  elsif k in ('episode', 'series') then kind := 'episode';
  elsif k in ('movie', 'vod') then kind := 'movie';
  else kind := null; item_key := null; title := null; return next; return;
  end if;
  if kind = 'episode' then
    pre := btrim(regexp_replace(base, '\s*[-–:|]?\s*S\d{1,3}\s*[:.]?\s*E\d{1,4}\M.*$', '', 'i'));
    pre := btrim(regexp_replace(pre, '\s*[-–:|·]+$', ''));
    if pre = '' then pre := base; end if;
    title := coalesce(nullif(btrim(coalesce(p_series_title, '')), ''), nullif(pre, ''));
    item_key := coalesce(nullif(btrim(coalesce(p_series_id, '')), ''), case when title is not null then 't:' || lower(title) end, cid);
  else
    title := nullif(base, '');
    item_key := coalesce(cid, case when title is not null then 't:' || lower(title) end);
  end if;
  title := left(title, 200); item_key := left(item_key, 200);
  return next;
end $$;

-- Lokale dag in een tijdzone; een onbekende tijdzone valt terug op Europe/Amsterdam.
create or replace function public.bingr_local_day(p_tz text, p_at timestamptz default now()) returns date
language plpgsql stable set search_path = public as $$
begin
  return (p_at at time zone coalesce(nullif(p_tz, ''), 'Europe/Amsterdam'))::date;
exception when others then
  return (p_at at time zone 'Europe/Amsterdam')::date;
end $$;

-- Kijktijd van een lopende stream bijschrijven: de tijd sinds het laatst getelde moment (max. p_max_seconds per keer,
-- zodat een gat niet meetelt). Was de stream al verlopen (geen ping binnen p_ttl_seconds), dan alleen tot de laatste ping.
create or replace function public.bingr_stream_account(p_user uuid, p_device text, p_ttl_seconds int default 90, p_max_seconds int default 180)
returns void language plpgsql security definer set search_path = public as $$
declare s record; it record; v_end timestamptz; secs numeric;
begin
  select * into s from public.account_streams where user_id = p_user and device_id = p_device for update;
  if not found then return; end if;
  v_end := case when now() - s.last_ping > make_interval(secs => p_ttl_seconds) then s.last_ping else now() end;
  secs := least(greatest(extract(epoch from v_end - coalesce(s.last_accounted_at, s.started_at)), 0), p_max_seconds);
  update public.account_streams set last_accounted_at = greatest(v_end, coalesce(last_accounted_at, v_end))
  where user_id = p_user and device_id = p_device;
  if secs <= 0 then return; end if;
  select * into it from public.bingr_stats_item(s.kind, s.content_id, s.series_id, s.series_title, s.title);
  if it.kind is null or coalesce(it.item_key, '') = '' then return; end if;
  insert into public.account_watch_stats as w (user_id, profile_id, profile_name, day, kind, item_key, title, episodes, minutes, plays)
  values (p_user, coalesce(s.profile_id, ''), s.profile_name, public.bingr_local_day(s.tz, v_end), it.kind, it.item_key, it.title,
          case when it.kind = 'episode' and s.content_id is not null then array[left(s.content_id, 200)] else '{}'::text[] end, secs / 60.0, 0)
  on conflict (user_id, profile_id, day, kind, item_key) do update set
    minutes = w.minutes + excluded.minutes,
    title = coalesce(excluded.title, w.title),
    profile_name = coalesce(excluded.profile_name, w.profile_name),
    episodes = case when cardinality(excluded.episodes) = 0 or excluded.episodes[1] = any(w.episodes) or cardinality(w.episodes) >= 500
                    then w.episodes else w.episodes || excluded.episodes end,
    updated_at = now();
end $$;
revoke all on function public.bingr_stream_account(uuid, text, int, int) from public, anon, authenticated;
grant execute on function public.bingr_stream_account(uuid, text, int, int) to service_role;

-- stream_start met series_id, series_title en tz: eerst de lopende stream op dit apparaat bijschrijven,
-- dan zoals voorheen (limiet, geschiedenis), en één weergave (plays) voor de nieuwe titel.
drop function if exists public.bingr_stream_start(uuid, text, text, text, text, text, text, int, int);
create or replace function public.bingr_stream_start(p_user uuid, p_device text, p_profile_id text, p_profile_name text,
  p_title text, p_kind text, p_content_id text, p_limit int, p_ttl_seconds int,
  p_series_id text default null, p_series_title text default null, p_tz text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int; old_log bigint; dev_name text; dev_platform text; new_log bigint; it record;
begin
  perform pg_advisory_xact_lock(hashtextextended('bingr.streams:' || p_user::text, 0));
  perform public.bingr_stream_account(p_user, p_device, p_ttl_seconds);
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
  insert into public.account_streams (user_id, device_id, profile_id, profile_name, title, kind, content_id, log_id, started_at, last_ping,
    series_id, series_title, tz, last_accounted_at)
  values (p_user, p_device, p_profile_id, p_profile_name, p_title, p_kind, p_content_id, new_log, now(), now(),
    p_series_id, p_series_title, p_tz, now())
  on conflict (user_id, device_id) do update set profile_id = excluded.profile_id, profile_name = excluded.profile_name,
    title = excluded.title, kind = excluded.kind, content_id = excluded.content_id, log_id = excluded.log_id,
    started_at = excluded.started_at, last_ping = excluded.last_ping, series_id = excluded.series_id,
    series_title = excluded.series_title, tz = excluded.tz, last_accounted_at = excluded.last_accounted_at;
  select * into it from public.bingr_stats_item(p_kind, p_content_id, p_series_id, p_series_title, p_title);
  if it.kind is not null and coalesce(it.item_key, '') <> '' then
    insert into public.account_watch_stats as w (user_id, profile_id, profile_name, day, kind, item_key, title, plays)
    values (p_user, coalesce(p_profile_id, ''), p_profile_name, public.bingr_local_day(p_tz), it.kind, it.item_key, it.title, 1)
    on conflict (user_id, profile_id, day, kind, item_key) do update set plays = w.plays + 1,
      title = coalesce(excluded.title, w.title), profile_name = coalesce(excluded.profile_name, w.profile_name), updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.bingr_stream_start(uuid, text, text, text, text, text, text, int, int, text, text, text) from public, anon, authenticated;
grant execute on function public.bingr_stream_start(uuid, text, text, text, text, text, text, int, int, text, text, text) to service_role;

-- Statistieken voor een periode (p_from t/m p_to, lokale dagen), voor één profiel of alle (p_profile null).
-- Per dag of per maand (p_by_month) en per soort; titels (top 50 per soort) en tellers; minuten per profiel.
create or replace function public.bingr_watch_stats(p_user uuid, p_profile text, p_from date, p_to date, p_by_month boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  with r as (
    select * from public.account_watch_stats
    where user_id = p_user and day between p_from and p_to and (p_profile is null or profile_id = p_profile)
  ), ep as (
    select r.kind, r.item_key, count(distinct e) n from r, unnest(r.episodes) e group by 1, 2
  ), items as (
    select r.kind, r.item_key, (array_agg(r.title order by r.updated_at desc) filter (where r.title is not null))[1] as title,
      sum(r.minutes) as minutes, sum(r.plays) as plays, coalesce(max(ep.n), 0) as episodes
    from r left join ep on ep.kind = r.kind and ep.item_key = r.item_key group by 1, 2
  )
  select jsonb_build_object(
    'buckets', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'kind', kind, 'minutes', m)) from (
        select case when p_by_month then to_char(day, 'YYYY-MM') else to_char(day, 'YYYY-MM-DD') end as key, kind, sum(minutes) as m
        from r group by 1, 2) b), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'item_key', item_key, 'title', title, 'minutes', minutes,
        'plays', plays, 'episodes', episodes)) from (
        select *, row_number() over (partition by kind order by minutes desc, item_key) as rn from items where minutes >= 1) x where rn <= 50), '[]'::jsonb),
    'counts', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'items', n, 'episodes', e)) from (
        select kind, count(*) as n, sum(episodes) as e from items where minutes >= 1 group by kind) c), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('profile_id', profile_id, 'profile_name', profile_name, 'minutes', m)) from (
        select profile_id, (array_agg(profile_name order by updated_at desc) filter (where profile_name is not null))[1] as profile_name, sum(minutes) as m
        from r group by 1) p), '[]'::jsonb),
    'since', (select min(day) from public.account_watch_stats where user_id = p_user and (p_profile is null or profile_id = p_profile))
  );
$$;
revoke all on function public.bingr_watch_stats(uuid, text, date, date, boolean) from public, anon, authenticated;
grant execute on function public.bingr_watch_stats(uuid, text, date, date, boolean) to service_role;
revoke all on function public.bingr_stats_item(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.bingr_local_day(text, timestamptz) from public, anon, authenticated;
grant execute on function public.bingr_stats_item(text, text, text, text, text) to service_role;
grant execute on function public.bingr_local_day(text, timestamptz) to service_role;

-- Eenmalig: statistieken vullen uit de bestaande kijkgeschiedenis (max. 8 dagen, Nederlandse tijd, best effort).
-- Lopende streams tellen daarna verder vanaf hun laatste ping, zodat niets dubbel telt.
do $$ begin
  if not exists (select 1 from public.bingr_migrations where name = 'watch_stats_seed_68') then
    insert into public.account_watch_stats (user_id, profile_id, profile_name, day, kind, item_key, title, episodes, minutes, plays)
    select l.user_id, coalesce(l.profile_id, ''), max(l.profile_name), (l.started_at at time zone 'Europe/Amsterdam')::date,
      it.kind, it.item_key, max(it.title),
      case when it.kind = 'episode' then coalesce((array_agg(distinct left(l.content_id, 200)) filter (where l.content_id is not null))[1:500], '{}'::text[]) else '{}'::text[] end,
      sum(least(greatest(extract(epoch from l.ended_at - l.started_at), 0), 6 * 3600)) / 60.0, count(*)
    from public.account_watch_log l
    cross join lateral public.bingr_stats_item(l.kind, l.content_id, null, null, l.title) it
    where it.kind is not null and coalesce(it.item_key, '') <> ''
    group by l.user_id, coalesce(l.profile_id, ''), (l.started_at at time zone 'Europe/Amsterdam')::date, it.kind, it.item_key
    on conflict do nothing;
    update public.account_streams set last_accounted_at = coalesce(last_accounted_at, last_ping);
    insert into public.bingr_migrations (name) values ('watch_stats_seed_68');
  end if;
end $$;

-- Opruimen: zoals hierboven, plus kijkstatistieken ouder dan 400 dagen.
create or replace function public.bingr_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.device_codes where expires_at < now();
  delete from public.account_streams where last_ping < now() - interval '1 day';
  delete from public.account_watch_log where started_at < now() - interval '8 days';
  delete from public.rate_limits where bucket < now() - interval '10 minutes';
  delete from public.admin_login_attempts where window_start < now() - interval '1 day' and (locked_until is null or locked_until < now());
  delete from public.account_logins where day < (now() at time zone 'utc')::date - 400;
  delete from public.admin_audit where created_at < now() - interval '1 year';
  delete from public.account_watch_stats where day < (now() at time zone 'utc')::date - 400;
$$;
revoke all on function public.bingr_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_cleanup() to service_role;

-- ============================================================================================================
-- Supporttickets (support.bingr.online). Alleen de Edge Function `support` (service role) leest en schrijft hierin;
-- het beheer (functie admin in bingr-beheer) gaat via `support` met het geheim SUPPORT_ADMIN_SECRET.
-- Ticketnummers beginnen bij 1001 en worden getoond als #1001. Een ticket zonder account is te openen met de
-- geheime link uit de e-mail (access_token); met een Bingr-account ook via "Mijn tickets".
create sequence if not exists public.support_ticket_number_seq start with 1001;
create table if not exists public.support_tickets (
  id               uuid primary key default gen_random_uuid(),
  number           bigint not null unique default nextval('public.support_ticket_number_seq'),
  user_id          uuid references auth.users(id) on delete set null,
  email            text not null,
  name             text not null default '',
  subject          text not null,
  category         text not null default 'overig',
  platform         text,
  app_version      text,
  status           text not null default 'new',
  priority         text not null default 'normal',
  lang             text not null default 'nl',
  access_token     text not null,
  ip_hash          text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  last_reply_at    timestamptz not null default now(),
  last_customer_at timestamptz not null default now(),
  last_support_at  timestamptz,
  admin_seen_at    timestamptz,
  customer_seen_at timestamptz,
  closed_at        timestamptz
);
alter sequence public.support_ticket_number_seq owned by public.support_tickets.number;
create index if not exists support_tickets_status_idx on public.support_tickets (status, last_reply_at desc);
create index if not exists support_tickets_email_idx on public.support_tickets (lower(email));
create index if not exists support_tickets_user_idx on public.support_tickets (user_id);
create index if not exists support_tickets_ip_idx on public.support_tickets (ip_hash, created_at);
create index if not exists support_tickets_created_idx on public.support_tickets (created_at desc);
alter table public.support_tickets enable row level security;
revoke all on public.support_tickets from anon, authenticated;
do $$ begin
  alter table public.support_tickets add constraint support_tickets_status_chk check (status in ('new', 'open', 'pending', 'resolved', 'closed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.support_tickets add constraint support_tickets_priority_chk check (priority in ('low', 'normal', 'high', 'urgent'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.support_tickets add constraint support_tickets_lang_chk check (lang in ('nl', 'en'));
exception when duplicate_object then null; end $$;

-- Berichten per ticket: customer (klant), support (antwoord, gemaild), note (interne notitie, nooit zichtbaar voor de
-- klant) en event (statuswijziging, body = de nieuwe status).
create table if not exists public.support_messages (
  id          bigserial primary key,
  ticket_id   uuid not null references public.support_tickets(id) on delete cascade,
  author      text not null,
  body        text not null,
  created_at  timestamptz not null default now(),
  email_sent  boolean not null default false,
  email_error text
);
create index if not exists support_messages_ticket_idx on public.support_messages (ticket_id, created_at);
alter table public.support_messages enable row level security;
revoke all on public.support_messages from anon, authenticated;
revoke all on sequence public.support_messages_id_seq from anon, authenticated;
revoke all on sequence public.support_ticket_number_seq from anon, authenticated;
do $$ begin
  alter table public.support_messages add constraint support_messages_author_chk check (author in ('customer', 'support', 'note', 'event'));
exception when duplicate_object then null; end $$;

-- Apparaat bij een ticket (support.bingr.online, ingelogd): het gekozen apparaat uit account_devices (device_id, mag later
-- verdwijnen, dus geen foreign key) met de naam en systeemversie zoals ze bij het aanmaken waren. Zonder account: alleen platform.
alter table public.support_tickets add column if not exists device_id text;
alter table public.support_tickets add column if not exists device_name text;
alter table public.support_tickets add column if not exists os_version text;

-- Supporttickets per e-mail (inbox-import, actie poll_inbox van de functie support): herkomst van een bericht (web =
-- support.bingr.online of de apps, email = per mail binnengekomen, admin = beheer), de Message-ID van de binnengekomen mail
-- (uniek: elke mail maar één keer) en waar hij op antwoordde, en de Message-ID van de mail die wij voor dit bericht verstuurden.
alter table public.support_messages add column if not exists source text;
alter table public.support_messages add column if not exists message_id text;
alter table public.support_messages add column if not exists in_reply_to text;
alter table public.support_messages add column if not exists mail_message_id text;
do $$ begin
  alter table public.support_messages add constraint support_messages_source_chk check (source is null or source in ('web', 'email', 'admin'));
exception when duplicate_object then null; end $$;
create unique index if not exists support_messages_message_id_key on public.support_messages (message_id) where message_id is not null;
create index if not exists support_messages_mail_id_idx on public.support_messages (mail_message_id) where mail_message_id is not null;
-- bestaande berichten: klant via de site, support en notities via het beheer
update public.support_messages set source = case when author = 'customer' then 'web' else 'admin' end
  where source is null and author in ('customer', 'support', 'note');

-- Toestand van de inbox-import (één rij): laatste verwerkte UID per UIDVALIDITY, laatste ronde en fout, en een korte lease
-- (lock_until) zodat de planning en de knop in het beheer nooit tegelijk lopen.
create table if not exists public.support_inbox_state (
  id             int primary key default 1 check (id = 1),
  mailbox        text,
  uidvalidity    bigint,
  last_uid       bigint,
  error_uid      bigint,
  error_count    int not null default 0,
  lock_until     timestamptz,
  last_poll_at   timestamptz,
  last_ok_at     timestamptz,
  last_import_at timestamptz,
  last_error     text,
  last_error_at  timestamptz,
  last_result    jsonb,
  last_source    text,
  updated_at     timestamptz not null default now()
);
insert into public.support_inbox_state (id) values (1) on conflict (id) do nothing;
alter table public.support_inbox_state enable row level security;
revoke all on public.support_inbox_state from anon, authenticated;
-- Logboek van de inbox-import (30 dagen): wat er met elke mail gebeurde (geen berichttekst)
create table if not exists public.support_inbox_log (
  id            bigserial primary key,
  at            timestamptz not null default now(),
  uid           bigint,
  message_id    text,
  sender        text,
  subject       text,
  result        text not null,
  ticket_number bigint,
  detail        text
);
create index if not exists support_inbox_log_at_idx on public.support_inbox_log (at desc);
alter table public.support_inbox_log enable row level security;
revoke all on public.support_inbox_log from anon, authenticated;
revoke all on sequence public.support_inbox_log_id_seq from anon, authenticated;
create or replace function public.bingr_support_inbox_lock(p_seconds int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into public.support_inbox_state (id) values (1) on conflict (id) do nothing;
  update public.support_inbox_state set lock_until = now() + make_interval(secs => greatest(10, least(p_seconds, 600)))
    where id = 1 and (lock_until is null or lock_until < now());
  return found;
end $$;
revoke all on function public.bingr_support_inbox_lock(int) from public, anon, authenticated;
grant execute on function public.bingr_support_inbox_lock(int) to service_role;

-- Aantallen per status voor het beheer (tab Support en de tegel "Open tickets"); unread = klant wacht op een reactie
-- die het beheer nog niet heeft gezien.
create or replace function public.bingr_support_counts() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'new',      count(*) filter (where status = 'new'),
    'open',     count(*) filter (where status = 'open'),
    'pending',  count(*) filter (where status = 'pending'),
    'resolved', count(*) filter (where status = 'resolved'),
    'closed',   count(*) filter (where status = 'closed'),
    'active',   count(*) filter (where status in ('new', 'open', 'pending')),
    'unread',   count(*) filter (where status in ('new', 'open') and (admin_seen_at is null or last_customer_at > admin_seen_at)),
    'total',    count(*),
    'last_7d',  count(*) filter (where created_at > now() - interval '7 days'))
  from public.support_tickets;
$$;
-- Bingr-account bij een ticket (op user_id, anders op e-mailadres): alleen een samenvatting voor het beheer. Gevonden op
-- e-mailadres = linked false: dat account is NIET de eigenaar (security H1), het beheer toont het als "niet gekoppeld".
create or replace function public.bingr_support_account(p_user uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare u record; found_it boolean := false;
begin
  if p_user is not null then
    select id, email, created_at, last_sign_in_at, email_confirmed_at into u from auth.users where id = p_user;
    found_it := found;
  end if;
  if not found_it and coalesce(p_email, '') <> '' then
    select id, email, created_at, last_sign_in_at, email_confirmed_at into u from auth.users where lower(email) = lower(p_email) limit 1;
    found_it := found;
  end if;
  if not found_it then return null; end if;
  return jsonb_build_object(
    'id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'confirmed', u.email_confirmed_at is not null, 'linked', p_user is not null and u.id = p_user,
    'device_count', (select count(*) from public.account_devices d where d.user_id = u.id),
    'platforms', (select coalesce(jsonb_agg(distinct d.platform), '[]'::jsonb) from public.account_devices d where d.user_id = u.id and d.platform <> ''),
    'app_versions', (select coalesce(jsonb_agg(distinct d.app_version), '[]'::jsonb) from public.account_devices d where d.user_id = u.id and d.app_version is not null),
    'last_seen_at', (select max(d.last_seen_at) from public.account_devices d where d.user_id = u.id),
    -- security H1: alleen gekoppelde tickets (user_id); een account op hetzelfde adres is geen bewijs van eigendom
    'tickets', (select count(*) from public.support_tickets t where t.user_id = u.id)
  );
end $$;
revoke all on function public.bingr_support_counts() from public, anon, authenticated;
revoke all on function public.bingr_support_account(uuid, text) from public, anon, authenticated;
grant execute on function public.bingr_support_counts() to service_role;
grant execute on function public.bingr_support_account(uuid, text) to service_role;

-- build 95: e-mailadressen van tickets altijd in kleine letters (de functie support schrijft ze zo), zodat de filters
-- email = '…' een gewone index gebruiken (support_tickets_email_idx op lower(email) blijft voor bingr_support_account).
update public.support_tickets set email = lower(email) where email <> lower(email);
do $$ begin
  alter table public.support_tickets add constraint support_tickets_email_lower_chk check (email = lower(email));
exception when duplicate_object then null; end $$;
create index if not exists support_tickets_email_created_idx on public.support_tickets (email, created_at);

-- build 95: inbox-import: oude ongelezen mails (eerste ronde of nieuwe UIDVALIDITY) in porties over meerdere rondes
-- (scan_until = hoogste UID van die achterstand, scan_cursor = laatst verwerkte UID daarin; null = geen achterstand), en
-- het inbox-logboek hooguit één keer per dag opruimen (last_cleanup_at).
alter table public.support_inbox_state add column if not exists scan_until bigint;
alter table public.support_inbox_state add column if not exists scan_cursor bigint;
alter table public.support_inbox_state add column if not exists last_cleanup_at timestamptz;
-- build 140: de import loopt niet meer met een cursor maar langs alle mails zonder het IMAP-trefwoord $BingrDone; het
-- logboek per map en UIDVALIDITY/UID is het vangnet voor servers zonder trefwoorden (scan_until/scan_cursor ongebruikt).
alter table public.support_inbox_log add column if not exists folder text;
alter table public.support_inbox_log add column if not exists uidvalidity bigint;
create index if not exists support_inbox_log_uid_idx on public.support_inbox_log (folder, uidvalidity, uid);

-- build 95: captcha zonder derde partij (proof-of-work, actie challenge van de functie support): elke salt mag maar één
-- keer een ticket maken. Alleen de functie (service role); dagelijks opgeruimd door bingr_support_cleanup.
create table if not exists public.support_pow_used (
  salt    text primary key,
  used_at timestamptz not null default now()
);
create index if not exists support_pow_used_at_idx on public.support_pow_used (used_at);
alter table public.support_pow_used enable row level security;
revoke all on public.support_pow_used from anon, authenticated;

-- build 95: AVG. Dagelijks (pg_cron-taak bingr-support-cleanup, klaargezet door de Backend-workflow):
--   gesloten tickets (met berichten, via on delete cascade) 24 maanden na de laatste activiteit weg;
--   ip_hash na 30 dagen leeg (alleen nodig voor de limieten van het afgelopen uur);
--   gebruikte captcha-salts na 1 dag weg; het logboek van pg_cron (cron.job_run_details) na 7 dagen weg.
create or replace function public.bingr_support_cleanup() returns jsonb
language plpgsql security definer set search_path = public as $$
declare t int := 0; i int := 0; p int := 0; c int := 0; s int := 0; b int := 0;
begin
  delete from public.support_tickets
  where status = 'closed' and greatest(last_reply_at, updated_at, coalesce(closed_at, updated_at)) < now() - interval '24 months';
  get diagnostics t = row_count;
  update public.support_tickets set ip_hash = null where ip_hash is not null and created_at < now() - interval '30 days';
  get diagnostics i = row_count;
  delete from public.support_pow_used where used_at < now() - interval '1 day';
  get diagnostics p = row_count;
  begin
    execute 'delete from cron.job_run_details where coalesce(end_time, start_time) < now() - interval ''7 days''';
    get diagnostics c = row_count;
  exception when others then
    raise notice 'cron.job_run_details niet opgeruimd: %', sqlerrm;
  end;
  -- build 134: registratiepogingen (IP-hashes) na 7 dagen weg
  if to_regprocedure('public.bingr_signup_attempts_cleanup()') is not null then s := public.bingr_signup_attempts_cleanup(); end if;
  -- bewaarplicht: aankopen zonder account 7 jaar na het einde van het boekjaar weg (bingr_billing_retention)
  if to_regprocedure('public.bingr_billing_retention(timestamptz)') is not null then b := public.bingr_billing_retention(); end if;
  return jsonb_build_object('tickets', t, 'ip_hash', i, 'pow', p, 'cron_runs', c, 'signup_attempts', s, 'purchases', b);
end $$;
revoke all on function public.bingr_support_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_support_cleanup() to service_role;

-- build 95: account verwijderd -> ook de supporttickets (met berichten) van dat account. Security H1: alleen tickets die
-- echt bij het account horen (user_id: ingelogd aangemaakt of met de geheime link gekoppeld), nooit op e-mailadres;
-- gast-tickets met hetzelfde adres blijven staan. Aan te roepen door het beheer vóór het verwijderen van de gebruiker; de
-- trigger hieronder doet het ook vanzelf bij elk verwijderen uit auth.users (device-auth delete_account en het beheer).
create or replace function public.bingr_support_delete_user(uid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if uid is null then return 0; end if;
  delete from public.support_tickets t where t.user_id = uid;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.bingr_support_delete_user(uuid) from public, anon, authenticated;
grant execute on function public.bingr_support_delete_user(uuid) to service_role;
create or replace function public.bingr_support_user_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.bingr_support_delete_user(old.id);
  exception when others then
    -- het verwijderen van het account mag hier nooit op vastlopen
    raise warning 'supporttickets van % niet verwijderd: %', old.id, sqlerrm;
  end;
  return old;
end $$;
revoke all on function public.bingr_support_user_deleted() from public, anon, authenticated;
drop trigger if exists bingr_support_user_deleted on auth.users;
create trigger bingr_support_user_deleted before delete on auth.users
  for each row execute function public.bingr_support_user_deleted();

-- Statusmonitors voor support: de functie (meteen actief) en de site (staat uit tot support.bingr.online online is;
-- aanzetten in het beheer, tab Status).
insert into public.status_monitors (id, name_nl, name_en, grp, kind, target, keyword, interval_min, public, enabled, builtin, sort) values
  ('support',   'Supporttickets',               'Support tickets',              'server',  'fn',          'support',                                null,         5,  true,  true,  true, 45),
  ('site-sup',  'Supportsite',                  'Support site',                 'website', 'http',        'https://support.bingr.online/',          'content="support"', 5, true, false, true, 55)
on conflict (id) do nothing;
-- support.bingr.online staat online: de monitor Supportsite één keer aanzetten (daarna beslist het beheer)
do $$ begin
  if not exists (select 1 from public.bingr_migrations where name = 'support_site_monitor_on') then
    update public.status_monitors set enabled = true where id = 'site-sup';
    insert into public.bingr_migrations (name) values ('support_site_monitor_on');
  end if;
end $$;
-- Build 82: statuspagina, kortere namen voor de apps en Opslag (profielfoto's) niet meer openbaar (wel gecontroleerd, in het
-- beheer zichtbaar). Eén keer; daarna beslist het beheer (tab Status).
do $$ begin
  if not exists (select 1 from public.bingr_migrations where name = 'status_names_build82') then
    update public.status_monitors set name_nl = 'Android', name_en = 'Android' where id = 'apk';
    update public.status_monitors set name_nl = 'Samsung TV', name_en = 'Samsung TV' where id = 'wgt';
    update public.status_monitors set name_nl = 'Apple (iOS, iPadOS, tvOS, macOS)', name_en = 'Apple (iOS, iPadOS, tvOS, macOS)' where id = 'apple';
    update public.status_monitors set public = false where id = 'storage';
    insert into public.bingr_migrations (name) values ('status_names_build82');
  end if;
end $$;

-- ============================================================================================================
-- Statuspagina 2.0: meldingen (storingen en gepland onderhoud) met tijdlijn, getroffen onderdelen en abonnees.
-- Alleen de Edge Function `status` (service role) leest en schrijft hierin; het beheer gaat via de functie admin.
--   status_notices            één storing of onderhoud. kind: incident | maintenance.
--                             incident:    status investigating | identified | monitoring | resolved, impact none | minor | major | critical
--                             maintenance: status scheduled | in_progress | completed | cancelled (begin/einde volgen window_start/-end)
--                             auto = aangemaakt door een monitor; auto_resolve = sluit vanzelf als alle gekoppelde storingen voorbij zijn;
--                             edited = in het beheer aangepast (titel blijft dan staan)
--   status_notice_components  getroffen onderdelen (monitor-id) met impact degraded | partial | major | maintenance
--   status_notice_updates     tijdlijn: status + bericht (nl/en) + tijd
--   status_subscribers        e-mailabonnees (dubbele opt-in; één token voor bevestigen en afmelden)
--   status_mail_queue         te versturen meldingen (in porties, per run van de planning)
create table if not exists public.status_notices (
  id            bigserial primary key,
  kind          text not null default 'incident',
  title_nl      text not null,
  title_en      text not null default '',
  impact        text not null default 'minor',
  status        text not null default 'investigating',
  started_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  window_start  timestamptz,
  window_end    timestamptz,
  auto          boolean not null default false,
  auto_resolve  boolean not null default false,
  edited        boolean not null default false,
  notify        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
do $$ begin
  alter table public.status_notices add constraint status_notices_kind_chk check (kind in ('incident', 'maintenance'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.status_notices add constraint status_notices_impact_chk check (impact in ('none', 'minor', 'major', 'critical', 'maintenance'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.status_notices add constraint status_notices_status_chk check (status in
    ('investigating', 'identified', 'monitoring', 'resolved', 'scheduled', 'in_progress', 'completed', 'cancelled'));
exception when duplicate_object then null; end $$;
create index if not exists status_notices_started_idx on public.status_notices (started_at desc);
create index if not exists status_notices_open_idx on public.status_notices (kind, status) where resolved_at is null;
alter table public.status_notices enable row level security;
revoke all on public.status_notices from anon, authenticated;

create table if not exists public.status_notice_components (
  notice_id   bigint not null references public.status_notices(id) on delete cascade,
  monitor_id  text not null references public.status_monitors(id) on delete cascade,
  impact      text not null default 'major',
  primary key (notice_id, monitor_id)
);
do $$ begin
  alter table public.status_notice_components add constraint status_notice_components_impact_chk check (impact in ('degraded', 'partial', 'major', 'maintenance'));
exception when duplicate_object then null; end $$;
create index if not exists status_notice_components_monitor_idx on public.status_notice_components (monitor_id);
alter table public.status_notice_components enable row level security;
revoke all on public.status_notice_components from anon, authenticated;

create table if not exists public.status_notice_updates (
  id         bigserial primary key,
  notice_id  bigint not null references public.status_notices(id) on delete cascade,
  status     text not null,
  body_nl    text not null default '',
  body_en    text not null default '',
  auto       boolean not null default false,
  at         timestamptz not null default now()
);
create index if not exists status_notice_updates_notice_idx on public.status_notice_updates (notice_id, at desc);
alter table public.status_notice_updates enable row level security;
revoke all on public.status_notice_updates from anon, authenticated;

-- automatische storingen per monitor hangen aan een melding
alter table public.status_incidents add column if not exists notice_id bigint references public.status_notices(id) on delete set null;
create index if not exists status_incidents_notice_idx on public.status_incidents (notice_id) where notice_id is not null;

create table if not exists public.status_subscribers (
  id               bigserial primary key,
  email            text not null,
  lang             text not null default 'nl',
  token            text not null,
  confirmed_at     timestamptz,
  confirm_sent_at  timestamptz,
  last_sent_at     timestamptz,
  created_at       timestamptz not null default now()
);
create unique index if not exists status_subscribers_email_idx on public.status_subscribers (lower(email));
create unique index if not exists status_subscribers_token_idx on public.status_subscribers (token);
do $$ begin
  alter table public.status_subscribers add constraint status_subscribers_lang_chk check (lang in ('nl', 'en'));
exception when duplicate_object then null; end $$;
alter table public.status_subscribers enable row level security;
revoke all on public.status_subscribers from anon, authenticated;

create table if not exists public.status_mail_queue (
  id          bigserial primary key,
  notice_id   bigint not null references public.status_notices(id) on delete cascade,
  update_id   bigint references public.status_notice_updates(id) on delete cascade,
  created_at  timestamptz not null default now(),
  send_after  timestamptz not null default now(),
  cursor      bigint not null default 0,   -- laatst gemailde abonnee (id)
  sent        int not null default 0,
  failed      int not null default 0,
  cancelled   boolean not null default false,
  done_at     timestamptz
);
create index if not exists status_mail_queue_todo_idx on public.status_mail_queue (send_after) where done_at is null;
alter table public.status_mail_queue enable row level security;
revoke all on public.status_mail_queue from anon, authenticated;

-- één mailronde tegelijk (planning en beheer)
alter table public.status_runner add column if not exists mail_until timestamptz not null default 'epoch';
create or replace function public.bingr_status_mail_lock() returns boolean
language plpgsql security definer set search_path = public as $$
declare got int;
begin
  update public.status_runner set mail_until = now() + interval '75 seconds' where id = 1 and mail_until < now();
  get diagnostics got = row_count;
  return got > 0;
end $$;
create or replace function public.bingr_status_mail_unlock() returns void
language sql security definer set search_path = public as $$
  update public.status_runner set mail_until = 'epoch' where id = 1;
$$;

-- tellers voor het beheer
create or replace function public.bingr_status_subscriber_counts() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'confirmed', count(*) filter (where confirmed_at is not null),
    'pending',   count(*) filter (where confirmed_at is null),
    'nl',        count(*) filter (where confirmed_at is not null and lang = 'nl'),
    'en',        count(*) filter (where confirmed_at is not null and lang = 'en'),
    'last_7d',   count(*) filter (where confirmed_at > now() - interval '7 days'),
    'queue',     (select count(*) from public.status_mail_queue where done_at is null and not cancelled))
  from public.status_subscribers;
$$;

-- opruimen: onbevestigde aanmeldingen na 7 dagen, verwerkte mailrondes na 60 dagen
create or replace function public.bingr_status_cleanup2() returns void
language sql security definer set search_path = public as $$
  delete from public.status_subscribers where confirmed_at is null and created_at < now() - interval '7 days';
  delete from public.status_mail_queue where done_at is not null and done_at < now() - interval '60 days';
$$;
revoke all on function public.bingr_status_mail_lock() from public, anon, authenticated;
revoke all on function public.bingr_status_mail_unlock() from public, anon, authenticated;
revoke all on function public.bingr_status_subscriber_counts() from public, anon, authenticated;
revoke all on function public.bingr_status_cleanup2() from public, anon, authenticated;
grant execute on function public.bingr_status_mail_lock() to service_role;
grant execute on function public.bingr_status_mail_unlock() to service_role;
grant execute on function public.bingr_status_subscriber_counts() to service_role;
grant execute on function public.bingr_status_cleanup2() to service_role;

-- eenmalig: bestaande storingen van openbare monitors (laatste 90 dagen) als afgesloten melding, zodat de pagina
-- en de geschiedenis niet leeg beginnen
do $$
declare r record; nid bigint;
begin
  if exists (select 1 from public.bingr_migrations where name = 'status_notices_backfill') then return; end if;
  for r in select i.id, i.monitor_id, i.started_at, i.ended_at, m.name_nl, m.name_en
           from public.status_incidents i join public.status_monitors m on m.id = i.monitor_id
           where i.notice_id is null and i.ended_at is not null and i.started_at > now() - interval '90 days'
             and m.public and m.kind <> 'devices'
           order by i.started_at loop
    insert into public.status_notices (kind, title_nl, title_en, impact, status, started_at, resolved_at, auto, auto_resolve, notify, created_at, updated_at)
    values ('incident', 'Storing bij ' || r.name_nl, 'Outage affecting ' || r.name_en, 'major', 'resolved', r.started_at, r.ended_at, true, true, false, r.started_at, r.ended_at)
    returning id into nid;
    insert into public.status_notice_components (notice_id, monitor_id, impact) values (nid, r.monitor_id, 'major');
    insert into public.status_notice_updates (notice_id, status, body_nl, body_en, auto, at) values
      (nid, 'investigating', 'Onze monitoring zag dat ' || r.name_nl || ' niet bereikbaar was. We zochten het uit.',
            'Our monitoring detected that ' || r.name_en || ' was unavailable. We looked into it.', true, r.started_at),
      (nid, 'resolved', r.name_nl || ' werkt weer normaal.', r.name_en || ' is working normally again.', true, r.ended_at);
    update public.status_incidents set notice_id = nid where id = r.id;
  end loop;
  insert into public.bingr_migrations (name) values ('status_notices_backfill');
end $$;

-- ============================================================================================================
-- Abonnementen: Gratis en Lifetime (€ 4,99 eenmalig). Contract in docs/ACCOUNT.md ("Abonnementen").
-- Eén rij per account met een abonnement of eigen limieten; geen rij = gratis. Standaardlimieten staan in
-- supabase/functions/_shared/plans.ts (gratis: 1 stream, 8 apparaten, 1 server; lifetime: 3, 15, onbeperkt);
-- max_streams / max_devices = eigen limiet uit het beheer (null = standaard van het abonnement).
-- source: 'legacy' (bestaand account, cadeau bij de invoering), 'admin' (beheer) of 'purchase' (betaald).
-- De gebruiker leest alleen zijn eigen rij; schrijven doen alleen device-auth en admin (service role).
create table if not exists public.account_plans (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  plan        text not null default 'free' check (plan in ('free', 'lifetime')),
  max_streams int check (max_streams is null or max_streams between 1 and 50),
  max_devices int check (max_devices is null or max_devices between 1 and 200),
  source      text check (source is null or source in ('legacy', 'admin', 'purchase')),
  note        text check (note is null or char_length(note) <= 500),
  granted_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.account_plans enable row level security;
revoke all on public.account_plans from anon, authenticated;
grant select on public.account_plans to authenticated;
drop policy if exists "eigen abonnement lezen" on public.account_plans;
create policy "eigen abonnement lezen" on public.account_plans for select to authenticated using (user_id = auth.uid());
create index if not exists account_plans_plan_idx on public.account_plans (plan);

-- Instellingen van de apps (sleutel -> jsonb), alleen voor de functies (service role). upgrade_link: per platform of de
-- apps een link/knop naar bingr.online/upgrade/ tonen (apple = ios, ipados, tvos, macos). Bestaande waarden blijven staan.
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;
insert into public.app_settings (key, value) values
  ('upgrade_link', '{"apple": false, "android": true, "androidtv": true, "tizen": true, "web": true}'::jsonb)
on conflict (key) do nothing;

-- Eenmalig: alle accounts die bij de invoering al bestaan krijgen Lifetime cadeau (source 'legacy'). De markering
-- plans_legacy_done in app_settings zorgt dat een latere deploy nieuwe accounts (gratis) nooit Lifetime geeft.
do $$
declare n int;
begin
  if exists (select 1 from public.app_settings where key = 'plans_legacy_done') then return; end if;
  insert into public.account_plans (user_id, plan, source, note, granted_by)
  select u.id, 'lifetime', 'legacy', 'Bestaand account bij de invoering van abonnementen', 'systeem'
  from auth.users u where not exists (select 1 from public.account_plans p where p.user_id = u.id);
  get diagnostics n = row_count;
  insert into public.app_settings (key, value) values ('plans_legacy_done', jsonb_build_object('at', now(), 'accounts', n));
  raise notice 'Abonnementen: % bestaande accounts kregen Lifetime (legacy)', n;
end $$;

-- ============================================================================================================
-- build 133: betalen via Stripe (functies billing en stripe-webhook, docs/ACCOUNT.md "Betalen (Stripe, build 133)").
-- billing_purchases: één rij per Checkout Session van Lifetime. status: pending (afgerond, betaling nog onderweg), paid,
-- failed, refunded (volledig terugbetaald), disputed (chargeback). Geen e-mailadressen, namen of betaalgegevens: alleen het
-- account, de Stripe-id's, het bedrag en de status. De gebruiker leest alleen zijn eigen rijen; schrijven alleen de functies.
-- Account verwijderd: de aankoop blijft (fiscale bewaarplicht) met user_id null en user_deleted_at; zie "Bewaarplicht" hieronder.
-- >>> unittest billing
create table if not exists public.billing_purchases (
  id                bigint generated always as identity primary key,
  user_id           uuid references auth.users(id) on delete set null,
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
create index if not exists billing_purchases_user_idx on public.billing_purchases (user_id, created_at desc);
create index if not exists billing_purchases_pi_idx on public.billing_purchases (payment_intent) where payment_intent is not null;
create index if not exists billing_purchases_paid_idx on public.billing_purchases (paid_at) where paid_at is not null;
alter table public.billing_purchases enable row level security;
revoke all on public.billing_purchases from anon, authenticated;
grant select on public.billing_purchases to authenticated;
drop policy if exists "eigen aankopen lezen" on public.billing_purchases;
create policy "eigen aankopen lezen" on public.billing_purchases for select to authenticated using (user_id = auth.uid());
-- Verwerkte Stripe-events (idempotentie van de webhook). Alleen id, type en resultaat; na 90 dagen weg (bingr_billing_cleanup).
create table if not exists public.billing_events (
  id         text primary key check (id ~ '^evt_[A-Za-z0-9_]+$'),
  type       text not null,
  result     text,
  created_at timestamptz not null default now()
);
alter table public.billing_events enable row level security;
revoke all on public.billing_events from anon, authenticated;
create or replace function public.bingr_billing_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.billing_events where created_at < now() - interval '90 days';
$$;
revoke all on function public.bingr_billing_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_billing_cleanup() to service_role;
-- Beheer: aankopen in de gebruikerslijst en het overzicht (laatste aankoop per account: datum, bedrag, status)
create or replace function public.bingr_admin_purchase(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('purchased_at', coalesce(b.paid_at, b.created_at), 'amount', b.amount, 'currency', b.currency, 'status', b.status,
                            'refunded_at', b.refunded_at)
    from public.billing_purchases b where b.user_id = p_user and b.status in ('paid', 'refunded', 'disputed')
   order by coalesce(b.paid_at, b.created_at) desc limit 1
$$;
revoke all on function public.bingr_admin_purchase(uuid) from public, anon, authenticated;
grant execute on function public.bingr_admin_purchase(uuid) to service_role;

-- Beheer, tab Omzet (functie admin, actie revenue; bingr-beheer). Per aankoop ook de Stripe-kosten en het netto bedrag
-- (balance transaction), de btw volgens Stripe Tax (alleen met automatic_tax, anders null), het type betaalmethode en het
-- land (alleen landcode). De webhook vult dit bij betaling, bij charge.updated of via admin revenue_backfill. Geen
-- persoonsgegevens: geen kaartnummers, namen of adressen.
alter table public.billing_purchases
  add column if not exists charge_id      text check (charge_id is null or (charge_id ~ '^(ch|py)_[A-Za-z0-9_]+$' and char_length(charge_id) <= 255)),
  add column if not exists fee            int check (fee is null or fee >= 0),
  add column if not exists net_amount     int,
  add column if not exists tax_amount     int check (tax_amount is null or tax_amount >= 0),
  add column if not exists payment_method text check (payment_method is null or payment_method ~ '^[a-z_]{1,32}$'),
  add column if not exists country        text check (country is null or country ~ '^[A-Z]{2}$'),
  add column if not exists details_at     timestamptz;
-- Terugbetalingen (ook gedeeltelijk) en chargebacks: één rij per Stripe-id (re_…, dp_…; zonder Stripe-sleutel één rij per
-- charge ch_… met het totaal). Alleen bedrag, kosten (dispute fee) en moment. Alleen de functies (service role).
create table if not exists public.billing_refunds (
  id          text primary key check (id ~ '^(re|pyr|dp|du|ch|py)_[A-Za-z0-9_]+$' and char_length(id) <= 255),
  purchase_id bigint not null references public.billing_purchases(id) on delete cascade,
  kind        text not null check (kind in ('refund', 'dispute')),
  amount      int not null check (amount >= 0),
  fee         int not null default 0 check (fee >= 0),
  refunded_at timestamptz not null,
  created_at  timestamptz not null default now()
);
create index if not exists billing_refunds_purchase_idx on public.billing_refunds (purchase_id);
create index if not exists billing_refunds_at_idx on public.billing_refunds (refunded_at);
create index if not exists billing_purchases_nofee_idx on public.billing_purchases (paid_at) where fee is null and payment_intent is not null;
alter table public.billing_refunds enable row level security;
revoke all on public.billing_refunds from anon, authenticated;
-- terugbetalingen van vóór deze tabel: één rij per aankoop (volledig bedrag, op refunded_at)
insert into public.billing_refunds (id, purchase_id, kind, amount, refunded_at)
select 'ch_legacy_' || b.id, b.id, case when b.status = 'disputed' then 'dispute' else 'refund' end, b.amount, coalesce(b.refunded_at, b.updated_at)
  from public.billing_purchases b
 where b.status in ('refunded', 'disputed') and not exists (select 1 from public.billing_refunds r where r.purchase_id = b.id)
on conflict (id) do nothing;

-- Bewaarplicht (fiscaal, 7 jaar): aankopen en terugbetalingen blijven staan als het account wordt verwijderd (device-auth
-- delete_account, het beheer of het opruimen), maar zonder koppeling aan het account: user_id wordt null (on delete set
-- null) en user_deleted_at het moment van verwijderen (trigger hieronder). Er staan in deze tabellen geen e-mailadressen,
-- namen of adressen; de kwitantie-URL wordt niet bewaard (die haalt de functie billing live bij Stripe, alleen voor het
-- eigen account). Wat blijft: datum, bedrag, btw, Stripe-kosten, betaalmethode (soort), land (code), status en de
-- Stripe-id's (de boekhouding gaat uit van Stripe). RLS: user_id = auth.uid(), dus een rij zonder account ziet niemand.
-- Na 7 jaar na het einde van het boekjaar weg (bingr_billing_retention, dagelijks via bingr_support_cleanup).
-- Migratie (herhaalbaar): user_id mag leeg, de foreign key van on delete cascade naar on delete set null.
alter table public.billing_purchases add column if not exists user_deleted_at timestamptz;
alter table public.billing_purchases alter column user_id drop not null;
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.billing_purchases'::regclass and contype = 'f' and confrelid = 'auth.users'::regclass
              and confdeltype <> 'n' loop
    execute format('alter table public.billing_purchases drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'public.billing_purchases'::regclass and contype = 'f'
                    and confrelid = 'auth.users'::regclass and confdeltype = 'n') then
    alter table public.billing_purchases add constraint billing_purchases_user_id_fkey
      foreign key (user_id) references auth.users(id) on delete set null;
  end if;
end $$;
create index if not exists billing_purchases_unlinked_idx on public.billing_purchases (user_deleted_at) where user_id is null;
-- user_id van gevuld naar leeg (de foreign key bij het verwijderen van het account): moment vastleggen. Werkt voor elke
-- manier van verwijderen, want on delete set null is een update op deze tabel.
create or replace function public.bingr_billing_user_unlinked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.user_id is not null and new.user_id is null then
    new.user_deleted_at := coalesce(new.user_deleted_at, now());
    new.updated_at := now();
  end if;
  return new;
end $$;
revoke all on function public.bingr_billing_user_unlinked() from public, anon, authenticated;
drop trigger if exists bingr_billing_user_unlinked on public.billing_purchases;
create trigger bingr_billing_user_unlinked before update of user_id on public.billing_purchases
  for each row execute function public.bingr_billing_user_unlinked();
-- Bewaartermijn: 7 jaar na het einde van het boekjaar (kalenderjaar, Europe/Amsterdam) van het laatste moment van de
-- aankoop (aangemaakt, betaald, terugbetaald of een terugbetaling/chargeback in billing_refunds). Een aankoop uit 2026 mag
-- dus vanaf 1 januari 2034 weg. Alleen aankopen zonder account (bij een bestaand account blijven ze tot het account wordt
-- verwijderd); de terugbetalingen gaan mee (on delete cascade). Terug: aantal verwijderde aankopen.
create or replace function public.bingr_billing_retention(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = public as $$
declare cutoff timestamptz; n int;
begin
  cutoff := (date_trunc('year', p_now at time zone 'Europe/Amsterdam') - interval '7 years') at time zone 'Europe/Amsterdam';
  delete from public.billing_purchases b
   where b.user_id is null
     and greatest(b.created_at, b.paid_at, b.refunded_at) < cutoff
     and not exists (select 1 from public.billing_refunds r where r.purchase_id = b.id and r.refunded_at >= cutoff);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.bingr_billing_retention(timestamptz) from public, anon, authenticated;
grant execute on function public.bingr_billing_retention(timestamptz) to service_role;
-- btw-tarief voor de omzet zonder Stripe Tax (bedragen zijn incl. btw): btw = bruto × tarief / (100 + tarief). In te stellen
-- in het beheer (tab Omzet, actie revenue_vat_set); een bestaande waarde blijft staan.
insert into public.app_settings (key, value) values ('revenue_vat', '{"rate": 21}'::jsonb) on conflict (key) do nothing;

-- Btw-tarief (0–50, standaard 21) en het filter op modus (live = cs_live_…, test = cs_test_…, all) als SQL-stukken voor
-- de omzetfuncties hieronder. Intern (geen execute voor de API-rollen).
create or replace function public.bingr_revenue_rate() returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select case when (value->>'rate') ~ '^\d{1,2}(\.\d{1,2})?$' and (value->>'rate')::numeric <= 50
                               then (value->>'rate')::numeric end from public.app_settings where key = 'revenue_vat'), 21)
$$;
revoke all on function public.bingr_revenue_rate() from public, anon, authenticated, service_role;
create or replace function public.bingr_revenue_filter(p_mode text) returns text
language sql immutable set search_path = '' as $$
  select case p_mode when 'live' then ' and b.stripe_session_id like ''cs\_live\_%''' when 'test' then ' and b.stripe_session_id like ''cs\_test\_%''' else '' end
$$;
revoke all on function public.bingr_revenue_filter(text) from public, anon, authenticated, service_role;

-- Totalen van één tijdvak: aankopen op paid_at (ook als ze later zijn terugbetaald), terugbetalingen/chargebacks op hun
-- eigen moment. Btw per aankoop: Stripe Tax (tax_amount) als bekend, anders bruto × tarief / (100 + tarief); van een
-- terugbetaling het evenredige deel. Alleen aantallen en bedragen (centen, eur), plus verdeling per betaalmethode en land.
create or replace function public.bingr_revenue_sum(p_from timestamptz, p_to timestamptz, p_mode text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb; rate numeric := public.bingr_revenue_rate(); f text := public.bingr_revenue_filter(p_mode); vat text;
begin
  vat := format('coalesce(b.tax_amount, round(b.amount * %s / (100 + %s)))', rate, rate);
  execute format($q$
    with p as (select b.amount, b.fee, b.tax_amount, b.payment_method, b.country, (%2$s)::bigint vat from public.billing_purchases b
                where b.status in ('paid', 'refunded', 'disputed') and b.currency = 'eur' and b.paid_at >= $1 and b.paid_at < $2 %1$s),
         r as (select r.amount, r.fee, r.kind, round(r.amount::numeric * (%2$s) / nullif(b.amount, 0))::bigint vat
                 from public.billing_refunds r join public.billing_purchases b on b.id = r.purchase_id
                where b.currency = 'eur' and r.refunded_at >= $1 and r.refunded_at < $2 %1$s)
    select jsonb_build_object(
      'count', (select count(*) from p), 'gross', (select coalesce(sum(amount), 0) from p), 'vat', (select coalesce(sum(vat), 0) from p),
      'fees', (select coalesce(sum(fee), 0) from p) + (select coalesce(sum(fee), 0) from r),
      'refunds', (select coalesce(sum(amount), 0) from r), 'refunds_vat', (select coalesce(sum(vat), 0) from r),
      'refund_count', (select count(*) from r where kind = 'refund'), 'dispute_count', (select count(*) from r where kind = 'dispute'),
      'missing_fees', (select count(*) from p where fee is null), 'with_tax', (select count(*) from p where tax_amount is not null),
      'by_method', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'count', c, 'gross', g) order by g desc, k), '[]'::jsonb)
                      from (select coalesce(payment_method, '?') k, count(*) c, sum(amount) g from p group by 1) x),
      'by_country', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'count', c, 'gross', g) order by g desc, k), '[]'::jsonb)
                       from (select coalesce(country, '?') k, count(*) c, sum(amount) g from p group by 1) x))
  $q$, f, vat) into res using p_from, p_to;
  return res;
end $$;
revoke all on function public.bingr_revenue_sum(timestamptz, timestamptz, text) from public, anon, authenticated, service_role;

-- p_edges: grenzen van de tijdvakken (zoals bingr_admin_insights); p_mode: live | test | all; p_ranges: [{key, from, to}]
-- (max. 8) voor de tegels (deze maand, vorige maand, dit jaar, totaal) en de gekozen periode. Antwoord: {rate, live_count,
-- test_count, series: {count, gross, vat, fees, refunds, refunds_vat, refund_count: [per tijdvak]}, ranges: {key: totalen}}.
create or replace function public.bingr_admin_revenue(p_edges timestamptz[], p_mode text default 'all', p_ranges jsonb default '[]'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n int := coalesce(array_length(p_edges, 1), 0) - 1; rate numeric := public.bingr_revenue_rate(); f text; vat text;
        paid text; refs text; rg jsonb; ranges jsonb := '{}'::jsonb;
begin
  if n < 1 or n > 1000 or array_position(p_edges, null) is not null then return null; end if;
  if exists (select 1 from generate_series(1, n) i where p_edges[i] >= p_edges[i + 1]) then return null; end if;
  if p_mode is null or p_mode not in ('live', 'test', 'all') then return null; end if;
  if jsonb_typeof(p_ranges) <> 'array' or jsonb_array_length(p_ranges) > 8 then return null; end if;
  f := public.bingr_revenue_filter(p_mode);
  vat := format('coalesce(b.tax_amount, round(b.amount * %s / (100 + %s)))', rate, rate);
  paid := 'from public.billing_purchases b where b.status in (''paid'', ''refunded'', ''disputed'') and b.currency = ''eur''
            and b.paid_at >= $2 and b.paid_at < $3' || f;
  refs := 'from public.billing_refunds r join public.billing_purchases b on b.id = r.purchase_id where b.currency = ''eur''
            and r.refunded_at >= $2 and r.refunded_at < $3' || f;
  for rg in select * from jsonb_array_elements(p_ranges) loop
    if coalesce(rg->>'key', '') !~ '^[a-z_]{1,20}$' or (rg->>'from') is null or (rg->>'to') is null then return null; end if;
    ranges := ranges || jsonb_build_object(rg->>'key', public.bingr_revenue_sum((rg->>'from')::timestamptz, (rg->>'to')::timestamptz, p_mode));
  end loop;
  return jsonb_build_object(
    'rate', rate,
    'live_count', (select count(*) from public.billing_purchases b where b.status in ('paid', 'refunded', 'disputed') and b.stripe_session_id like 'cs\_live\_%'),
    'test_count', (select count(*) from public.billing_purchases b where b.status in ('paid', 'refunded', 'disputed') and b.stripe_session_id like 'cs\_test\_%'),
    'series', jsonb_build_object(
      'count', public.bingr_insights_bin(p_edges, 'select b.paid_at, 1 ' || paid),
      'gross', public.bingr_insights_bin(p_edges, 'select b.paid_at, b.amount ' || paid),
      'vat', public.bingr_insights_bin(p_edges, format('select b.paid_at, %s ', vat) || paid),
      'fees', public.bingr_insights_bin(p_edges, 'select b.paid_at, coalesce(b.fee, 0) ' || paid || ' union all select r.refunded_at, r.fee ' || refs),
      'refunds', public.bingr_insights_bin(p_edges, 'select r.refunded_at, r.amount ' || refs),
      'refunds_vat', public.bingr_insights_bin(p_edges, format('select r.refunded_at, round(r.amount::numeric * (%s) / nullif(b.amount, 0)) ', vat) || refs),
      'refund_count', public.bingr_insights_bin(p_edges, 'select r.refunded_at, 1 ' || refs)),
    'ranges', ranges);
end $$;
revoke all on function public.bingr_admin_revenue(timestamptz[], text, jsonb) from public, anon, authenticated;
grant execute on function public.bingr_admin_revenue(timestamptz[], text, jsonb) to service_role;

-- CSV-export van de tab Omzet: per aankoop (paid_at in de periode) en per terugbetaling/chargeback (op dat moment) alleen
-- datum, soort, bedrag, btw, kosten, methode en land; geen account, e-mail, naam of Stripe-id. Max. 5000 rijen.
create or replace function public.bingr_admin_revenue_rows(p_from timestamptz, p_to timestamptz, p_mode text default 'all') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb; rate numeric := public.bingr_revenue_rate(); f text; vat text;
begin
  if p_from is null or p_to is null or p_from >= p_to or p_mode is null or p_mode not in ('live', 'test', 'all') then return null; end if;
  f := public.bingr_revenue_filter(p_mode);
  vat := format('coalesce(b.tax_amount, round(b.amount * %s / (100 + %s)))', rate, rate);
  execute format($q$
    select coalesce(jsonb_agg(x.j order by x.at), '[]'::jsonb) from (
      select u.at, u.j from (
        select b.paid_at at, jsonb_build_object('at', b.paid_at, 'kind', 'purchase', 'amount', b.amount, 'vat', (%2$s)::bigint, 'fee', b.fee,
                 'method', b.payment_method, 'country', b.country, 'tax', b.tax_amount is not null) j
          from public.billing_purchases b
         where b.status in ('paid', 'refunded', 'disputed') and b.currency = 'eur' and b.paid_at >= $1 and b.paid_at < $2 %1$s
        union all
        select r.refunded_at, jsonb_build_object('at', r.refunded_at, 'kind', r.kind, 'amount', -r.amount,
                 'vat', -round(r.amount::numeric * (%2$s) / nullif(b.amount, 0))::bigint, 'fee', r.fee,
                 'method', b.payment_method, 'country', b.country, 'tax', b.tax_amount is not null)
          from public.billing_refunds r join public.billing_purchases b on b.id = r.purchase_id
         where b.currency = 'eur' and r.refunded_at >= $1 and r.refunded_at < $2 %1$s) u
      order by u.at limit 5000) x
  $q$, f, vat) into res using p_from, p_to;
  return res;
end $$;
revoke all on function public.bingr_admin_revenue_rows(timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.bingr_admin_revenue_rows(timestamptz, timestamptz, text) to service_role;
-- <<< unittest billing

-- build 97: beheer (functie admin in LRvdLinden/bingr-beheer). Tokenversie: elk beheer-token draagt de versie v; de functie
-- admin vergelijkt die bij elk verzoek met deze rij. "Overal uitloggen" (actie logout_all) verhoogt de versie, en een ander
-- wachtwoord ook vanzelf: pw_hash is een sleutel-hash (HMAC met de service-role-sleutel) van BINGR_ADMIN_PASSWORD, nooit het
-- wachtwoord zelf. Eén rij (id = 1); alleen de service role.
create table if not exists public.admin_token_state (
  id         int primary key default 1 check (id = 1),
  version    int not null default 1,
  pw_hash    text,
  updated_at timestamptz not null default now()
);
alter table public.admin_token_state enable row level security;
revoke all on public.admin_token_state from anon, authenticated;
insert into public.admin_token_state (id) values (1) on conflict do nothing;

-- build 97: huidige tokenversie; is het wachtwoord (p_pw_hash) anders dan het opgeslagen, dan eerst de versie ophogen
-- (alle bestaande tokens vervallen). Gewoonlijk alleen een lees-actie zonder slot.
create or replace function public.bingr_admin_token_version(p_pw_hash text) returns int
language plpgsql security definer set search_path = public as $$
declare r public.admin_token_state%rowtype;
begin
  select * into r from public.admin_token_state where id = 1;
  if found and (p_pw_hash is null or r.pw_hash = p_pw_hash) then return r.version; end if;
  insert into public.admin_token_state (id) values (1) on conflict do nothing;
  select * into r from public.admin_token_state where id = 1 for update;
  if p_pw_hash is null or r.pw_hash = p_pw_hash then return r.version; end if;
  if r.pw_hash is null then
    update public.admin_token_state set pw_hash = p_pw_hash, updated_at = now() where id = 1;
    return r.version;
  end if;
  update public.admin_token_state set version = version + 1, pw_hash = p_pw_hash, updated_at = now() where id = 1
  returning version into r.version;
  return r.version;
end $$;
-- build 97: overal uitloggen: versie + 1, alle beheer-tokens (web en app) vervallen meteen
create or replace function public.bingr_admin_logout_all() returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into public.admin_token_state (id) values (1) on conflict do nothing;
  update public.admin_token_state set version = version + 1, updated_at = now() where id = 1 returning version into v;
  return v;
end $$;
revoke all on function public.bingr_admin_token_version(text) from public, anon, authenticated;
revoke all on function public.bingr_admin_logout_all() from public, anon, authenticated;
grant execute on function public.bingr_admin_token_version(text) to service_role;
grant execute on function public.bingr_admin_logout_all() to service_role;

-- build 97: bulkmail per ontvanger bijhouden. bingr_announce_claim schoof de cursor meteen door: stopte de functie midden
-- in een batch, dan kreeg de rest van die batch nooit een mail. Nu krijgt elke geclaimde ontvanger een rij 'sending' met
-- tijdstip; na elke verzonden mail zet bingr_announce_mark hem op 'sent' of 'failed' (en telt mee). Een rij die langer dan
-- 10 minuten op 'sending' staat (functie gestopt), komt in een volgende batch opnieuw aan de beurt. 'skipped' = intussen
-- afgemeld of zonder bevestigd adres. Gaat mee met het bericht (en met het account).
create table if not exists public.announcement_sends (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  state           text not null default 'sending' check (state in ('sending', 'sent', 'failed', 'skipped')),
  claimed_at      timestamptz not null default now(),
  done_at         timestamptz,
  primary key (announcement_id, user_id)
);
create index if not exists announcement_sends_sending_idx on public.announcement_sends (announcement_id, claimed_at) where state = 'sending';
alter table public.announcement_sends enable row level security;
revoke all on public.announcement_sends from anon, authenticated;

-- build 97: volgende batch: eerst vastgelopen rijen (> 10 min 'sending'), dan nieuwe ontvangers vanaf de cursor.
-- -> {items:[{id,email,lang,first_name}], done, busy}. busy = er lopen nog verzendingen van een andere aanroep (even wachten).
-- Klaar (email_done_at) pas als de cursor op is en niemand meer op 'sending' staat.
create or replace function public.bingr_announce_take(p_id uuid, p_batch int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare a record; n int := greatest(least(coalesce(p_batch, 25), 100), 1); ids uuid[] := '{}'; more uuid[]; last_id uuid; rows jsonb;
begin
  select * into a from public.announcements where id = p_id for update;
  if not found or not a.email or a.email_done_at is not null then
    return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false);
  end if;
  -- 1. vastgelopen rijen opnieuw claimen
  with s as (
    select user_id from public.announcement_sends
    where announcement_id = p_id and state = 'sending' and claimed_at < now() - interval '10 minutes'
    order by claimed_at limit n for update skip locked),
  u as (
    update public.announcement_sends x set claimed_at = now() from s
    where x.announcement_id = p_id and x.user_id = s.user_id returning x.user_id)
  select coalesce(array_agg(u.user_id), '{}') into ids from u;
  -- 2. aanvullen met nieuwe ontvangers vanaf de cursor
  if coalesce(array_length(ids, 1), 0) < n then
    select coalesce(array_agg(r.id order by r.id), '{}'), max(r.id::text)::uuid into more, last_id from (
      select u.id from auth.users u
      where u.email is not null and u.email_confirmed_at is not null
        and (a.email_cursor is null or u.id > a.email_cursor)
        and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and p.email_opt_out)
      order by u.id limit n - coalesce(array_length(ids, 1), 0)) r;
    if last_id is not null then
      insert into public.announcement_sends (announcement_id, user_id) select p_id, x from unnest(more) x
      on conflict (announcement_id, user_id) do nothing;
      update public.announcements set email_cursor = last_id where id = p_id;
      ids := ids || more;
    end if;
  end if;
  -- intussen afgemeld of zonder bevestigd adres: overslaan
  update public.announcement_sends s set state = 'skipped', done_at = now()
  where s.announcement_id = p_id and s.user_id = any(ids) and s.state = 'sending'
    and not exists (select 1 from auth.users u where u.id = s.user_id and u.email is not null and u.email_confirmed_at is not null
                    and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and p.email_opt_out));
  -- first_name: voor de aanhef "Hoi <voornaam>," in de mail (beheer)
  select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'lang', u.raw_user_meta_data->>'lang',
    'first_name', nullif(btrim(u.raw_user_meta_data->>'first_name'), '')) order by u.id) into rows
  from auth.users u join public.announcement_sends s on s.user_id = u.id and s.announcement_id = p_id and s.state = 'sending'
  where u.id = any(ids);
  if rows is not null then return jsonb_build_object('items', rows, 'done', false, 'busy', false); end if;
  if exists (select 1 from public.announcement_sends where announcement_id = p_id and state = 'sending') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', false, 'busy', true);
  end if;
  update public.announcements set email_done_at = now() where id = p_id;
  return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false);
end $$;
-- build 97: resultaat per ontvanger (na elke mail): 'sending' -> 'sent' / 'failed', en de tellers van het bericht.
-- Alleen rijen die nog op 'sending' staan tellen (dubbel melden telt niet dubbel). -> zelfde vorm als bingr_announce_report.
create or replace function public.bingr_announce_mark(p_id uuid, p_sent uuid[], p_failed uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; nf int;
begin
  update public.announcement_sends set state = 'sent', done_at = now()
  where announcement_id = p_id and state = 'sending' and user_id = any(coalesce(p_sent, '{}'));
  get diagnostics ns = row_count;
  update public.announcement_sends set state = 'failed', done_at = now()
  where announcement_id = p_id and state = 'sending' and user_id = any(coalesce(p_failed, '{}'));
  get diagnostics nf = row_count;
  return public.bingr_announce_report(p_id, ns, nf);
end $$;
revoke all on function public.bingr_announce_take(uuid, int) from public, anon, authenticated;
revoke all on function public.bingr_announce_mark(uuid, uuid[], uuid[]) from public, anon, authenticated;
grant execute on function public.bingr_announce_take(uuid, int) to service_role;
grant execute on function public.bingr_announce_mark(uuid, uuid[], uuid[]) to service_role;

-- ---- Voor- en achternaam van het account (user_metadata first_name / last_name) ----
-- De apps en sites vragen ze bij het aanmaken van een account (docs/ACCOUNT.md); bestaande accounts vult de eigenaar in via
-- het beheer. Mails beginnen dan met "Hoi <voornaam>," (functies support, status en admin; accountmails via {{ .Data.first_name }}).
-- Opschonen zoals de apps en sites (BingrAuth.cleanName, Account.cleanName, personName() in functions/_shared/layout.ts):
-- stuurtekens en < > weg, witruimte samengevoegd, getrimd, max. 50 tekens; leeg = geen naam.
-- >>> unittest person-name
create or replace function public.bingr_clean_person_name(p text) returns text
language sql immutable set search_path = public as $$
  select nullif(btrim(left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[\x01-\x1f\x7f<>]', '', 'g'), '\s+', ' ', 'g')), 50)), '')
$$;
-- build 134: naamregel, ook gebruikt door de hook bingr_before_user_created: link of e-mailadres (://, www., @), < of >,
-- of langer dan 50 tekens.
create or replace function public.bingr_person_name_invalid(p text) returns boolean
language sql immutable set search_path = public as $$
  select p is not null and (p ~* '(://|www\.|@|<|>)' or char_length(btrim(regexp_replace(p, '\s+', ' ', 'g'))) > 50)
$$;
revoke all on function public.bingr_person_name_invalid(text) from public, anon, authenticated;
-- Trigger op auth.users: naam opschonen bij het opslaan, en weigeren als er een link, e-mailadres of HTML in staat of hij
-- langer is dan 50 tekens (de accountmail bij het aanmaken toont de naam al, ook voor een adres dat nog niet bevestigd is).
-- Build 138: haalt ook hp en fill_ms (honeypot en tijdmeting van de webformulieren, alleen voor de hook) uit de metadata.
-- De apps en sites sturen alleen opgeschoonde namen; een geweigerde naam geeft bij Supabase Auth een foutmelding (geen account).
-- Foutcode PT400 (build 136; was 22023 = HTTP 500): Supabase Auth geeft een SQLSTATE "PTnnn" door als HTTP-status nnn, met
-- {code:"PT400", message, detail (= first_name/last_name), hint:"bingr_invalid_name"}. Dat geldt alleen voor aanroepen zonder
-- header X-Supabase-Api-Version (curl, URLSession, OkHttp); supabase-js stuurt "2024-01-01" en krijgt van Auth altijd 500
-- "Error updating user" (unexpected_failure). Zie docs/ACCOUNT.md, "Voor- en achternaam".
create or replace function public.bingr_user_names() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; raw jsonb; v text; c text;
begin
  if new.raw_user_meta_data is null or jsonb_typeof(new.raw_user_meta_data) <> 'object' then return new; end if;
  -- build 138: honeypot en tijdmeting van de webformulieren zijn alleen voor de hook bingr_before_user_created; niet bewaren
  new.raw_user_meta_data := new.raw_user_meta_data - 'hp' - 'fill_ms';
  foreach k in array array['first_name', 'last_name'] loop
    raw := new.raw_user_meta_data -> k;
    continue when raw is null;
    continue when tg_op = 'UPDATE' and raw is not distinct from (old.raw_user_meta_data -> k);
    if jsonb_typeof(raw) = 'null' then new.raw_user_meta_data := new.raw_user_meta_data - k; continue; end if;
    v := case when jsonb_typeof(raw) = 'string' then raw #>> '{}' end;
    if v is null or public.bingr_person_name_invalid(v) then
      raise exception 'Names cannot contain links, email addresses or HTML.'
        using errcode = 'PT400', detail = k, hint = 'bingr_invalid_name';
    end if;
    c := public.bingr_clean_person_name(v);
    new.raw_user_meta_data := case when c is null then new.raw_user_meta_data - k else jsonb_set(new.raw_user_meta_data, array[k], to_jsonb(c)) end;
  end loop;
  return new;
end $$;
revoke all on function public.bingr_user_names() from public, anon, authenticated;
drop trigger if exists bingr_user_names on auth.users;
create trigger bingr_user_names before insert or update of raw_user_meta_data on auth.users
  for each row execute function public.bingr_user_names();
-- <<< unittest person-name
-- Voornamen bij e-mailadressen (functie status: abonnees hebben geen account-id). Alleen bevestigde accounts met een naam;
-- max. 200 adressen per aanroep; alleen voor de service role.
create or replace function public.bingr_first_names(p_emails text[]) returns table(email text, first_name text)
language sql stable security definer set search_path = public, auth as $$
  select lower(u.email)::text, public.bingr_clean_person_name(u.raw_user_meta_data->>'first_name')
  from auth.users u
  where u.email = any (array(select lower(e) from unnest(coalesce(p_emails, '{}'::text[])) e limit 200))
    and u.email_confirmed_at is not null
    and public.bingr_clean_person_name(u.raw_user_meta_data->>'first_name') is not null
$$;
revoke all on function public.bingr_first_names(text[]) from public, anon, authenticated;
grant execute on function public.bingr_first_names(text[]) to service_role;

-- ============================================================================================================
-- Pushmeldingen (docs/PUSH.md): APNs, FCM en Web Push via de Edge Function `push`. Alleen de service role (de functie)
-- leest en schrijft hierin; RLS staat aan zonder policies en anon/authenticated hebben geen rechten.
create table if not exists public.push_devices (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  device_id   text not null,
  platform    text not null,
  channel     text not null check (channel in ('apns', 'fcm', 'webpush')),
  token       text not null,
  lang        text not null default 'en',
  tz          text,
  app_version text,
  app_build   int,
  sandbox     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  last_error  text,
  unique (user_id, device_id),
  unique (channel, token)
);
alter table public.push_devices enable row level security;
revoke all on public.push_devices from anon, authenticated;

-- Eén rij per bericht. dedup_key: release:<groep>:<build> (één releasemelding per build) of reminder:<account>:<herinnering-id>.
-- counts = {queued, sent, failed, invalid, errors:{code: aantal}}, bijgewerkt na elke batch (bingr_push_refresh).
create table if not exists public.push_messages (
  id             bigint generated always as identity primary key,
  kind           text not null check (kind in ('release', 'admin', 'reminder')),
  title_nl       text,
  body_nl        text,
  title_en       text,
  body_en        text,
  url            text,
  payload        jsonb not null default '{}'::jsonb,
  target         jsonb not null default '{}'::jsonb,
  platform_group text,
  build          int,
  dedup_key      text unique,
  devices        int not null default 0,
  counts         jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now(),
  created_by     text,
  finished_at    timestamptz
);
create index if not exists push_messages_kind_idx on public.push_messages (kind, id desc);
alter table public.push_messages enable row level security;
revoke all on public.push_messages from anon, authenticated;

-- Eén rij per bericht per apparaat; uniek per (bericht, apparaat), dus ook per (herinnering, apparaat).
-- state: queued -> (sending) -> sent | failed | invalid (token verlopen, apparaat opgeruimd).
create table if not exists public.push_deliveries (
  id          bigint generated always as identity primary key,
  message_id  bigint not null references public.push_messages(id) on delete cascade,
  device_ref  bigint references public.push_devices(id) on delete set null,
  user_id     uuid references auth.users(id) on delete cascade,
  platform    text not null,
  channel     text not null,
  state       text not null default 'queued' check (state in ('queued', 'sending', 'sent', 'failed', 'invalid')),
  attempts    int not null default 0,
  error       text,
  claimed_at  timestamptz,
  next_at     timestamptz,
  sent_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (message_id, device_ref)
);
create index if not exists push_deliveries_open_idx on public.push_deliveries (id) where state in ('queued', 'sending');
create index if not exists push_deliveries_msg_idx on public.push_deliveries (message_id, state);
create index if not exists push_deliveries_dev_idx on public.push_deliveries (device_ref);
alter table public.push_deliveries enable row level security;
revoke all on public.push_deliveries from anon, authenticated;

-- Apparaat uit het account verwijderd (device-auth remove_device, beheer): zijn push-registratie gaat mee.
-- Account verwijderd: cascade via auth.users.
create or replace function public.bingr_push_device_removed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.push_devices where user_id = old.user_id and device_id = old.device_id;
  return old;
end $$;
revoke all on function public.bingr_push_device_removed() from public, anon, authenticated;
drop trigger if exists bingr_push_device_removed on public.account_devices;
create trigger bingr_push_device_removed after delete on public.account_devices
  for each row execute function public.bingr_push_device_removed();

-- Apparaten van de doelgroep in de wachtrij zetten (idempotent). p_below_build: alleen app_build < build (onbekend telt als 0).
create or replace function public.bingr_push_enqueue(p_message bigint, p_all boolean, p_accounts uuid[], p_platforms text[], p_below_build int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.push_deliveries (message_id, device_ref, user_id, platform, channel)
  select p_message, d.id, d.user_id, d.platform, d.channel
  from public.push_devices d
  where (coalesce(p_all, false) or p_accounts is not null or p_platforms is not null)
    and (p_accounts is null or d.user_id = any (p_accounts))
    and (p_platforms is null or d.platform = any (p_platforms))
    and (p_below_build is null or coalesce(d.app_build, 0) < p_below_build)
  on conflict (message_id, device_ref) do nothing;
  get diagnostics n = row_count;
  update public.push_messages set devices = devices + n, finished_at = null where id = p_message and n > 0;
  return n;
end $$;

-- Een batch claimen (skip locked: twee gelijktijdige aanroepen pakken nooit dezelfde rij). Een rij die langer dan 3 minuten
-- op 'sending' staat (functie afgebroken) komt opnieuw aan de beurt.
create or replace function public.bingr_push_claim(p_limit int, p_message bigint default null)
returns table (id bigint, message_id bigint, device_ref bigint, attempts int)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with c as (
    select q.id from public.push_deliveries q
    where ((q.state = 'queued' and (q.next_at is null or q.next_at <= now()))
           or (q.state = 'sending' and q.claimed_at < now() - interval '3 minutes'))
      and (p_message is null or q.message_id = p_message)
    order by q.id
    limit greatest(1, least(coalesce(p_limit, 200), 1000))
    for update skip locked
  )
  update public.push_deliveries d set state = 'sending', claimed_at = now(), attempts = d.attempts + 1
  from c where d.id = c.id
  returning d.id, d.message_id, d.device_ref, d.attempts;
end $$;

-- Tellingen per bericht bijwerken (en finished_at zodra niets meer wacht).
create or replace function public.bingr_push_refresh(p_ids bigint[]) returns void
language sql security definer set search_path = public as $$
  update public.push_messages m set
    counts = s.counts,
    finished_at = case when (s.counts->>'queued')::int = 0 then coalesce(m.finished_at, now()) else null end
  from (
    select m2.id,
      jsonb_build_object(
        'queued',  count(d.id) filter (where d.state in ('queued', 'sending')),
        'sent',    count(d.id) filter (where d.state = 'sent'),
        'failed',  count(d.id) filter (where d.state = 'failed'),
        'invalid', count(d.id) filter (where d.state = 'invalid'),
        'errors',  coalesce((select jsonb_object_agg(e.error, e.n) from (
                     select d2.error, count(*) n from public.push_deliveries d2
                     where d2.message_id = m2.id and d2.error is not null and d2.state in ('failed', 'invalid')
                     group by d2.error order by count(*) desc limit 10) e), '{}'::jsonb)
      ) counts
    from public.push_messages m2 left join public.push_deliveries d on d.message_id = m2.id
    where m2.id = any (p_ids)
    group by m2.id
  ) s
  where m.id = s.id;
$$;

-- Resultaten van een batch in één keer verwerken: [{id, state, error, tok?}] (state sent|failed|invalid|queued).
-- invalid: het apparaat (token) wordt verwijderd; de bezorging blijft staan voor de telling.
create or replace function public.bingr_push_finish(p_results jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare ids bigint[];
begin
  with r as (select * from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(id bigint, state text, error text))
  update public.push_deliveries d set
    state = case when r.state in ('sent', 'failed', 'invalid', 'queued') then r.state else 'failed' end,
    error = left(r.error, 120),
    sent_at = case when r.state = 'sent' then now() else d.sent_at end,
    next_at = case when r.state = 'queued' then now() + interval '1 minute' else null end,  -- tijdelijke fout: over een minuut opnieuw
    claimed_at = null
  from r where d.id = r.id;
  update public.push_devices p set last_error = left(x.error, 120)
  from public.push_deliveries d, jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(id bigint, state text, error text)
  where d.id = x.id and p.id = d.device_ref and x.state = 'failed';
  -- alleen als de token intussen niet vernieuwd is (tok = de token waarmee verstuurd is)
  delete from public.push_devices p using public.push_deliveries d, jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(id bigint, state text, error text, tok text)
  where d.id = x.id and p.id = d.device_ref and x.state = 'invalid' and p.token = x.tok;
  select array_agg(distinct d.message_id) into ids from public.push_deliveries d
  where d.id in (select (e->>'id')::bigint from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) e);
  if ids is not null then perform public.bingr_push_refresh(ids); end if;
end $$;

-- Accounts met minstens één push-apparaat (voor de herinneringen in de cron), in pagina's.
create or replace function public.bingr_push_users(p_after uuid default null, p_limit int default 500) returns table (user_id uuid)
language sql stable security definer set search_path = public as $$
  select distinct d.user_id from public.push_devices d
  where p_after is null or d.user_id > p_after
  order by d.user_id limit greatest(1, least(coalesce(p_limit, 500), 2000));
$$;

-- Opruimen (dagelijks, pg_cron bingr-push-cleanup): herinneringsberichten na 3 dagen, overige berichten na 400 dagen,
-- details per apparaat na 30 dagen (de tellingen blijven op het bericht), apparaten die 270 dagen niet registreerden.
create or replace function public.bingr_push_cleanup() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.push_messages where kind = 'reminder' and created_at < now() - interval '3 days';
  delete from public.push_messages where created_at < now() - interval '400 days';
  delete from public.push_deliveries where created_at < now() - interval '30 days' and state not in ('queued', 'sending');
  delete from public.push_devices where updated_at < now() - interval '270 days';
  -- build 133: verwerkte Stripe-events na 90 dagen (de aankopen zelf blijven)
  if to_regclass('public.billing_events') is not null then delete from public.billing_events where created_at < now() - interval '90 days'; end if;
end $$;

revoke all on function public.bingr_push_enqueue(bigint, boolean, uuid[], text[], int) from public, anon, authenticated;
revoke all on function public.bingr_push_claim(int, bigint) from public, anon, authenticated;
revoke all on function public.bingr_push_refresh(bigint[]) from public, anon, authenticated;
revoke all on function public.bingr_push_finish(jsonb) from public, anon, authenticated;
revoke all on function public.bingr_push_users(uuid, int) from public, anon, authenticated;
revoke all on function public.bingr_push_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_push_enqueue(bigint, boolean, uuid[], text[], int) to service_role;
grant execute on function public.bingr_push_claim(int, bigint) to service_role;
grant execute on function public.bingr_push_refresh(bigint[]) to service_role;
grant execute on function public.bingr_push_finish(jsonb) to service_role;
grant execute on function public.bingr_push_users(uuid, int) to service_role;
grant execute on function public.bingr_push_cleanup() to service_role;

-- ============================================================================================================
-- Build 117: pushdiensten op de statuspagina (groep Server). Eén keer klaargezet; daarna beslist het beheer (tab Status).
-- push       = de eigen functie push (actie vapid_key moet de publieke Web Push-sleutel geven)
-- push-apple = pushdienst voor iPhone, iPad en Mac (api.push.apple.com bereikbaar via HTTPS; elk HTTP-antwoord = up)
-- push-android = pushdienst voor Android en de webspeler in Chrome (fcm.googleapis.com bereikbaar)
insert into public.status_monitors (id, name_nl, name_en, grp, kind, target, keyword, interval_min, public, enabled, builtin, sort) values
  ('push',         'Pushmeldingen',                  'Push notifications',                'server', 'push',  '',                              null, 5, true, true, true, 70),
  ('push-apple',   'Pushmeldingen Apple-apparaten',  'Push notifications Apple devices',  'server', 'reach', 'https://api.push.apple.com/',   null, 5, true, true, true, 72),
  ('push-android', 'Pushmeldingen Android',          'Push notifications Android',        'server', 'reach', 'https://fcm.googleapis.com/',   null, 5, true, true, true, 74)
on conflict (id) do nothing;

-- ============================================================================================================
-- Pushmeldingen naar de beheer-app Bingr Beheer (bundle nl.lrvdlinden.bingr.beheer; iOS, iPadOS en Mac via Catalyst, APNs).
-- docs/PUSH.md, "Beheer-app". De functie admin (bingr-beheer) upsert apparaten met de service role op device_id; de cron van
-- de functie push leest ze en verstuurt (tickets, antwoorden, builds, status). Geen accounts: alleen beheerders hebben de app.
create table if not exists public.admin_push_devices (
  id          bigint generated always as identity primary key,
  device_id   text not null unique,
  token       text not null unique,
  platform    text not null check (platform in ('ios', 'ipados', 'macos')),
  sandbox     boolean not null default false,
  prefs       jsonb not null default '{"tickets":true,"replies":true,"builds":true,"status":true}'::jsonb,
  app_build   int,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  last_error  text
);
alter table public.admin_push_devices enable row level security;
revoke all on public.admin_push_devices from anon, authenticated;

-- Watermerken (één rij, id = 1): wat de beheer-app al gemeld kreeg. Ontbreekt de rij of een veld, dan zet de cron het op de
-- huidige stand zonder te melden (geen stortvloed aan oude meldingen). builds = {platform: build}, monitors =
-- {monitor-id: {s: "up"|"down", since}}; builds_checked_at = laatste keer dat het manifest is opgehaald (hoogstens elke 5 min).
create table if not exists public.admin_push_state (
  id                 int primary key default 1 check (id = 1),
  last_ticket_number bigint,
  last_message_id    bigint,
  builds             jsonb,
  monitors           jsonb,
  builds_checked_at  timestamptz,
  updated_at         timestamptz not null default now()
);
alter table public.admin_push_state add column if not exists builds_checked_at timestamptz;
-- build 133: watermerk voor "Nieuwe Lifetime-aankoop" (billing_purchases.paid_at)
alter table public.admin_push_state add column if not exists last_purchase_at timestamptz;
alter table public.admin_push_state enable row level security;
revoke all on public.admin_push_state from anon, authenticated;

-- ---- Nieuwsbrief (functie newsletter, docs/NEWSLETTER.md) ----
-- Zondag 09:00 en woensdag 18:00 (Europe/Amsterdam) "wat is nieuw aan films en series" naar ingeschreven leden.
-- Ingeschreven = bevestigd e-mailadres, niet geblokkeerd, geen email_opt_out en geen newsletter_opt_out. Nieuwe accounts
-- zijn automatisch ingeschreven (geen rij in account_email_prefs = ingeschreven). Het beheer (bingr-beheer) leest en zet
-- account_email_prefs.newsletter_opt_out rechtstreeks.
alter table public.account_email_prefs add column if not exists newsletter_opt_out boolean not null default false;

-- Aan/uit (één rij, id = 1). Standaard UIT: de cron verstuurt niets zolang enabled = false.
create table if not exists public.newsletter_settings (
  id         int primary key default 1 check (id = 1),
  enabled    boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.newsletter_settings (id) values (1) on conflict (id) do nothing;
alter table public.newsletter_settings enable row level security;
revoke all on public.newsletter_settings from anon, authenticated;

-- Eén rij per editie (edition_key uniek, bv. 2026-10-18-sun): de inhoud per taal ({nl:{featured,fresh,soon,popular}, en:…})
-- wordt bij het aanmaken vastgelegd, zodat iedereen dezelfde mail krijgt en de volgende edities kunnen ontdubbelen.
-- cursor = laatste account-id dat aan de wachtrij is toegevoegd.
create table if not exists public.newsletter_editions (
  id          bigint generated always as identity primary key,
  edition_key text not null unique,
  created_at  timestamptz not null default now(),
  content     jsonb not null,
  recipients  int not null default 0,
  sent        int not null default 0,
  failed      int not null default 0,
  cursor      uuid,
  finished_at timestamptz
);
create index if not exists newsletter_editions_created_idx on public.newsletter_editions (created_at desc);
alter table public.newsletter_editions enable row level security;
revoke all on public.newsletter_editions from anon, authenticated;

-- Per (editie, account) één rij: nooit twee mails van dezelfde editie naar hetzelfde account. 'queued' = tijdelijke
-- SMTP-fout, later opnieuw (max. 3 pogingen); een rij die langer dan 30 minuten op 'sending' staat (functie gestopt
-- tijdens het versturen) wordt 'failed' en NIET opnieuw verstuurd (dan liever een mail te weinig dan dubbel).
create table if not exists public.newsletter_deliveries (
  edition_id bigint not null references public.newsletter_editions(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  state      text not null default 'sending' check (state in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  attempts   int not null default 1,
  claimed_at timestamptz not null default now(),
  done_at    timestamptz,
  primary key (edition_id, user_id)
);
create index if not exists newsletter_deliveries_open_idx on public.newsletter_deliveries (edition_id, state) where state in ('queued', 'sending');
alter table public.newsletter_deliveries enable row level security;
revoke all on public.newsletter_deliveries from anon, authenticated;

-- Ingeschreven voor de nieuwsbrief?
create or replace function public.bingr_news_subscribed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users u
    where u.id = p_user and u.email is not null and u.email_confirmed_at is not null and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now())
      and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and (p.email_opt_out or p.newsletter_opt_out)));
$$;
-- Aantal ingeschreven ontvangers per taal (nl = lang leeg of nl*, anders en).
create or replace function public.bingr_news_recipients() returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select jsonb_build_object('nl', count(*) filter (where l = 'nl'), 'en', count(*) filter (where l = 'en'), 'total', count(*)) from (
    select case when coalesce(u.raw_user_meta_data->>'lang', '') = '' or lower(u.raw_user_meta_data->>'lang') like 'nl%' then 'nl' else 'en' end as l
    from auth.users u
    where u.email is not null and u.email_confirmed_at is not null and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now())
      and not exists (select 1 from public.account_email_prefs p where p.user_id = u.id and (p.email_opt_out or p.newsletter_opt_out))) x;
$$;
-- Volgende batch van een editie -> {items:[{id,email,lang,first_name}], done, busy}. Eerst 'queued' (opnieuw proberen),
-- dan nieuwe ontvangers vanaf de cursor. Klaar (finished_at) als de cursor op is en niets meer open staat.
create or replace function public.bingr_news_take(p_edition bigint, p_batch int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare e record; n int := greatest(least(coalesce(p_batch, 50), 500), 1); ids uuid[] := '{}'; more uuid[]; last_id uuid; rows jsonb; f int;
begin
  select * into e from public.newsletter_editions where id = p_edition for update;
  if not found or e.finished_at is not null then return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false); end if;
  -- vastgelopen verzendingen: failed (nooit opnieuw, kan al verstuurd zijn)
  update public.newsletter_deliveries set state = 'failed', done_at = now()
  where edition_id = p_edition and state = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics f = row_count;
  if f > 0 then update public.newsletter_editions set failed = failed + f where id = p_edition; end if;
  with s as (
    select user_id from public.newsletter_deliveries where edition_id = p_edition and state = 'queued'
    order by claimed_at limit n for update skip locked),
  u as (
    update public.newsletter_deliveries d set state = 'sending', claimed_at = now(), attempts = d.attempts + 1 from s
    where d.edition_id = p_edition and d.user_id = s.user_id returning d.user_id)
  select coalesce(array_agg(u.user_id), '{}') into ids from u;
  if coalesce(array_length(ids, 1), 0) < n then
    select coalesce(array_agg(r.id order by r.id), '{}'), max(r.id::text)::uuid into more, last_id from (
      select u.id from auth.users u
      where (e.cursor is null or u.id > e.cursor) and u.email is not null and u.email_confirmed_at is not null
      order by u.id limit n - coalesce(array_length(ids, 1), 0)) r;
    if last_id is not null then
      insert into public.newsletter_deliveries (edition_id, user_id) select p_edition, x from unnest(more) x
      on conflict (edition_id, user_id) do nothing;
      update public.newsletter_editions set cursor = last_id where id = p_edition;
      ids := ids || more;
    end if;
  end if;
  -- intussen afgemeld, geblokkeerd of zonder bevestigd adres: overslaan
  update public.newsletter_deliveries d set state = 'skipped', done_at = now()
  where d.edition_id = p_edition and d.user_id = any(ids) and d.state = 'sending' and not public.bingr_news_subscribed(d.user_id);
  select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'lang', u.raw_user_meta_data->>'lang',
    'first_name', nullif(btrim(u.raw_user_meta_data->>'first_name'), '')) order by u.id) into rows
  from auth.users u join public.newsletter_deliveries d on d.user_id = u.id and d.edition_id = p_edition and d.state = 'sending'
  where u.id = any(ids);
  if rows is not null then return jsonb_build_object('items', rows, 'done', false, 'busy', false); end if;
  if exists (select 1 from public.newsletter_deliveries where edition_id = p_edition and state = 'sending') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', false, 'busy', true);
  end if;
  if coalesce(array_length(ids, 1), 0) > 0 or exists (select 1 from public.newsletter_deliveries where edition_id = p_edition and state = 'queued') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', false, 'busy', false);
  end if;
  update public.newsletter_editions set finished_at = now() where id = p_edition;
  return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false);
end $$;
-- Resultaat van een batch: sent / failed / retry (tijdelijke fout: terug naar 'queued', na 3 pogingen failed) / release
-- (niet aan toegekomen: terug naar 'queued' zonder dat het als poging telt).
create or replace function public.bingr_news_mark(p_edition bigint, p_sent uuid[], p_failed uuid[], p_retry uuid[], p_release uuid[] default '{}')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; nf int; nr int;
begin
  update public.newsletter_deliveries set state = 'queued', attempts = greatest(attempts - 1, 0)
  where edition_id = p_edition and state = 'sending' and user_id = any(coalesce(p_release, '{}'));
  update public.newsletter_deliveries set state = 'sent', done_at = now()
  where edition_id = p_edition and state = 'sending' and user_id = any(coalesce(p_sent, '{}'));
  get diagnostics ns = row_count;
  update public.newsletter_deliveries set state = 'failed', done_at = now()
  where edition_id = p_edition and state = 'sending' and (user_id = any(coalesce(p_failed, '{}'))
    or (user_id = any(coalesce(p_retry, '{}')) and attempts >= 3));
  get diagnostics nf = row_count;
  update public.newsletter_deliveries set state = 'queued'
  where edition_id = p_edition and state = 'sending' and user_id = any(coalesce(p_retry, '{}'));
  get diagnostics nr = row_count;
  update public.newsletter_editions set sent = sent + ns, failed = failed + nf where id = p_edition;
  return jsonb_build_object('sent', ns, 'failed', nf, 'retry', nr);
end $$;
-- Opruimen: wachtrij van edities ouder dan 90 dagen weg (de tellers in newsletter_editions blijven).
create or replace function public.bingr_news_cleanup() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.newsletter_deliveries d using public.newsletter_editions e
  where d.edition_id = e.id and e.created_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.bingr_news_subscribed(uuid) from public, anon, authenticated;
revoke all on function public.bingr_news_recipients() from public, anon, authenticated;
revoke all on function public.bingr_news_take(bigint, int) from public, anon, authenticated;
revoke all on function public.bingr_news_mark(bigint, uuid[], uuid[], uuid[], uuid[]) from public, anon, authenticated;
revoke all on function public.bingr_news_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_news_subscribed(uuid) to service_role;
grant execute on function public.bingr_news_recipients() to service_role;
grant execute on function public.bingr_news_take(bigint, int) to service_role;
grant execute on function public.bingr_news_mark(bigint, uuid[], uuid[], uuid[], uuid[]) to service_role;
grant execute on function public.bingr_news_cleanup() to service_role;

-- ---- Welkomstmail (functie newsletter, actie welcome_cron; docs/NEWSLETTER.md, sectie Welkomstmail) ----
-- Eén rij per account dat een welkomstmail kreeg (of krijgt): sent_at = verstuurd; error = korte foutcode (smtp_550, stuck)
-- of 'existing' (bij de eerste uitrol al bestaand lid: nooit een welkomstmail); een rij zonder sent_at en error = bezig.
-- Bij de EERSTE uitrol (tabel bestond nog niet) worden alle bevestigde accounts als 'existing' gemarkeerd, zodat alleen
-- nieuwe leden een welkomstmail krijgen. Daarna is dit blok een no-op.
do $$
begin
  if to_regclass('public.account_welcome') is null then
    create table public.account_welcome (
      user_id    uuid primary key references auth.users(id) on delete cascade,
      claimed_at timestamptz not null default now(),
      sent_at    timestamptz,
      error      text check (error is null or error ~ '^[a-z0-9_]{1,40}$')
    );
    insert into public.account_welcome (user_id, sent_at, error)
      select u.id, null, 'existing' from auth.users u where u.email_confirmed_at is not null
      on conflict (user_id) do nothing;
  end if;
end $$;
create index if not exists account_welcome_sent_idx on public.account_welcome (sent_at) where sent_at is not null;
alter table public.account_welcome enable row level security;
revoke all on public.account_welcome from anon, authenticated;

-- Volgende batch (max. 200, de functie vraagt 50) -> [{id, email, lang, first_name, newsletter}], meteen geclaimd met een rij.
-- Bevestigd in de laatste 7 dagen, niet verwijderd, niet geblokkeerd, nog geen rij. email_opt_out telt hier NIET (de
-- welkomstmail is transactioneel); `newsletter` = ingeschreven voor de nieuwsbrief (dan staat die alinea in de mail).
-- Een claim die 30 minuten blijft hangen wordt 'stuck' en niet opnieuw verstuurd (liever geen mail dan twee).
create or replace function public.bingr_welcome_take(p_batch int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare n int := greatest(least(coalesce(p_batch, 50), 200), 1); rows jsonb;
begin
  update public.account_welcome set error = 'stuck' where sent_at is null and error is null and claimed_at < now() - interval '30 minutes';
  with c as (
    select u.id from auth.users u
    where u.email is not null and u.email_confirmed_at is not null and u.email_confirmed_at > now() - interval '7 days'
      and u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
      and not exists (select 1 from public.account_welcome w where w.user_id = u.id)
    order by u.email_confirmed_at limit n),
  ins as (
    insert into public.account_welcome (user_id) select id from c on conflict (user_id) do nothing returning user_id)
  select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'lang', u.raw_user_meta_data->>'lang',
    'first_name', nullif(btrim(u.raw_user_meta_data->>'first_name'), ''),
    'newsletter', public.bingr_news_subscribed(u.id)) order by u.email_confirmed_at) into rows
  from auth.users u join ins on ins.user_id = u.id;
  return coalesce(rows, '[]'::jsonb);
end $$;
-- Resultaat: sent -> sent_at; failed -> error = code (niet opnieuw); retry (tijdelijke fout / niet aan toegekomen) -> rij weg,
-- de volgende ronde opnieuw (binnen de 7 dagen).
create or replace function public.bingr_welcome_mark(p_sent uuid[], p_failed uuid[], p_codes text[], p_retry uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; nf int; nr int;
begin
  update public.account_welcome set sent_at = now(), error = null
  where sent_at is null and user_id = any(coalesce(p_sent, '{}'));
  get diagnostics ns = row_count;
  update public.account_welcome w set error = case when f.code ~ '^[a-z0-9_]{1,40}$' then f.code else 'error' end
  from unnest(coalesce(p_failed, '{}'), coalesce(p_codes, '{}')) as f(id, code)
  where w.user_id = f.id and w.sent_at is null;
  get diagnostics nf = row_count;
  delete from public.account_welcome where sent_at is null and error is null and user_id = any(coalesce(p_retry, '{}'));
  get diagnostics nr = row_count;
  return jsonb_build_object('sent', ns, 'failed', nf, 'retry', nr);
end $$;
-- Aantallen voor het beheer: verstuurd in de laatste 7 dagen en wachtend (zou nu een welkomstmail krijgen).
create or replace function public.bingr_welcome_counts() returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select jsonb_build_object(
    'sent_7d', (select count(*) from public.account_welcome w where w.sent_at > now() - interval '7 days'),
    'pending', (select count(*) from auth.users u
      where u.email is not null and u.email_confirmed_at is not null and u.email_confirmed_at > now() - interval '7 days'
        and u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
        and not exists (select 1 from public.account_welcome w where w.user_id = u.id)));
$$;
revoke all on function public.bingr_welcome_take(int) from public, anon, authenticated;
revoke all on function public.bingr_welcome_mark(uuid[], uuid[], text[], uuid[]) from public, anon, authenticated;
revoke all on function public.bingr_welcome_counts() from public, anon, authenticated;
grant execute on function public.bingr_welcome_take(int) to service_role;
grant execute on function public.bingr_welcome_mark(uuid[], uuid[], text[], uuid[]) to service_role;
grant execute on function public.bingr_welcome_counts() to service_role;

-- ---- Eigen mailing vanuit het beheer (functie newsletter, acties mailing_*; docs/NEWSLETTER.md, "Eigen mailing vanuit het beheer") ----
-- De beheerder stelt in bingr-beheer (tab Nieuwsbrief) een mail op in NL en EN en kiest de doelgroep:
--   newsletter = nieuwsbrief-abonnees (zelfde regels als bingr_news_subscribed: geen email_opt_out en geen newsletter_opt_out)
--   service    = servicebericht aan alle accounts met een bevestigd adres (ook na afmelden voor de nieuwsbrief of alle
--                berichten); alleen voor belangrijke service-informatie (voorwaarden, storingen), nooit reclame.
-- Altijd: bevestigd e-mailadres, niet verwijderd, niet (nu) geblokkeerd. Taal: user_metadata.lang leeg of nl* -> nl, anders en.
-- Bij het versturen wordt de lijst ontvangers één keer vastgelegd in mailing_recipients (primaire sleutel mailing + account:
-- iedereen hoogstens één mail per mailing). De functie newsletter verstuurt in batches (pg_cron bingr-mailing, elke 5
-- minuten, met een limiet per uur) en controleert vlak voor het versturen nog een keer de doelgroep. Geen adressen in
-- deze tabellen; het beheer ziet alleen onderwerpen en aantallen.
-- >>> unittest mailing
create table if not exists public.mailings (
  id               bigint generated always as identity primary key,
  request_id       uuid not null unique,
  created_at       timestamptz not null default now(),
  audience         text not null check (audience in ('newsletter', 'service')),
  content          jsonb not null,
  status           text not null default 'sending' check (status in ('sending', 'done', 'cancelled')),
  recipients       int not null default 0,
  recipients_nl    int not null default 0,
  recipients_en    int not null default 0,
  sent             int not null default 0,
  failed           int not null default 0,
  skipped          int not null default 0,
  cancelled        int not null default 0,
  finished_at      timestamptz,
  push_notified_at timestamptz
);
create index if not exists mailings_created_idx on public.mailings (created_at desc);
-- hoogstens één mailing tegelijk aan het versturen
create unique index if not exists mailings_one_active_idx on public.mailings ((true)) where status = 'sending';
alter table public.mailings enable row level security;
revoke all on public.mailings from anon, authenticated;

-- state: queued (wacht; ook na een tijdelijke SMTP-fout, max. 3 pogingen) -> sending (geclaimd) -> sent | failed |
-- skipped (intussen niet meer in de doelgroep) | cancelled (mailing geannuleerd). Een rij die 30 minuten op sending blijft
-- (functie gestopt tijdens het versturen) wordt failed en NIET opnieuw verstuurd (liever één mail te weinig dan dubbel).
create table if not exists public.mailing_recipients (
  mailing_id bigint not null references public.mailings(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  lang       text not null check (lang in ('nl', 'en')),
  state      text not null default 'queued' check (state in ('queued', 'sending', 'sent', 'failed', 'skipped', 'cancelled')),
  attempts   int not null default 0,
  claimed_at timestamptz,
  done_at    timestamptz,
  primary key (mailing_id, user_id)
);
create index if not exists mailing_recipients_open_idx on public.mailing_recipients (mailing_id, state) where state in ('queued', 'sending');
create index if not exists mailing_recipients_done_idx on public.mailing_recipients (done_at) where state in ('sent', 'failed');
alter table public.mailing_recipients enable row level security;
revoke all on public.mailing_recipients from anon, authenticated;

-- Doelgroep: (account, taal). Zelfde regels als eligible() in supabase/functions/newsletter/mailing.ts.
create or replace function public.bingr_mailing_audience(p_audience text) returns table (user_id uuid, lang text)
language sql stable security definer set search_path = public, auth as $$
  select u.id,
    case when coalesce(u.raw_user_meta_data->>'lang', '') = '' or lower(u.raw_user_meta_data->>'lang') like 'nl%' then 'nl' else 'en' end
  from auth.users u
  where p_audience in ('newsletter', 'service')
    and u.email is not null and u.email_confirmed_at is not null and u.deleted_at is null
    and (u.banned_until is null or u.banned_until <= now())
    and (p_audience = 'service' or not exists (select 1 from public.account_email_prefs p
      where p.user_id = u.id and (p.email_opt_out or p.newsletter_opt_out)));
$$;
-- Hoort één account (nog) bij de doelgroep? (vlak voor het versturen)
create or replace function public.bingr_mailing_eligible(p_user uuid, p_audience text) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users u
    where u.id = p_user and p_audience in ('newsletter', 'service')
      and u.email is not null and u.email_confirmed_at is not null and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now())
      and (p_audience = 'service' or not exists (select 1 from public.account_email_prefs p
        where p.user_id = u.id and (p.email_opt_out or p.newsletter_opt_out))));
$$;
-- Aantallen per taal -> {nl, en, total}
create or replace function public.bingr_mailing_count(p_audience text) returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select jsonb_build_object('nl', count(*) filter (where a.lang = 'nl'), 'en', count(*) filter (where a.lang = 'en'), 'total', count(*))
  from public.bingr_mailing_audience(p_audience) a;
$$;

-- Mailing aanmaken en de ontvangers vastleggen -> {id, duplicate, recipients:{nl, en, total}} of {error}. Idempotent:
-- dezelfde request_id (uuid van het beheer per verzendopdracht) geeft de bestaande mailing terug in plaats van een tweede.
-- Fouten: bad_audience, no_recipients, mailing_busy (er wordt al een mailing verstuurd).
create or replace function public.bingr_mailing_create(p_request uuid, p_audience text, p_content jsonb) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare m record; mid bigint; nl int; en int;
begin
  if p_request is null then return jsonb_build_object('error', 'bad_request_id'); end if;
  if p_audience is null or p_audience not in ('newsletter', 'service') then return jsonb_build_object('error', 'bad_audience'); end if;
  if p_content is null or jsonb_typeof(p_content) <> 'object' then return jsonb_build_object('error', 'bad_content'); end if;
  select * into m from public.mailings where request_id = p_request;
  if found then
    return jsonb_build_object('id', m.id, 'duplicate', true,
      'recipients', jsonb_build_object('nl', m.recipients_nl, 'en', m.recipients_en, 'total', m.recipients));
  end if;
  if exists (select 1 from public.mailings where status = 'sending') then return jsonb_build_object('error', 'mailing_busy'); end if;
  select count(*) filter (where a.lang = 'nl'), count(*) filter (where a.lang = 'en') into nl, en
  from public.bingr_mailing_audience(p_audience) a;
  if nl + en = 0 then return jsonb_build_object('error', 'no_recipients'); end if;
  insert into public.mailings (request_id, audience, content) values (p_request, p_audience, p_content)
  on conflict do nothing returning id into mid;
  if mid is null then
    -- tegelijk aangemaakt: dezelfde opdracht (request_id) of een andere mailing is net begonnen
    select * into m from public.mailings where request_id = p_request;
    if found then
      return jsonb_build_object('id', m.id, 'duplicate', true,
        'recipients', jsonb_build_object('nl', m.recipients_nl, 'en', m.recipients_en, 'total', m.recipients));
    end if;
    return jsonb_build_object('error', 'mailing_busy');
  end if;
  insert into public.mailing_recipients (mailing_id, user_id, lang)
  select mid, a.user_id, a.lang from public.bingr_mailing_audience(p_audience) a
  on conflict (mailing_id, user_id) do nothing;
  select count(*) filter (where r.lang = 'nl'), count(*) filter (where r.lang = 'en') into nl, en
  from public.mailing_recipients r where r.mailing_id = mid;
  update public.mailings set recipients = nl + en, recipients_nl = nl, recipients_en = en where id = mid;
  return jsonb_build_object('id', mid, 'duplicate', false, 'recipients', jsonb_build_object('nl', nl, 'en', en, 'total', nl + en));
end $$;

-- Volgende batch -> {items:[{id, email, lang, first_name}], done, busy}. Claimt 'queued'-rijen (state 'sending', poging + 1);
-- wie intussen niet meer bij de doelgroep hoort (afgemeld, geblokkeerd, verwijderd) wordt 'skipped'. Niets meer open:
-- de mailing is klaar (status done, finished_at).
create or replace function public.bingr_mailing_take(p_mailing bigint, p_batch int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare m record; n int := greatest(least(coalesce(p_batch, 50), 200), 1); ids uuid[]; f int; s int; rows jsonb;
begin
  select * into m from public.mailings where id = p_mailing for update;
  if not found or m.status <> 'sending' then return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false); end if;
  update public.mailing_recipients set state = 'failed', done_at = now()
  where mailing_id = p_mailing and state = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics f = row_count;
  with c as (
    select r.user_id from public.mailing_recipients r where r.mailing_id = p_mailing and r.state = 'queued'
    order by r.user_id limit n for update skip locked),
  u as (
    update public.mailing_recipients r set state = 'sending', claimed_at = now(), attempts = r.attempts + 1 from c
    where r.mailing_id = p_mailing and r.user_id = c.user_id returning r.user_id)
  select coalesce(array_agg(u.user_id), '{}') into ids from u;
  update public.mailing_recipients r set state = 'skipped', done_at = now()
  where r.mailing_id = p_mailing and r.user_id = any(ids) and r.state = 'sending'
    and not public.bingr_mailing_eligible(r.user_id, m.audience);
  get diagnostics s = row_count;
  if f + s > 0 then update public.mailings set failed = failed + f, skipped = skipped + s where id = p_mailing; end if;
  select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'lang', r.lang,
    'first_name', nullif(btrim(u.raw_user_meta_data->>'first_name'), '')) order by u.id) into rows
  from public.mailing_recipients r join auth.users u on u.id = r.user_id
  where r.mailing_id = p_mailing and r.user_id = any(ids) and r.state = 'sending';
  if rows is not null then return jsonb_build_object('items', rows, 'done', false, 'busy', false); end if;
  if exists (select 1 from public.mailing_recipients where mailing_id = p_mailing and state = 'sending') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', false, 'busy', true);
  end if;
  if exists (select 1 from public.mailing_recipients where mailing_id = p_mailing and state = 'queued') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', false, 'busy', false);
  end if;
  update public.mailings set status = 'done', finished_at = now() where id = p_mailing and status = 'sending';
  return jsonb_build_object('items', '[]'::jsonb, 'done', true, 'busy', false);
end $$;

-- Resultaat van een batch: sent / failed / retry (tijdelijke fout: terug naar queued, na 3 pogingen failed) / release
-- (niet aan toegekomen: terug naar queued zonder dat het als poging telt). Alleen rijen die op 'sending' staan.
create or replace function public.bingr_mailing_mark(p_mailing bigint, p_sent uuid[], p_failed uuid[], p_retry uuid[], p_release uuid[] default '{}')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; nf int; nr int;
begin
  update public.mailing_recipients set state = 'queued', attempts = greatest(attempts - 1, 0)
  where mailing_id = p_mailing and state = 'sending' and user_id = any(coalesce(p_release, '{}'));
  update public.mailing_recipients set state = 'sent', done_at = now()
  where mailing_id = p_mailing and state = 'sending' and user_id = any(coalesce(p_sent, '{}'));
  get diagnostics ns = row_count;
  update public.mailing_recipients set state = 'failed', done_at = now()
  where mailing_id = p_mailing and state = 'sending' and (user_id = any(coalesce(p_failed, '{}'))
    or (user_id = any(coalesce(p_retry, '{}')) and attempts >= 3));
  get diagnostics nf = row_count;
  update public.mailing_recipients set state = 'queued'
  where mailing_id = p_mailing and state = 'sending' and user_id = any(coalesce(p_retry, '{}'));
  get diagnostics nr = row_count;
  update public.mailings set sent = sent + ns, failed = failed + nf where id = p_mailing;
  -- geannuleerd terwijl deze batch liep: wat nu weer 'queued' staat gaat ook niet meer
  update public.mailing_recipients r set state = 'cancelled', done_at = now()
  from public.mailings m where m.id = p_mailing and m.status = 'cancelled' and r.mailing_id = p_mailing and r.state = 'queued';
  get diagnostics nr = row_count;
  if nr > 0 then update public.mailings set cancelled = cancelled + nr where id = p_mailing; end if;
  return jsonb_build_object('sent', ns, 'failed', nf);
end $$;

-- Annuleren zolang de mailing nog niet klaar is: wat nog in de wachtrij staat gaat niet meer; een batch die nu loopt
-- maakt zijn mails af. -> {ok, cancelled} | {ok:false, error:'not_active'}
create or replace function public.bingr_mailing_cancel(p_mailing bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.mailings set status = 'cancelled', finished_at = now() where id = p_mailing and status = 'sending';
  if not found then return jsonb_build_object('ok', false, 'error', 'not_active'); end if;
  update public.mailing_recipients set state = 'cancelled', done_at = now() where mailing_id = p_mailing and state = 'queued';
  get diagnostics n = row_count;
  update public.mailings set cancelled = cancelled + n where id = p_mailing;
  return jsonb_build_object('ok', true, 'cancelled', n);
end $$;

-- Mails (verstuurd of mislukt) van alle mailings in het laatste uur: voor de limiet per uur.
create or replace function public.bingr_mailing_sent_last_hour() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.mailing_recipients where state in ('sent', 'failed') and done_at > now() - interval '1 hour';
$$;
-- Open rijen (queued of sending) van een mailing: "te gaan" in het beheer.
create or replace function public.bingr_mailing_open(p_mailing bigint) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.mailing_recipients where mailing_id = p_mailing and state in ('queued', 'sending');
$$;
-- Opruimen: ontvangerslijsten van mailings die langer dan 90 dagen klaar zijn (de tellers in mailings blijven).
create or replace function public.bingr_mailing_cleanup() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.mailing_recipients r using public.mailings m
  where r.mailing_id = m.id and m.status <> 'sending' and m.finished_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.bingr_mailing_audience(text) from public, anon, authenticated;
revoke all on function public.bingr_mailing_eligible(uuid, text) from public, anon, authenticated;
revoke all on function public.bingr_mailing_count(text) from public, anon, authenticated;
revoke all on function public.bingr_mailing_create(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.bingr_mailing_take(bigint, int) from public, anon, authenticated;
revoke all on function public.bingr_mailing_mark(bigint, uuid[], uuid[], uuid[], uuid[]) from public, anon, authenticated;
revoke all on function public.bingr_mailing_cancel(bigint) from public, anon, authenticated;
revoke all on function public.bingr_mailing_sent_last_hour() from public, anon, authenticated;
revoke all on function public.bingr_mailing_open(bigint) from public, anon, authenticated;
revoke all on function public.bingr_mailing_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_mailing_audience(text) to service_role;
grant execute on function public.bingr_mailing_eligible(uuid, text) to service_role;
grant execute on function public.bingr_mailing_count(text) to service_role;
grant execute on function public.bingr_mailing_create(uuid, text, jsonb) to service_role;
grant execute on function public.bingr_mailing_take(bigint, int) to service_role;
grant execute on function public.bingr_mailing_mark(bigint, uuid[], uuid[], uuid[], uuid[]) to service_role;
grant execute on function public.bingr_mailing_cancel(bigint) to service_role;
grant execute on function public.bingr_mailing_sent_last_hour() to service_role;
grant execute on function public.bingr_mailing_open(bigint) to service_role;
grant execute on function public.bingr_mailing_cleanup() to service_role;
grant select, insert, update, delete on public.mailings, public.mailing_recipients to service_role;
-- <<< unittest mailing

-- ============================================================================================================
-- Insights in het beheer (tab Overzicht van bingr-beheer, functie admin, actie insights): aantallen per tijdvak voor de
-- grafieken. De functie admin rekent de grenzen van de tijdvakken uit (Europe/Amsterdam, per 5 min / uur / dag / maand) en
-- stuurt ze als oplopende lijst p_edges (n+1 momenten = n tijdvakken). Terug komt per serie een lijst van n aantallen, of
-- null als de serie hier niet te tellen is. Nooit gegevens per persoon: alleen tellingen per tijdvak.
-- Hulpje (niet aan te roepen van buiten): telt de rijen (at, w) van een vaste query uit bingr_admin_insights per tijdvak;
-- in die query is $1 = p_edges, $2 = begin, $3 = einde.
-- >>> unittest insights-bin
create or replace function public.bingr_insights_bin(p_edges timestamptz[], p_sql text) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare n int := array_length(p_edges, 1) - 1; res jsonb;
begin
  execute format(
    'select coalesce(jsonb_agg(coalesce(c.v, 0) order by g.i), ''[]''::jsonb)
       from generate_series(1, %s) g(i)
       left join (select width_bucket(s.at, $1) i, sum(s.w)::bigint v from (%s) s(at, w)
                   where s.at >= $2 and s.at < $3 group by 1) c on c.i = g.i', n, p_sql)
    into res using p_edges, p_edges[1], p_edges[n + 1];
  return res;
end $$;
revoke all on function public.bingr_insights_bin(timestamptz[], text) from public, anon, authenticated, service_role;
-- <<< unittest insights-bin

-- p_metric: accounts (new_users; active_users alleen met p_daily) | signins | streams (live, movie, episode) |
-- push (sent, failed) | purchases (paid, refunded; build 133) | support (new, closed). p_daily = tijdvakken van een dag of langer (gegevens per dag tellen mee).
create or replace function public.bingr_admin_insights(p_metric text, p_edges timestamptz[], p_daily boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare n int := coalesce(array_length(p_edges, 1), 0) - 1; k text; kinds text[];
        res jsonb := '{}'::jsonb; q text;
begin
  if n < 1 or n > 1000 or array_position(p_edges, null) is not null then return null; end if;
  if exists (select 1 from generate_series(1, n) i where p_edges[i] >= p_edges[i + 1]) then return null; end if;
  if p_metric = 'accounts' then
    res := jsonb_build_object('new_users', public.bingr_insights_bin(p_edges,
      'select created_at, 1 from auth.users where created_at >= $2 and created_at < $3'));
    -- account_logins: één rij per account per UTC-dag; telt op 12:00 UTC van die dag
    if p_daily then
      res := res || jsonb_build_object('active_users', public.bingr_insights_bin(p_edges,
        'select (day + time ''12:00'') at time zone ''UTC'', 1 from public.account_logins
          where day between ($2 at time zone ''UTC'')::date - 1 and ($3 at time zone ''UTC'')::date'));
    end if;
  elsif p_metric = 'signins' then
    if to_regclass('auth.audit_log_entries') is not null then
      begin
        res := jsonb_build_object('signins', public.bingr_insights_bin(p_edges,
          'select created_at, 1 from auth.audit_log_entries
            where created_at >= $2 and created_at < $3 and payload->>''action'' = ''login'''));
      exception when others then res := '{}'::jsonb;
      end;
    end if;
  elsif p_metric = 'streams' then
    foreach k in array array['live', 'movie', 'episode'] loop
      kinds := case k when 'live' then array['live', 'catchup', 'channel'] when 'movie' then array['movie', 'vod']
                      else array['episode', 'series'] end;
      if p_daily then
        -- account_watch_stats: per lokale dag (Europe/Amsterdam of de tijdzone van de app), 400 dagen bewaard
        q := format('select (day + time ''12:00'') at time zone ''Europe/Amsterdam'', plays from public.account_watch_stats
                      where kind = %L and day between ($2 at time zone ''Europe/Amsterdam'')::date - 1
                                                  and ($3 at time zone ''Europe/Amsterdam'')::date', k);
      else
        -- per uur of 5 minuten: gestarte streams uit account_watch_log (8 dagen bewaard)
        q := format('select started_at, 1 from public.account_watch_log
                      where started_at >= $2 and started_at < $3 and lower(coalesce(kind, '''')) = any(%L::text[])', kinds);
      end if;
      res := res || jsonb_build_object(k, public.bingr_insights_bin(p_edges, q));
    end loop;
  elsif p_metric = 'push' then
    -- push_deliveries: per apparaat, 30 dagen bewaard; daarvoor de tellers per bericht (push_messages.counts)
    res := jsonb_build_object(
      'sent', public.bingr_insights_bin(p_edges,
        'select sent_at, 1 from public.push_deliveries
          where state = ''sent'' and sent_at >= greatest($2, now() - interval ''30 days'') and sent_at < $3
         union all
         select created_at, coalesce((counts->>''sent'')::int, 0) from public.push_messages
          where created_at >= $2 and created_at < least($3, now() - interval ''30 days'')'),
      'failed', public.bingr_insights_bin(p_edges,
        'select coalesce(claimed_at, created_at), 1 from public.push_deliveries
          where state in (''failed'', ''invalid'') and coalesce(claimed_at, created_at) >= greatest($2, now() - interval ''30 days'')
            and coalesce(claimed_at, created_at) < $3
         union all
         select created_at, coalesce((counts->>''failed'')::int, 0) + coalesce((counts->>''invalid'')::int, 0) from public.push_messages
          where created_at >= $2 and created_at < least($3, now() - interval ''30 days'')'));
  elsif p_metric = 'purchases' then
    -- build 133: betaalde aankopen (op het moment van betalen) en terugbetalingen/chargebacks (op dat moment)
    res := jsonb_build_object(
      'paid', public.bingr_insights_bin(p_edges,
        'select paid_at, 1 from public.billing_purchases where paid_at >= $2 and paid_at < $3'),
      'refunded', public.bingr_insights_bin(p_edges,
        'select refunded_at, 1 from public.billing_purchases where refunded_at >= $2 and refunded_at < $3'));
  elsif p_metric = 'support' then
    res := jsonb_build_object(
      'new', public.bingr_insights_bin(p_edges,
        'select created_at, 1 from public.support_tickets where created_at >= $2 and created_at < $3'),
      'closed', public.bingr_insights_bin(p_edges,
        'select closed_at, 1 from public.support_tickets where status = ''closed'' and closed_at >= $2 and closed_at < $3'));
  else
    return null;
  end if;
  return res;
end $$;
revoke all on function public.bingr_admin_insights(text, timestamptz[], boolean) from public, anon, authenticated;
grant execute on function public.bingr_admin_insights(text, timestamptz[], boolean) to service_role;
create index if not exists support_tickets_closed_idx on public.support_tickets (closed_at) where closed_at is not null;
create index if not exists push_deliveries_sent_idx on public.push_deliveries (sent_at) where sent_at is not null;
create index if not exists push_messages_created_idx on public.push_messages (created_at);
-- Storingen (monitors van de statuspagina) en gepland onderhoud in een periode, als banden op de tijdas van de grafieken
-- in het beheer. Alleen naam en tijden (zoals op de openbare statuspagina): geen oorzaak, doel of andere gegevens.
create or replace function public.bingr_admin_insights_events(p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(e order by e->>'from'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'incident', 'name', m.name_nl, 'from', i.started_at, 'to', i.ended_at) e
      from public.status_incidents i join public.status_monitors m on m.id = i.monitor_id
     where m.public and m.kind <> 'devices' and i.started_at < p_to and coalesce(i.ended_at, now()) > p_from
    union all
    select jsonb_build_object('kind', 'maintenance', 'name', n.title_nl, 'from', coalesce(n.window_start, n.started_at),
                              'to', coalesce(n.window_end, n.resolved_at))
      from public.status_notices n
     where n.kind = 'maintenance' and n.status not in ('cancelled', 'scheduled')
       and coalesce(n.window_start, n.started_at) < p_to and coalesce(n.window_end, n.resolved_at, now()) > p_from
    order by 1 limit 40) x(e);
$$;
revoke all on function public.bingr_admin_insights_events(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.bingr_admin_insights_events(timestamptz, timestamptz) to service_role;

-- ============================================================================================================
-- build 134: bescherming tegen nepaccounts (docs/ACCOUNT.md, "Bescherming tegen nepaccounts (build 134)"). Zonder captcha
-- en zonder app-update: Supabase Auth roept bij elk nieuw account (POST /auth/v1/signup, ook vanaf tv-apps en de website)
-- de Postgres-hook bingr_before_user_created aan (Before User Created; aangezet door de Backend-workflow). Die weigert:
--   rate_limit  meer dan signup_limits.per_hour (3) nieuwe accounts per uur of per_day (10) per 24 uur vanaf één netwerk
--               (IPv4-adres of IPv6-/64), 429;
--   name        een voor- of achternaam met een link, e-mailadres of HTML (zelfde regel als de trigger bingr_user_names), 400;
--   disposable  een wegwerp-e-mailadres (tabel disposable_domains, ook subdomeinen), 400;
--   honeypot    (build 138) user_metadata.hp niet leeg: het verborgen veld "website" van de webformulieren is ingevuld, 400;
--   too_fast    (build 138) user_metadata.fill_ms aanwezig en < 1500: formulier sneller verstuurd dan een mens kan, 400.
--               Beide met de neutrale melding "Something went wrong. Please try again." (geen hint voor bots). De apps sturen
--               hp en fill_ms niet mee: ontbreken = toestaan. De trigger bingr_user_names haalt hp en fill_ms weer uit de
--               opgeslagen metadata (nooit zichtbaar in het beheer of in mails).
-- Nooit een IP-adres of e-mailadres opgeslagen: alleen sha256(geheime salt | netwerk) in signup_attempts, 7 dagen bewaard.
-- Accounts die het beheer of de CI via de admin-API maakt, roepen de hook niet aan (Supabase Auth); zonder IP-adres of met
-- een andere provider dan e-mail laat de hook alles door. Bij een fout in de hook zelf: toestaan (nooit legitieme
-- aanmeldingen blokkeren door een storing). Onbevestigde accounts verdwijnen na 48 uur (bingr_signup_cleanup, elk uur).
-- Het blok tussen de unittest-markeringen wordt ook los getest met Postgres (supabase/tests/signup_guard_test.sh).
-- >>> unittest signup-guard

create table if not exists public.signup_attempts (
  id      bigint generated always as identity primary key,
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  at      timestamptz not null default now(),
  allowed boolean not null,
  reason  text check (reason is null or reason in ('rate_limit', 'disposable', 'name', 'honeypot', 'too_fast'))
);
-- build 138: redenen honeypot en too_fast erbij (bestaande tabel: de check opnieuw zetten als hij ze nog niet kent)
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.signup_attempts'::regclass and contype = 'c'
                 and pg_get_constraintdef(oid) like '%too_fast%') then
    alter table public.signup_attempts drop constraint if exists signup_attempts_reason_check;
    alter table public.signup_attempts add constraint signup_attempts_reason_check
      check (reason is null or reason in ('rate_limit', 'disposable', 'name', 'honeypot', 'too_fast'));
  end if;
end $$;
create index if not exists signup_attempts_ip_idx on public.signup_attempts (ip_hash, at) where allowed;
create index if not exists signup_attempts_at_idx on public.signup_attempts (at);
alter table public.signup_attempts enable row level security;
revoke all on public.signup_attempts from anon, authenticated;

-- Geheime salt voor de IP-hash: één keer in de database gemaakt (nooit in de repo of een log), alleen voor de functies hier.
create table if not exists public.signup_guard_secret (
  id   int primary key default 1 check (id = 1),
  salt text not null check (char_length(salt) >= 32)
);
alter table public.signup_guard_secret enable row level security;
revoke all on public.signup_guard_secret from anon, authenticated, service_role;
insert into public.signup_guard_secret (id, salt)
values (1, encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'))
on conflict (id) do nothing;

-- Wegwerpdomeinen: source 'list' = github.com/disposable-email-domains/disposable-email-domains (de workflow vult en ververst
-- ze, vast op een commit), 'own' = eigen aanvulling hieronder (blijft ook staan als de lijst niet te laden is).
create table if not exists public.disposable_domains (
  domain   text primary key check (char_length(domain) <= 253 and domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  source   text not null default 'own' check (source in ('list', 'own')),
  added_at timestamptz not null default now()
);
alter table public.disposable_domains enable row level security;
revoke all on public.disposable_domains from anon, authenticated;
insert into public.disposable_domains (domain, source) values
  ('mailinator.com', 'own'), ('yopmail.com', 'own'), ('guerrillamail.com', 'own'), ('sharklasers.com', 'own'),
  ('10minutemail.com', 'own'), ('temp-mail.org', 'own'), ('tempmail.com', 'own'), ('trashmail.com', 'own'),
  ('getnada.com', 'own'), ('maildrop.cc', 'own'), ('dispostable.com', 'own'), ('mohmal.com', 'own'),
  ('emailondeck.com', 'own'), ('throwawaymail.com', 'own'), ('mintemail.com', 'own'), ('fakeinbox.com', 'own')
on conflict (domain) do update set source = 'own';

-- Onbevestigde accounts die automatisch verwijderd zijn: alleen het aantal per ronde (voor het beheer), 400 dagen bewaard.
create table if not exists public.signup_cleanups (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  deleted int not null check (deleted >= 0)
);
alter table public.signup_cleanups enable row level security;
revoke all on public.signup_cleanups from anon, authenticated;

-- Limieten (aan te passen zonder deploy): nieuwe accounts per netwerk per uur en per 24 uur. Bestaande waarden blijven staan.
insert into public.app_settings (key, value) values ('signup_limits', '{"per_hour": 3, "per_day": 10}'::jsonb)
on conflict (key) do nothing;
-- build 137: bevestigen per e-mail verplicht (true) of tijdelijk uit (false; de workflow Backend zet dan mailer_autoconfirm aan
-- en bevestigt vastzittende accounts). Alleen weer op true als de e-2-e-test (job authmail) de bevestigingsmail bewijst.
insert into public.app_settings (key, value) values ('require_email_confirm', 'false'::jsonb)
on conflict (key) do nothing;

-- Netwerk van een IP-adres: IPv4 zoals het is (ook ::ffff:a.b.c.d), IPv6 per /64 (één aansluiting); onleesbaar = de tekst.
create or replace function public.bingr_signup_ip_key(p_ip text) returns text
language plpgsql immutable set search_path = public as $$
declare a inet; s text := lower(btrim(coalesce(p_ip, '')));
begin
  if s ~ '^::ffff:\d+\.\d+\.\d+\.\d+$' then s := substr(s, 8); end if;
  begin
    a := s::inet;
  exception when others then
    return left(s, 100);
  end;
  if family(a) = 6 then return host(network(set_masklen(a, 64))) || '/64'; end if;
  return host(a);
end $$;
create or replace function public.bingr_signup_ip_hash(p_ip text) returns text
language sql stable security definer set search_path = public as $$
  select encode(sha256(convert_to(s.salt || '|' || public.bingr_signup_ip_key(p_ip), 'UTF8')), 'hex')
  from public.signup_guard_secret s where s.id = 1
$$;

-- Wegwerpadres? Het domein of een bovenliggend domein (a.b.mailinator.com -> mailinator.com) staat in disposable_domains.
create or replace function public.bingr_email_disposable(p_email text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare d text; parts text[]; n int; cands text[] := '{}';
begin
  d := rtrim(lower(btrim(coalesce(substring(coalesce(p_email, '') from '@([^@]*)$'), ''))), '.');
  if d = '' then return false; end if;
  parts := string_to_array(d, '.');
  n := coalesce(array_length(parts, 1), 0);
  for i in 1 .. n - 1 loop
    cands := cands || array_to_string(parts[i:n], '.');
  end loop;
  return exists (select 1 from public.disposable_domains where domain = any (cands));
end $$;

-- De hook (Supabase Auth, Before User Created). event = {metadata:{ip_address,…}, user:{email, app_metadata, user_metadata,…}}.
-- Terug: '{}' = toestaan; {"error":{"http_code":4xx,"message":…}} = weigeren (Auth geeft die status en msg door; error_code
-- is dan "unknown"). De apps tonen bij een onbekende fout "Something went wrong. Please try again."; de website (koppelen)
-- herkent "Too many" als te veel pogingen. Daarom korte, neutrale Engelse teksten.
create or replace function public.bingr_before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u jsonb := case when jsonb_typeof(event->'user') = 'object' then event->'user' else '{}'::jsonb end;
  ip text := nullif(btrim(coalesce(event->'metadata'->>'ip_address', '')), '');
  prov text := coalesce(nullif(u->'app_metadata'->>'provider', ''), 'email');
  meta jsonb := u->'user_metadata';
  lim jsonb; per_hour int := 3; per_day int := 10; h text; reason text; fill numeric;
begin
  -- geen gewone aanmelding (admin-API zonder IP, anoniem of een andere provider): toestaan
  if ip is null or prov <> 'email' or coalesce(u->>'is_anonymous', 'false') = 'true' then return '{}'::jsonb; end if;
  begin
    h := public.bingr_signup_ip_hash(ip);
    if h is null then return '{}'::jsonb; end if;
    select value into lim from public.app_settings where key = 'signup_limits';
    if jsonb_typeof(lim->'per_hour') = 'number' then per_hour := least(greatest((lim->>'per_hour')::numeric::int, 1), 10000); end if;
    if jsonb_typeof(lim->'per_day') = 'number' then per_day := least(greatest((lim->>'per_day')::numeric::int, 1), 10000); end if;
    -- gelijktijdige aanmeldingen vanaf hetzelfde netwerk na elkaar tellen
    perform pg_advisory_xact_lock(hashtextextended('bingr_signup:' || h, 0));
    -- build 138: honeypot en tijdmeting van de webformulieren (de apps sturen ze niet: ontbreken = toestaan)
    if jsonb_typeof(meta) = 'object' then
      if jsonb_typeof(meta->'fill_ms') = 'number' then fill := (meta->>'fill_ms')::numeric;
      elsif jsonb_typeof(meta->'fill_ms') = 'string' and btrim(meta->>'fill_ms') ~ '^-?[0-9]{1,15}(\.[0-9]+)?$' then fill := btrim(meta->>'fill_ms')::numeric;
      end if;
    end if;
    if jsonb_typeof(meta) = 'object' and jsonb_typeof(meta->'hp') is not null and jsonb_typeof(meta->'hp') <> 'null'
       and not (jsonb_typeof(meta->'hp') = 'string' and btrim(meta->>'hp') = '') then
      reason := 'honeypot';
    elsif fill is not null and fill < 1500 then
      reason := 'too_fast';
    elsif (select count(*) from public.signup_attempts where ip_hash = h and allowed and at > now() - interval '1 hour') >= per_hour
       or (select count(*) from public.signup_attempts where ip_hash = h and allowed and at > now() - interval '24 hours') >= per_day then
      reason := 'rate_limit';
    elsif jsonb_typeof(meta) = 'object' and exists (
        select 1 from unnest(array['first_name', 'last_name']) k
        where jsonb_typeof(meta->k) is not null and jsonb_typeof(meta->k) <> 'null'
          and (jsonb_typeof(meta->k) <> 'string' or public.bingr_person_name_invalid(meta->>k))) then
      reason := 'name';
    elsif public.bingr_email_disposable(u->>'email') then
      reason := 'disposable';
    end if;
    insert into public.signup_attempts (ip_hash, allowed, reason) values (h, reason is null, reason);
  exception when others then
    raise warning 'bingr_before_user_created: % (%)', sqlerrm, sqlstate;
    return '{}'::jsonb;
  end;
  if reason = 'rate_limit' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 429, 'message', 'Too many sign-ups from this network. Try again later.'));
  elsif reason = 'name' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Names cannot contain links, email addresses or HTML.'));
  elsif reason = 'disposable' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Use a permanent email address. Disposable email addresses are not accepted.'));
  elsif reason in ('honeypot', 'too_fast') then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Something went wrong. Please try again.'));
  end if;
  return '{}'::jsonb;
end $$;

-- Opruimen (pg_cron bingr-unconfirmed-cleanup, elk uur): onbevestigde accounts ouder dan 48 uur verwijderen, alleen als er
-- niets aan hangt (geen abonnement, aankoop, blokkade, supportticket, profielen of apparaten; nooit ingelogd, niet
-- uitgenodigd). Max. 500 per ronde. Alleen het aantal wordt bewaard (signup_cleanups). p_only = alleen dat account (CI-test;
-- telt niet mee). Terug: {deleted}.
create or replace function public.bingr_signup_cleanup(p_only uuid default null) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare n int := 0;
begin
  delete from auth.users u where u.id in (
    select x.id from auth.users x
    where x.email_confirmed_at is null and x.phone_confirmed_at is null and x.created_at < now() - interval '48 hours'
      and x.last_sign_in_at is null and x.invited_at is null and x.email is not null
      and (p_only is null or x.id = p_only)
      and not exists (select 1 from public.account_plans p where p.user_id = x.id)
      and not exists (select 1 from public.billing_purchases b where b.user_id = x.id)
      and not exists (select 1 from public.account_blocks k where k.user_id = x.id)
      and not exists (select 1 from public.support_tickets t where t.user_id = x.id)
      and not exists (select 1 from public.account_data d where d.user_id = x.id)
      and not exists (select 1 from public.account_devices v where v.user_id = x.id)
    order by x.created_at limit 500);
  get diagnostics n = row_count;
  if p_only is null and n > 0 then insert into public.signup_cleanups (deleted) values (n); end if;
  return jsonb_build_object('deleted', n);
end $$;

-- Pogingen na 7 dagen weg, tellingen van het opruimen na 400 dagen (dagelijks via bingr_support_cleanup).
create or replace function public.bingr_signup_attempts_cleanup() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.signup_attempts where at < now() - interval '7 days';
  get diagnostics n = row_count;
  delete from public.signup_cleanups where at < now() - interval '400 days';
  return n;
end $$;

-- Beheer (functie admin, Overzicht): alleen aantallen. Geweigerd per reden (24 uur / 7 dagen), toegestaan, verwijderde
-- onbevestigde accounts en het aantal wegwerpdomeinen. Redenen: rate_limit, disposable, name, honeypot, too_fast (build 138).
create or replace function public.bingr_admin_signup_guard() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rejected_24h', (select jsonb_build_object('total', count(*), 'rate_limit', count(*) filter (where reason = 'rate_limit'),
        'disposable', count(*) filter (where reason = 'disposable'), 'name', count(*) filter (where reason = 'name'),
        'honeypot', count(*) filter (where reason = 'honeypot'), 'too_fast', count(*) filter (where reason = 'too_fast'))
      from public.signup_attempts where not allowed and at > now() - interval '24 hours'),
    'rejected_7d', (select jsonb_build_object('total', count(*), 'rate_limit', count(*) filter (where reason = 'rate_limit'),
        'disposable', count(*) filter (where reason = 'disposable'), 'name', count(*) filter (where reason = 'name'),
        'honeypot', count(*) filter (where reason = 'honeypot'), 'too_fast', count(*) filter (where reason = 'too_fast'))
      from public.signup_attempts where not allowed and at > now() - interval '7 days'),
    'allowed_24h', (select count(*) from public.signup_attempts where allowed and at > now() - interval '24 hours'),
    'allowed_7d', (select count(*) from public.signup_attempts where allowed and at > now() - interval '7 days'),
    'unconfirmed_deleted_24h', (select coalesce(sum(deleted), 0) from public.signup_cleanups where at > now() - interval '24 hours'),
    'unconfirmed_deleted_7d', (select coalesce(sum(deleted), 0) from public.signup_cleanups where at > now() - interval '7 days'),
    'disposable_domains', (select count(*) from public.disposable_domains))
$$;

revoke all on function public.bingr_signup_ip_key(text) from public, anon, authenticated, service_role;
revoke all on function public.bingr_signup_ip_hash(text) from public, anon, authenticated, service_role;
revoke all on function public.bingr_email_disposable(text) from public, anon, authenticated, service_role;
revoke all on function public.bingr_before_user_created(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.bingr_signup_cleanup(uuid) from public, anon, authenticated, service_role;
revoke all on function public.bingr_signup_attempts_cleanup() from public, anon, authenticated, service_role;
revoke all on function public.bingr_admin_signup_guard() from public, anon, authenticated;
grant execute on function public.bingr_admin_signup_guard() to service_role;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.bingr_before_user_created(jsonb) to supabase_auth_admin;
-- <<< unittest signup-guard

-- ============================================================================================================
-- Inlogbescherming per account (Supabase Auth, hook Password Verification Attempt; aangezet door de Backend-workflow,
-- docs/ACCOUNT.md "Inlogbescherming"). Auth roept de hook aan bij elke wachtwoordcontrole van een bestaand account
-- (inloggen met e-mail + wachtwoord, ook de controle bij delete_account) met event = {user_id, valid}.
-- 5 foute wachtwoorden binnen 15 minuten = dat account 15 minuten dicht (ook met het goede wachtwoord); elke volgende
-- blokkade binnen 24 uur duurt twee keer zo lang (15 -> 30 -> 60 minuten, max. 60). Gelukt = teller weg. Bestaande sessies
-- blijven werken (verversen gaat niet langs de hook). Terug: {"decision":"continue"} of
-- {"error":{"http_code":429,"message":"Too many attempts. Try again in 15 minutes."}} (kort, neutraal, Engels; de apps en
-- de website tonen bij 429 hun eigen tekst "te veel pogingen"). Alleen user_id en tijden, geen IP's of wachtwoorden;
-- rijen na 1 dag weg (in de hook en in bingr_cleanup). Een fout in de hook houdt niemand tegen (continue + warning).
-- Het blok tussen de unittest-markeringen wordt ook los getest met Postgres (supabase/tests/password_guard_test.sh).
-- >>> unittest password-guard
create table if not exists public.auth_password_failures (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  failures     int not null default 0,
  window_start timestamptz not null default now(),
  locked_until timestamptz,
  lock_level   int not null default 0,
  updated_at   timestamptz not null default now()
);
create index if not exists auth_password_failures_updated_idx on public.auth_password_failures (updated_at);
alter table public.auth_password_failures enable row level security;
revoke all on public.auth_password_failures from public, anon, authenticated;

create or replace function public.bingr_password_lock_message(p_until timestamptz) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('error', jsonb_build_object('http_code', 429, 'message',
    'Too many attempts. Try again in ' || m || case when m = 1 then ' minute.' else ' minutes.' end))
  from (select greatest(1, ceil(extract(epoch from p_until - now()) / 60))::int as m) x
$$;

create or replace function public.bingr_password_attempt(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid; ok boolean; have boolean; r public.auth_password_failures%rowtype; lvl int; until_ts timestamptz;
  max_fail constant int := 5; win constant interval := interval '15 minutes';
begin
  begin
    uid := nullif(event->>'user_id', '')::uuid;
    ok := coalesce((event->>'valid')::boolean, false);
  exception when others then
    return jsonb_build_object('decision', 'continue');
  end;
  if uid is null then return jsonb_build_object('decision', 'continue'); end if;
  begin
    select * into r from public.auth_password_failures where user_id = uid for update;
    have := found;
    if have and r.updated_at < now() - interval '1 day' and (r.locked_until is null or r.locked_until < now()) then
      delete from public.auth_password_failures where user_id = uid;
      have := false;
    end if;
    -- dicht: ook een goed wachtwoord wordt geweigerd
    if have and r.locked_until is not null and r.locked_until > now() then
      return public.bingr_password_lock_message(r.locked_until);
    end if;
    if ok then
      if have then delete from public.auth_password_failures where user_id = uid; end if;
      return jsonb_build_object('decision', 'continue');
    end if;
    if not have then
      insert into public.auth_password_failures (user_id, failures, window_start, updated_at) values (uid, 1, now(), now())
      on conflict (user_id) do update set failures = public.auth_password_failures.failures + 1, updated_at = now();
      return jsonb_build_object('decision', 'continue');
    end if;
    if r.window_start < now() - win then r.failures := 0; r.window_start := now(); end if;
    r.failures := r.failures + 1;
    if r.failures >= max_fail then
      lvl := least(coalesce(r.lock_level, 0) + 1, 3);
      until_ts := now() + win * power(2, lvl - 1)::int;
      update public.auth_password_failures set failures = 0, window_start = now(), locked_until = until_ts,
        lock_level = lvl, updated_at = now() where user_id = uid;
      return public.bingr_password_lock_message(until_ts);
    end if;
    update public.auth_password_failures set failures = r.failures, window_start = r.window_start, updated_at = now()
    where user_id = uid;
    return jsonb_build_object('decision', 'continue');
  exception when others then
    raise warning 'bingr_password_attempt: % (%)', sqlerrm, sqlstate;
    return jsonb_build_object('decision', 'continue');
  end;
end $$;

-- opruimen: rijen zonder lopende blokkade na 1 dag weg (ook via bingr_cleanup)
create or replace function public.bingr_password_failures_cleanup() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.auth_password_failures where updated_at < now() - interval '1 day' and (locked_until is null or locked_until < now());
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.bingr_password_lock_message(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.bingr_password_attempt(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.bingr_password_failures_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_password_failures_cleanup() to service_role;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.bingr_password_attempt(jsonb) to supabase_auth_admin;
-- <<< unittest password-guard

-- Opruimen (zoals hierboven), plus de tellers van de inlogbescherming per account.
create or replace function public.bingr_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.device_codes where expires_at < now();
  delete from public.account_streams where last_ping < now() - interval '1 day';
  delete from public.account_watch_log where started_at < now() - interval '8 days';
  delete from public.rate_limits where bucket < now() - interval '10 minutes';
  delete from public.admin_login_attempts where window_start < now() - interval '1 day' and (locked_until is null or locked_until < now());
  delete from public.account_logins where day < (now() at time zone 'utc')::date - 400;
  delete from public.admin_audit where created_at < now() - interval '1 year';
  delete from public.account_watch_stats where day < (now() at time zone 'utc')::date - 400;
  delete from public.auth_password_failures where updated_at < now() - interval '1 day' and (locked_until is null or locked_until < now());
$$;
revoke all on function public.bingr_cleanup() from public, anon, authenticated;
grant execute on function public.bingr_cleanup() to service_role;

-- Limiet alleen bekijken (zonder te tellen): zelfde venster en bucket als bingr_rate_hit. Voor device-auth: foute
-- koppelcodes per IP/account (alleen fouten tellen, maar elke aanvraag controleren). Terug: true = nog onder p_max.
create or replace function public.bingr_rate_peek(p_key text, p_max int, p_window int default 60) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare n int; w int := greatest(coalesce(p_window, 60), 1); b timestamptz;
begin
  if w = 60 then b := date_trunc('minute', now());
  else b := to_timestamp(floor(extract(epoch from now()) / w) * w + case when w > 60 then w else 0 end);
  end if;
  select hits into n from public.rate_limits where key = p_key and bucket = b;
  return coalesce(n, 0) < p_max;
end $$;
revoke all on function public.bingr_rate_peek(text, int, int) from public, anon, authenticated;
grant execute on function public.bingr_rate_peek(text, int, int) to service_role;

-- ============================================================================================================
-- Beveiligingsadvisor van Supabase (docs/ACCOUNT.md "Inlogbescherming"; Backend controleert hem na elke deploy):
-- 1. account_data: alleen wat de apps nodig hebben (authenticated lezen/toevoegen/wijzigen via RLS; anon niets, geen
--    delete/truncate; verwijderen gaat via device-auth met de service role).
revoke all on public.account_data from anon;
revoke delete, truncate, references, trigger on public.account_data from authenticated;
grant select, insert, update on public.account_data to authenticated;
-- 2. RLS-policies met (select auth.uid()): één keer per query uitgerekend i.p.v. per rij (performance-advisor
--    auth_rls_initplan); zelfde betekenis.
drop policy if exists "eigen gegevens lezen" on public.account_data;
drop policy if exists "eigen gegevens schrijven" on public.account_data;
drop policy if exists "eigen gegevens wijzigen" on public.account_data;
create policy "eigen gegevens lezen"    on public.account_data for select to authenticated using (user_id = (select auth.uid()));
create policy "eigen gegevens schrijven" on public.account_data for insert to authenticated with check (user_id = (select auth.uid()));
create policy "eigen gegevens wijzigen" on public.account_data for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "eigen abonnement lezen" on public.account_plans;
create policy "eigen abonnement lezen" on public.account_plans for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "eigen aankopen lezen" on public.billing_purchases;
create policy "eigen aankopen lezen" on public.billing_purchases for select to authenticated using (user_id = (select auth.uid()));
-- 3. Geen enkele security-definer-functie in public is via de Data API (/rest/v1/rpc) uit te voeren door anon of
--    authenticated (advisor anon/authenticated_security_definer_function_executable). Triggers en event-triggers hebben
--    dat recht niet nodig. De service role behoudt wat hij had. Functies van extensies blijven ongemoeid.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, has_function_privilege('service_role', p.oid, 'execute') as svc
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  loop
    begin
      if f.svc then execute format('grant execute on function %s to service_role', f.sig); end if;
      execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    exception when others then
      raise warning 'rechten % niet aangepast: %', f.sig, sqlerrm;
    end;
  end loop;
end $$;
