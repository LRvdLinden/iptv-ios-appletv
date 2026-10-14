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

-- Beheer: de tabellen announcements, account_email_prefs, admin_login_attempts en admin_audit en de functies bingr_admin_*
-- horen bij dit gedeelde schema, maar worden gebruikt door de Edge Function admin in de privé-repo LRvdLinden/bingr-beheer
-- (beheer.bingr.online). Alleen announcements wordt ook door device-auth gelezen (berichten in de apps).
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

-- Tellers voor limieten (webproxy): per sleutel per minuut.
create table if not exists public.rate_limits (
  key    text not null,
  bucket timestamptz not null,
  hits   int not null default 0,
  primary key (key, bucket)
);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;

create or replace function public.bingr_rate_hit(p_key text, p_max int) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.rate_limits (key, bucket, hits) values (p_key, date_trunc('minute', now()), 1)
  on conflict (key, bucket) do update set hits = public.rate_limits.hits + 1
  returning hits into n;
  return n <= p_max;
end $$;
revoke all on function public.bingr_rate_hit(text, int) from public, anon, authenticated;
grant execute on function public.bingr_rate_hit(text, int) to service_role;

-- Beheer-login: is dit IP (of alles samen, bij een aanval van veel IP's) geblokkeerd?
create or replace function public.bingr_admin_gate(p_ip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare until_ts timestamptz; total int;
begin
  select locked_until into until_ts from public.admin_login_attempts where ip = p_ip;
  if until_ts is not null and until_ts > now() then
    return jsonb_build_object('locked', true, 'retry_after', ceil(extract(epoch from until_ts - now())));
  end if;
  select coalesce(sum(failures), 0) into total from public.admin_login_attempts where window_start > now() - interval '15 minutes';
  if total >= 50 then return jsonb_build_object('locked', true, 'retry_after', 900); end if;
  return jsonb_build_object('locked', false);
end $$;
-- Resultaat van een poging: na 5 fouten binnen 15 min is het IP 15 min geblokkeerd; gelukt = teller weg.
create or replace function public.bingr_admin_result(p_ip text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_ok then delete from public.admin_login_attempts where ip = p_ip; return; end if;
  insert into public.admin_login_attempts as a (ip, failures, window_start) values (p_ip, 1, now())
  on conflict (ip) do update set
    failures = case when a.window_start < now() - interval '15 minutes' then 1 else a.failures + 1 end,
    window_start = case when a.window_start < now() - interval '15 minutes' then now() else a.window_start end;
  update public.admin_login_attempts set locked_until = now() + interval '15 minutes', failures = 0, window_start = now()
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

-- Statistieken voor het beheer-dashboard (functie admin, privé-repo bingr-beheer).
create or replace function public.bingr_admin_stats() returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare res jsonb; days jsonb; audit_total bigint;
begin
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

-- Gebruikers (hoofdaccounts), nieuwste eerst, zoeken op begin van het e-mailadres. De functie maskeert de e-mail.
create or replace function public.bingr_admin_users(p_search text, p_limit int, p_offset int) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare pat text := replace(replace(replace(lower(coalesce(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%';
begin
  return jsonb_build_object(
    'total', (select count(*) from auth.users u where lower(u.email) like pat),
    'items', coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.created_at desc) from (
      select u.id, u.email, u.created_at, u.last_sign_in_at, u.email_confirmed_at is not null as confirmed,
        (select count(*) from public.account_devices d where d.user_id = u.id) as device_count,
        (select coalesce(jsonb_agg(distinct d.platform), '[]'::jsonb) from public.account_devices d where d.user_id = u.id) as platforms,
        (select coalesce(jsonb_agg(distinct d.app_version), '[]'::jsonb) from public.account_devices d where d.user_id = u.id and d.app_version is not null) as app_versions,
        (select max(d.last_seen_at) from public.account_devices d where d.user_id = u.id) as last_seen_at,
        (select count(*) from public.account_data a, jsonb_array_elements(case when jsonb_typeof(a.profiles) = 'array' then a.profiles else '[]'::jsonb end) e
          where a.user_id = u.id and coalesce(e->>'deleted', 'false') <> 'true') as profile_count,
        coalesce((select p.email_opt_out from public.account_email_prefs p where p.user_id = u.id), false) as email_opt_out
      from auth.users u where lower(u.email) like pat
      order by u.created_at desc limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)) x), '[]'::jsonb)
  );
end $$;
revoke all on function public.bingr_admin_users(text, int, int) from public, anon, authenticated;
grant execute on function public.bingr_admin_users(text, int, int) to service_role;

create or replace function public.bingr_admin_user(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare u record;
begin
  select id, email, created_at, last_sign_in_at, email_confirmed_at, raw_user_meta_data->>'lang' as lang into u from auth.users where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'confirmed', u.email_confirmed_at is not null, 'lang', u.lang,
    'profile_count', (select count(*) from public.account_data a, jsonb_array_elements(case when jsonb_typeof(a.profiles) = 'array' then a.profiles else '[]'::jsonb end) e
          where a.user_id = u.id and coalesce(e->>'deleted', 'false') <> 'true'),
    'email_opt_out', coalesce((select p.email_opt_out from public.account_email_prefs p where p.user_id = u.id), false),
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
  ('storage',    'Opslag (profielfoto''s)',      'Storage (profile photos)',     'server',  'storage',     'avatars',                                null,         5,  true,  true, 50),
  ('smtp',       'E-mail (SMTP)',                'Email (SMTP)',                 'server',  'smtp',        '',                                       null,         5,  true,  true, 60),
  ('site',       'Website',                      'Website',                      'website', 'http',        'https://bingr.online/',                  'data-build', 5,  true,  true, 10),
  ('site-web',   'Webspeler',                    'Web player',                   'website', 'http',        'https://bingr.online/web/',              null,         5,  true,  true, 20),
  ('site-log',   'Changelog',                    'Changelog',                    'website', 'http',        'https://bingr.online/changelog/',        null,         5,  true,  true, 30),
  ('site-link',  'Tv koppelen',                  'TV linking',                   'website', 'http',        'https://bingr.online/koppelen/',         null,         5,  true,  true, 40),
  ('site-acc',   'Mijn Bingr',                   'My Bingr',                     'website', 'http',        'https://bingr.online/account/',          null,         5,  true,  true, 50),
  ('tls',        'TLS-certificaat',              'TLS certificate',              'website', 'tls',         'bingr.online',                           null,         60, true,  true, 60),
  ('apk',        'Android-download (APK)',       'Android download (APK)',       'apps',    'gh_asset',    'LRvdLinden/bingr-beheer|.apk',           null,         15, true,  true, 10),
  ('wgt',        'Samsung TV-download (.wgt)',   'Samsung TV download (.wgt)',   'apps',    'gh_asset',    'LRvdLinden/bingr-beheer|.wgt',           null,         15, true,  true, 20),
  ('apple',      'Apple-build',                  'Apple build',                  'apps',    'gh_workflow', 'LRvdLinden/iptv-ios-appletv|build.yml|main', null,     15, true,  true, 30),
  ('devices',    'Actieve apparaten',            'Active devices',               'apps',    'devices',     '',                                       null,         5,  false, true, 90)
on conflict (id) do nothing;
-- downloads staan sinds build 69 in bingr-beheer/versions (niet meer als GitHub-release)
update public.status_monitors set target = replace(target, 'LRvdLinden/bingr-android|', 'LRvdLinden/bingr-beheer|') where kind = 'gh_asset' and target like 'LRvdLinden/bingr-android|%';

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
-- Bingr-account bij een ticket (op user_id, anders op e-mailadres): alleen een samenvatting voor het beheer.
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
    'tickets', (select count(*) from public.support_tickets t where t.user_id = u.id or lower(t.email) = lower(u.email))
  );
end $$;
revoke all on function public.bingr_support_counts() from public, anon, authenticated;
revoke all on function public.bingr_support_account(uuid, text) from public, anon, authenticated;
grant execute on function public.bingr_support_counts() to service_role;
grant execute on function public.bingr_support_account(uuid, text) to service_role;

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
