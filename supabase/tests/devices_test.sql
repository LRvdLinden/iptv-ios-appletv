-- Unittests van bingr_enforce_free_devices (build 157). Stopt bij de eerste fout (ON_ERROR_STOP in devices_test.sh).
\set ON_ERROR_STOP 1
insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'), -- gratis, geen rij, 4 apparaten
  ('00000000-0000-0000-0000-00000000000b'), -- gratis met rij, 2 apparaten (binnen de limiet)
  ('00000000-0000-0000-0000-00000000000c'), -- lifetime, 5 apparaten
  ('00000000-0000-0000-0000-00000000000d'), -- gratis met eigen limiet 8, 5 apparaten
  ('00000000-0000-0000-0000-00000000000e'); -- gratis met rij, 3 apparaten
insert into public.account_plans (user_id, plan, max_devices) values
  ('00000000-0000-0000-0000-00000000000b', 'free', null), ('00000000-0000-0000-0000-00000000000c', 'lifetime', null),
  ('00000000-0000-0000-0000-00000000000d', 'free', 8), ('00000000-0000-0000-0000-00000000000e', 'free', null);
insert into auth.sessions (id, user_id)
  select ('10000000-0000-0000-0000-00000000000' || i)::uuid, '00000000-0000-0000-0000-00000000000a' from generate_series(1, 4) i;
insert into public.account_devices (user_id, device_id, session_id, last_seen_at) values
  ('00000000-0000-0000-0000-00000000000a', 'a1', '10000000-0000-0000-0000-000000000001', now() - interval '3 days'),
  ('00000000-0000-0000-0000-00000000000a', 'a2', '10000000-0000-0000-0000-000000000002', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-00000000000a', 'a3', '10000000-0000-0000-0000-000000000003', now() - interval '10 days'),
  ('00000000-0000-0000-0000-00000000000a', 'a4', '10000000-0000-0000-0000-000000000004', now() - interval '2 hours');
insert into public.account_streams (user_id, device_id) values ('00000000-0000-0000-0000-00000000000a', 'a3'), ('00000000-0000-0000-0000-00000000000a', 'a2');
insert into public.account_devices (user_id, device_id) select '00000000-0000-0000-0000-00000000000b', 'b' || i from generate_series(1, 2) i;
insert into public.account_devices (user_id, device_id) select '00000000-0000-0000-0000-00000000000c', 'c' || i from generate_series(1, 5) i;
insert into public.account_devices (user_id, device_id) select '00000000-0000-0000-0000-00000000000d', 'd' || i from generate_series(1, 5) i;
insert into public.account_devices (user_id, device_id, last_seen_at) select '00000000-0000-0000-0000-00000000000e', 'e' || i, now() - make_interval(hours => i) from generate_series(1, 3) i;

do $$
declare r jsonb; kept text;
begin
  -- één account: alleen dat account
  r := public.bingr_enforce_free_devices(2, '00000000-0000-0000-0000-00000000000e');
  if r <> '{"accounts": 1, "devices": 1}'::jsonb then raise exception 'één account: %', r; end if;
  select string_agg(device_id, ',' order by device_id) into kept from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000e';
  if kept <> 'e1,e2' then raise exception 'één account: de twee laatst actieve blijven, kreeg %', kept; end if;
  if (select count(*) from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000a') <> 4 then raise exception 'ander account aangeraakt'; end if;

  -- alle accounts
  r := public.bingr_enforce_free_devices(2);
  if r <> '{"accounts": 1, "devices": 2}'::jsonb then raise exception 'alle accounts: %', r; end if;
  select string_agg(device_id, ',' order by device_id) into kept from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000a';
  if kept <> 'a2,a4' then raise exception 'gratis zonder rij: verwacht a2,a4, kreeg %', kept; end if;
  if (select count(*) from auth.sessions) <> 2 then raise exception 'sessies van verwijderde apparaten niet ingetrokken'; end if;
  if exists (select 1 from auth.sessions where id in ('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003')) then raise exception 'verkeerde sessie ingetrokken'; end if;
  if exists (select 1 from public.account_streams where device_id = 'a3') then raise exception 'stream van verwijderd apparaat blijft staan'; end if;
  if not exists (select 1 from public.account_streams where device_id = 'a2') then raise exception 'stream van gebleven apparaat weg'; end if;
  if (select count(*) from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000b') <> 2 then raise exception 'binnen de limiet aangeraakt'; end if;
  if (select count(*) from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000c') <> 5 then raise exception 'lifetime aangeraakt'; end if;
  if (select count(*) from public.account_devices where user_id = '00000000-0000-0000-0000-00000000000d') <> 5 then raise exception 'eigen limiet aangeraakt'; end if;

  -- herhaalbaar: tweede keer niets
  r := public.bingr_enforce_free_devices(2);
  if r <> '{"accounts": 0, "devices": 0}'::jsonb then raise exception 'herhaald: %', r; end if;
  -- ongeldige limiet: niets
  r := public.bingr_enforce_free_devices(0);
  if r <> '{"accounts": 0, "devices": 0}'::jsonb then raise exception 'limiet 0: %', r; end if;
end $$;
