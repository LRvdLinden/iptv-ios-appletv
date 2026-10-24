-- Unittests van build 146: profielen versleuteld (trigger voor oude apps, kolomrechten, telling, overgangsstand) en het
-- versleutelen van de statistieken (bingr_stats_item als referentie voor device-auth/watch.ts, bingr_stats_seal).
-- Draait via profiles_test.sh in een tijdelijke database. Alleen testadressen (example.com).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'prof-a@example.com'),
  ('00000000-0000-4000-8000-0000000000a2', 'prof-b@example.com');
insert into public.account_devices (user_id, device_id, app_version) values
  ('00000000-0000-4000-8000-0000000000a1', 'd1', '1.0.1 (145)'),
  ('00000000-0000-4000-8000-0000000000a1', 'd2', '1.0.1 (146)'),
  ('00000000-0000-4000-8000-0000000000a2', 'd3', '1.0.1 (146)'),
  ('00000000-0000-4000-8000-0000000000a2', 'd4', null);

-- standaardstand: mirror
select pg_temp.ok((select value #>> '{}' from public.app_settings where key = 'profiles_legacy') = 'mirror', 'standaard mirror');
select pg_temp.ok(not has_column_privilege('authenticated', 'public.account_data', 'sealed', 'select'), 'sealed niet leesbaar voor apps');
select pg_temp.ok(not has_column_privilege('authenticated', 'public.account_data', 'sealed', 'update'), 'sealed niet schrijfbaar voor apps');
select pg_temp.ok(not has_column_privilege('authenticated', 'public.account_data', 'profile_count', 'insert'), 'profile_count niet schrijfbaar');
select pg_temp.ok(has_column_privilege('authenticated', 'public.account_data', 'profiles', 'select'), 'profiles leesbaar (oude apps)');
select pg_temp.ok(has_column_privilege('authenticated', 'public.account_data', 'profiles', 'update'), 'profiles schrijfbaar (oude apps)');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_profiles_status()', 'execute'), 'status niet voor apps');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_stats_seal(jsonb)', 'execute'), 'stats_seal niet voor apps');

-- 1. oude app schrijft rechtstreeks (zoals PostgREST: rol authenticated + claims)
set role authenticated;
set request.jwt.claims = '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1"}';
insert into public.account_data (user_id, profiles, updated_at) values ('00000000-0000-4000-8000-0000000000a1',
  '[{"id":"P1","name":"Léon","isMain":true,"order":0},{"id":"P2","name":"Kids","kids":true,"order":1},{"id":"P3","deleted":true,"deletedAt":"2026-10-01T00:00:00Z"}]',
  '2026-10-24T10:00:00Z')
  on conflict (user_id) do update set profiles = excluded.profiles, updated_at = excluded.updated_at;
-- een app kan sealed niet zetten of lezen
do $$ begin
  insert into public.account_data (user_id, profiles, sealed) values ('00000000-0000-4000-8000-0000000000a1', '[]', 'x');
  raise exception 'MISLUKT: sealed schrijven had geweigerd moeten worden';
exception when insufficient_privilege then null; end $$;
do $$ declare v text; begin
  select sealed into v from public.account_data;
  raise exception 'MISLUKT: sealed lezen had geweigerd moeten worden';
exception when insufficient_privilege then null; end $$;
-- RLS: een ander account ziet niets
set request.jwt.claims = '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a2"}';
select pg_temp.ok((select count(*) from public.account_data) = 0, 'ander account ziet de rij niet');
reset role;
reset request.jwt.claims;
select pg_temp.ok((select profile_count from public.account_data where user_id = '00000000-0000-4000-8000-0000000000a1') = 2, 'telling zonder tombstone');
select pg_temp.ok((select legacy_at is not null and not plain_cleared and sealed is null from public.account_data where user_id = '00000000-0000-4000-8000-0000000000a1'), 'legacy_at gezet');

-- 2. de functie (service role) schrijft versleuteld en maakt de kopie leeg: de trigger laat dat ongemoeid
set request.jwt.claims = '{"role":"service_role"}';
update public.account_data set sealed = 'SEALED', sealed_at = now(), profile_count = 3, plain_cleared = true, profiles = '[]',
  legacy_at = null, updated_at = '2026-10-24T11:00:00Z' where user_id = '00000000-0000-4000-8000-0000000000a1';
reset request.jwt.claims;
select pg_temp.ok((select sealed = 'SEALED' and profile_count = 3 and plain_cleared and legacy_at is null from public.account_data where user_id = '00000000-0000-4000-8000-0000000000a1'), 'service role ongemoeid');
select pg_temp.ok((select public.bingr_profile_count(a) from public.account_data a where user_id = '00000000-0000-4000-8000-0000000000a1') = 3, 'telling uit de kolom');

-- 3. oude app schrijft opnieuw (upsert): versleutelde lijst blijft, kopie weer "in gebruik", telling opnieuw
set role authenticated;
set request.jwt.claims = '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1"}';
insert into public.account_data (user_id, profiles, updated_at) values ('00000000-0000-4000-8000-0000000000a1', '[{"id":"P1","name":"Léon"}]', '2026-10-24T12:00:00Z')
  on conflict (user_id) do update set profiles = excluded.profiles, updated_at = excluded.updated_at;
select pg_temp.ok((select count(*) from public.account_data) = 1, 'eigen rij leesbaar');
reset role;
reset request.jwt.claims;
select pg_temp.ok((select sealed = 'SEALED' and not plain_cleared and profile_count = 1 and legacy_at is not null from public.account_data where user_id = '00000000-0000-4000-8000-0000000000a1'), 'upsert van oude app');

