-- Tests voor build 171 (crash_test.sh). Elke controle gooit een fout als hij niet klopt. Alleen verzonnen gegevens.
create or replace function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'MISLUKT: %', what; end if; end $$;

-- 1. nieuw rapport = nieuwe groep met melding 'new'
select pg_temp.check((public.bingr_crash_report('{"platform":"ios","kind":"crash","signature":"SIG-A","build":170,"message":"m1","stack":"s1","count":2}'::jsonb,
  repeat('a', 32), repeat('b', 32))->>'group') = 'new', 'eerste rapport = new');
select pg_temp.check((select pending_notice from public.crash_groups where signature = 'SIG-A') = 'new', 'melding new klaar');
select pg_temp.check((public.bingr_crash_report('{"platform":"android","kind":"crash","signature":"SIG-A","build":171}'::jsonb)->>'group') = 'known', 'tweede = known');
select pg_temp.check((select signed_in from public.crash_reports where signature = 'SIG-A' and platform = 'android') = false, 'zonder account = niet ingelogd');

-- 2. beheer: groepen met aantallen, platforms en builds; filter op platform en build
select pg_temp.check(jsonb_array_length(public.bingr_admin_crashes()->'groups') = 1, 'één groep');
select pg_temp.check((public.bingr_admin_crashes()->'groups'->0->>'reports')::int = 2, 'twee rapporten');
select pg_temp.check((public.bingr_admin_crashes()->'groups'->0->>'occurrences')::int = 3, 'drie keer gebeurd (count)');
select pg_temp.check(public.bingr_admin_crashes()->'groups'->0->'platforms' = '["android","ios"]'::jsonb, 'platforms');
select pg_temp.check(public.bingr_admin_crashes()->'groups'->0->'builds' = '[170,171]'::jsonb, 'builds');
select pg_temp.check(public.bingr_admin_crashes('ios')->'groups'->0->'builds' = '[170]'::jsonb, 'filter platform');
select pg_temp.check(jsonb_array_length(public.bingr_admin_crashes(null, 999)->'groups') = 0, 'filter build');
select pg_temp.check(public.bingr_admin_crashes()->'builds' = '[171,170]'::jsonb, 'buildlijst voor het filter');
select pg_temp.check((public.bingr_admin_crashes()->'totals'->>'open')::int = 1, 'totaal open');

-- 3. details met stack
select pg_temp.check(jsonb_array_length(public.bingr_admin_crash_detail('SIG-A')->'reports') = 2, 'details: 2 rapporten');
select pg_temp.check(public.bingr_admin_crash_detail('SIG-A', 'ios')->'reports'->0->>'stack' = 's1', 'details: stack');
select pg_temp.check(public.bingr_admin_crash_detail('BESTAAT-NIET') is null, 'onbekende groep = null');

-- 4. pushmelding claimen: één keer
select pg_temp.check(jsonb_array_length(public.bingr_crash_notices_claim()) = 1, 'claim 1');
select pg_temp.check(public.bingr_crash_notices_claim() = '[]'::jsonb, 'claim daarna leeg');

-- 5. opgelost in build 172; een rapport van 171 (oude app) = niet terug; van 172 = teruggekomen (één keer)
select pg_temp.check(public.bingr_admin_crash_resolve('SIG-A', 172) = 'resolved', 'opgelost');
select pg_temp.check((public.bingr_crash_report('{"platform":"ios","kind":"crash","signature":"SIG-A","build":171}'::jsonb)->>'group') = 'known', 'oude build: niet terug');
select pg_temp.check((public.bingr_crash_report('{"platform":"ios","kind":"crash","signature":"SIG-A","build":172}'::jsonb)->>'group') = 'regressed', 'build 172: terug');
select pg_temp.check((public.bingr_crash_report('{"platform":"ios","kind":"crash","signature":"SIG-A","build":173}'::jsonb)->>'group') = 'known', 'teruggekomen maar één keer gemeld');
select pg_temp.check(public.bingr_crash_notices_claim()->0->>'notice' = 'regressed', 'melding regressed');
select pg_temp.check(public.bingr_admin_crashes(null, null, 'regressed')->'groups'->0->>'status' = 'regressed', 'filter status');
select pg_temp.check(public.bingr_admin_crash_resolve('SIG-A', null) = 'open', 'weer open');
select pg_temp.check(public.bingr_admin_crash_resolve('BESTAAT-NIET', 5) is null, 'onbekend = null');
do $$ begin perform public.bingr_admin_crash_resolve('SIG-A', 0); raise exception 'MISLUKT: build 0 geaccepteerd';
exception when sqlstate '22023' then null; end $$;