-- 4. stand van de overgang
select pg_temp.ok((public.bingr_profiles_status()->>'accounts')::int = 1, 'status: accounts');
select pg_temp.ok((public.bingr_profiles_status()->>'sealed')::int = 1, 'status: sealed');
select pg_temp.ok((public.bingr_profiles_status()->>'old_devices')::int = 2, 'status: oude apparaten (145 en zonder versie)');
select pg_temp.ok((public.bingr_profiles_status()->>'accounts_with_old_devices')::int = 2, 'status: accounts met oude apparaten');

-- 5. stand "off": rechtstreeks schrijven geweigerd (42501, hint bingr_profiles_moved), de functie mag wel
update public.app_settings set value = '"off"' where key = 'profiles_legacy';
set role authenticated;
set request.jwt.claims = '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1"}';
do $$ begin
  update public.account_data set profiles = '[]', updated_at = now() where user_id = '00000000-0000-4000-8000-0000000000a1';
  raise exception 'MISLUKT: off had moeten weigeren';
exception when insufficient_privilege then
  if sqlerrm <> 'profiles_moved' then raise exception 'MISLUKT: verkeerde melding %', sqlerrm; end if;
end $$;
reset role;
reset request.jwt.claims;
set request.jwt.claims = '{"role":"service_role"}';
update public.account_data set profiles = '[]', plain_cleared = true where user_id = '00000000-0000-4000-8000-0000000000a1';
reset request.jwt.claims;
select pg_temp.ok((select plain_cleared from public.account_data where user_id = '00000000-0000-4000-8000-0000000000a1'), 'service role bij off');
update public.app_settings set value = '"mirror"' where key = 'profiles_legacy';

-- 6. bingr_stats_item: referentie voor device-auth/watch.ts (dezelfde gevallen staan in watch_test.ts)
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('episode', 'e1', null, null, 'De Serie · S1:E2 · Pilot') x)
  = '{"kind":"episode","item_key":"t:de serie","title":"De Serie"}', 'aflevering zonder series_id');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('episode', 'e1', null, null, 'Serie S01E02 Naam') x)
  = '{"kind":"episode","item_key":"t:serie","title":"Serie"}', 'S01E02');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('episode', 'e1', null, null, 'Serie - S1E2') x)
  = '{"kind":"episode","item_key":"t:serie","title":"Serie"}', 'Serie - S1E2');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('series', 'e1', 's9', 'Echte Titel', 'x') x)
  = '{"kind":"episode","item_key":"s9","title":"Echte Titel"}', 'met series_id');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('live', 'c1', null, null, 'NPO 1 · Journaal') x)
  = '{"kind":"live","item_key":"c1","title":"NPO 1"}', 'live');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('catchup', null, null, null, 'NPO 2') x)
  = '{"kind":"live","item_key":"t:npo 2","title":"NPO 2"}', 'terugkijken zonder id');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('movie', '', null, null, '  Dune  ') x)
  = '{"kind":"movie","item_key":"t:dune","title":"Dune"}', 'film zonder id');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('radio', 'r1', null, null, 'x') x)
  = '{"kind":null,"item_key":null,"title":null}', 'onbekende soort');
select pg_temp.ok((select to_jsonb(x) from public.bingr_stats_item('episode', null, null, null, 'S01E01') x)
  = '{"kind":"episode","item_key":"t:s01e01","title":"S01E01"}', 'alleen code');

-- 7. bingr_stats_seal: sleutel vervangen, samenvoegen bij gelijke nieuwe sleutel, alleen versleutelen bij gelijke sleutel
insert into public.account_watch_stats (user_id, profile_id, profile_name, day, kind, item_key, title, episodes, minutes, plays) values
  ('00000000-0000-4000-8000-0000000000a1', 'P1', 'Léon', '2026-10-20', 'episode', 't:de serie', 'De Serie', '{e1}', 30, 1),
  ('00000000-0000-4000-8000-0000000000a1', 'P1', 'Léon', '2026-10-20', 'episode', 't:De Serie', 'De Serie', '{e2,e1}', 15, 2),
  ('00000000-0000-4000-8000-0000000000a1', 'P1', 'Léon', '2026-10-20', 'movie', 'm1', 'Dune', '{}', 120, 1);
select pg_temp.ok(public.bingr_stats_seal('[
  {"user_id":"00000000-0000-4000-8000-0000000000a1","profile_id":"P1","day":"2026-10-20","kind":"episode","old_key":"t:de serie","new_key":"h:abc","title":"enc1:T","profile_name":"enc1:N"},
  {"user_id":"00000000-0000-4000-8000-0000000000a1","profile_id":"P1","day":"2026-10-20","kind":"episode","old_key":"t:De Serie","new_key":"h:abc","title":"enc1:T2","profile_name":"enc1:N2"},
  {"user_id":"00000000-0000-4000-8000-0000000000a1","profile_id":"P1","day":"2026-10-20","kind":"movie","old_key":"m1","new_key":"m1","title":"enc1:D","profile_name":"enc1:N"}
]'::jsonb) = 3, 'drie rijen');
select pg_temp.ok((select count(*) from public.account_watch_stats) = 2, 'samengevoegd tot twee rijen');
select pg_temp.ok((select minutes = 45 and plays = 3 and title = 'enc1:T' and profile_name = 'enc1:N' and cardinality(episodes) = 2
  from public.account_watch_stats where item_key = 'h:abc'), 'opgeteld, unieke afleveringen');
select pg_temp.ok((select title = 'enc1:D' and minutes = 120 from public.account_watch_stats where item_key = 'm1'), 'zelfde sleutel versleuteld');
select pg_temp.ok((select count(*) from public.account_watch_stats where item_key like 't:%' or title not like 'enc1:%') = 0, 'niets leesbaars over');