-- 6. grenzen in de tabel (ook als device-auth iets doorlaat)
do $$ begin perform public.bingr_crash_report(jsonb_build_object('platform','ios','kind','crash','signature','X','message', repeat('x', 501)));
  raise exception 'MISLUKT: message > 500'; exception when check_violation then null; end $$;
do $$ begin perform public.bingr_crash_report(jsonb_build_object('platform','ios','kind','crash','signature','X','stack', repeat('x', 16385)));
  raise exception 'MISLUKT: stack > 16 KB'; exception when check_violation then null; end $$;
do $$ begin perform public.bingr_crash_report('{"platform":"tizen","kind":"crash","signature":"X"}'::jsonb);
  raise exception 'MISLUKT: tizen'; exception when check_violation then null; end $$;
do $$ begin perform public.bingr_crash_report('{"platform":"ios","kind":"crash","signature":"X"}'::jsonb, 'jan@example.invalid');
  raise exception 'MISLUKT: geen hash als account'; exception when check_violation then null; end $$;

-- 7. opschonen na 90 dagen
insert into public.crash_groups (signature, kind, first_seen, last_seen) values ('OUD', 'anr', now() - interval '120 days', now() - interval '100 days');
insert into public.crash_reports (signature, platform, kind, occurred_at, created_at) values ('OUD', 'android', 'anr', now() - interval '100 days', now() - interval '100 days');
insert into auth.users (id) values ('00000000-0000-0000-0000-000000000001');
insert into public.account_stream_stops (user_id, device_id, stopped_at) values ('00000000-0000-0000-0000-000000000001', 'd1', now() - interval '2 days'),
  ('00000000-0000-0000-0000-000000000001', 'd2', now());
select pg_temp.check(public.bingr_crash_cleanup() = 1, 'één oud rapport weg');
select pg_temp.check(not exists (select 1 from public.crash_groups where signature = 'OUD'), 'oude groep weg');
select pg_temp.check(exists (select 1 from public.crash_groups where signature = 'SIG-A'), 'recente groep blijft');
select pg_temp.check((select count(*) from public.account_stream_stops) = 1, 'oude stopmarkering weg, nieuwe blijft');

-- 8. rechten: alleen de service role
select pg_temp.check(not has_table_privilege('anon', 'public.crash_reports', 'select'), 'anon leest geen rapporten');
select pg_temp.check(not has_table_privilege('authenticated', 'public.crash_reports', 'insert'), 'authenticated schrijft niet');
select pg_temp.check(not has_table_privilege('authenticated', 'public.crash_groups', 'select'), 'authenticated leest geen groepen');
select pg_temp.check(not has_table_privilege('anon', 'public.account_stream_stops', 'select'), 'anon leest geen stopmarkeringen');
select pg_temp.check(not has_function_privilege('anon', 'public.bingr_crash_report(jsonb, text, text)', 'execute'), 'anon roept niets aan');
select pg_temp.check(not has_function_privilege('authenticated', 'public.bingr_admin_crashes(text, int, text, int)', 'execute'), 'authenticated geen beheer');
select pg_temp.check(has_function_privilege('service_role', 'public.bingr_admin_crashes(text, int, text, int)', 'execute'), 'service role wel');
select pg_temp.check((select relrowsecurity from pg_class where oid = 'public.crash_reports'::regclass), 'RLS aan');
