-- Unittests van watch_month (trigger op account_watch_stats) en de wachtrij van de maandrecap. Draait na recap_stub.sql en
-- de schemablokken; zie recap_test.sh. Elke controle stopt met een fout als hij niet klopt. Alleen nepgegevens.
create or replace function pg_temp.check(ok boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(ok, false) then raise exception 'mislukt: %', msg; end if; end $$;

-- zoals bingr_stream_start: stream op het apparaat, en één weergave in de statistieken
create or replace function pg_temp.start(u uuid, dev text, d date, k text, key text, label text, tz text default 'Europe/Amsterdam') returns void
language sql as $$
  insert into public.account_streams (user_id, device_id, title, tz, stat_kind, stat_key, last_ping) values (u, dev, label, tz, k, key, now())
  on conflict (user_id, device_id) do update set title = excluded.title, tz = excluded.tz, stat_kind = excluded.stat_kind, stat_key = excluded.stat_key, last_ping = now();
  insert into public.account_watch_stats as w (user_id, profile_id, day, kind, item_key, title, plays) values (u, 'p1', d, k, key, 'enc1:T', 1)
  on conflict (user_id, profile_id, day, kind, item_key) do update set plays = w.plays + 1, updated_at = now();
$$;
-- zoals bingr_stream_account: minuten (en de aflevering) bijschrijven
create or replace function pg_temp.watch(u uuid, d date, k text, key text, mins numeric, ep text default null) returns void
language sql as $$
  insert into public.account_watch_stats as w (user_id, profile_id, day, kind, item_key, title, episodes, minutes, plays)
  values (u, 'p1', d, k, key, 'enc1:T', case when ep is null then '{}'::text[] else array[ep] end, mins, 0)
  on conflict (user_id, profile_id, day, kind, item_key) do update set minutes = w.minutes + excluded.minutes,
    episodes = case when cardinality(excluded.episodes) = 0 or excluded.episodes[1] = any(w.episodes) then w.episodes else w.episodes || excluded.episodes end,
    updated_at = now();
$$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'a@example.invalid', now(), '{"lang":"nl","first_name":"Alex"}'),
  ('00000000-0000-4000-8000-000000000002', 'b@example.invalid', now(), '{"lang":"en","display_name":"Sam"}'),
  ('00000000-0000-4000-8000-000000000003', 'c@example.invalid', now(), '{}'),
  ('00000000-0000-4000-8000-000000000004', 'd@example.invalid', now(), '{}'),
  ('00000000-0000-4000-8000-000000000005', 'e@example.invalid', now(), '{}');
-- Lifetime: 1, 2 en 4; 3 en 5 Gratis (geen rij = Gratis)
insert into public.account_plans (user_id, plan) values ('00000000-0000-4000-8000-000000000001', 'lifetime'),
  ('00000000-0000-4000-8000-000000000002', 'lifetime'), ('00000000-0000-4000-8000-000000000004', 'lifetime');

-- Gratis: kijken telt wel in de statistieken, maar niets in watch_month
select pg_temp.start('00000000-0000-4000-8000-000000000005', 'tv', current_date - 3, 'movie', 'movie:5', 'enc1:Film');
select pg_temp.watch('00000000-0000-4000-8000-000000000005', current_date - 3, 'movie', 'movie:5', 50);
select pg_temp.start('00000000-0000-4000-8000-000000000005', 'tv', current_date - 20, 'movie', 'movie:6', 'enc1:Oud');
select pg_temp.watch('00000000-0000-4000-8000-000000000005', current_date - 20, 'movie', 'movie:6', 40);
select pg_temp.check(not exists (select 1 from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005'), 'Gratis: geen aggregatie');
-- upgrade naar Lifetime: alleen de laatste 8 dagen worden aangevuld, daarna telt de trigger
insert into public.account_plans (user_id, plan) values ('00000000-0000-4000-8000-000000000005', 'free');
select pg_temp.check(not exists (select 1 from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005'), 'Gratis-rij: nog steeds niets');
update public.account_plans set plan = 'lifetime' where user_id = '00000000-0000-4000-8000-000000000005';
select pg_temp.check((select count(*) = 1 and bool_and(approx) and sum(minutes) = 50 from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005'),
  'upgrade: laatste 8 dagen aangevuld, ouder niet');
select pg_temp.watch('00000000-0000-4000-8000-000000000005', current_date - 3, 'movie', 'movie:5', 10);
select pg_temp.check((select minutes = 60 from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005' and item_key = 'movie:5'), 'na de upgrade telt de trigger');
-- terug naar Gratis: geen nieuwe aggregatie (wat er is blijft staan)
update public.account_plans set plan = 'free' where user_id = '00000000-0000-4000-8000-000000000005';
select pg_temp.watch('00000000-0000-4000-8000-000000000005', current_date - 3, 'movie', 'movie:5', 10);
select pg_temp.check((select minutes = 60 from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005' and item_key = 'movie:5'), 'terug naar Gratis: niet meer bijgewerkt');
delete from public.watch_month where user_id = '00000000-0000-4000-8000-000000000005';

-- een serie met afleveringen: 2 weergaven, 3 afleveringen (één dubbel), op 2 dagen
select pg_temp.start('00000000-0000-4000-8000-000000000001', 'tv', '2026-11-03', 'episode', 'series:1', 'enc1:S1E1');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-03', 'episode', 'series:1', 40, 'e1');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-03', 'episode', 'series:1', 2.5, 'e1');
select pg_temp.start('00000000-0000-4000-8000-000000000001', 'tv', '2026-11-04', 'episode', 'series:1', 'enc1:S1E2');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-04', 'episode', 'series:1', 45, 'e2');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-04', 'episode', 'series:1', 30, 'e3');
-- een film en live tv
select pg_temp.start('00000000-0000-4000-8000-000000000001', 'tv', '2026-11-05', 'movie', 'movie:9', 'enc1:Film');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-05', 'movie', 'movie:9', 110);
select pg_temp.start('00000000-0000-4000-8000-000000000001', 'tv', '2026-11-06', 'live', 'ch:1', 'enc1:Zender');
select pg_temp.watch('00000000-0000-4000-8000-000000000001', '2026-11-06', 'live', 'ch:1', 25);

select pg_temp.check((select plays = 2 and minutes = 117.5 and cardinality(episodes) = 3 and first_label = 'enc1:S1E1' and last_label = 'enc1:S1E2'
  and tz = 'Europe/Amsterdam' and not approx from public.watch_month where item_key = 'series:1'), 'serie: weergaven, minuten, afleveringen, labels');
select pg_temp.check((select plays = 1 and minutes = 110 and month = '2026-11' from public.watch_month where item_key = 'movie:9'), 'film');
select pg_temp.check((select minutes = 25 and first_label is null from public.watch_month where kind = 'live'), 'live: minuten, geen label');
select pg_temp.check((select first_at <= last_at from public.watch_month where item_key = 'series:1'), 'eerste vóór laatste');

-- bingr_recap_rows: opgeteld over profielen
insert into public.account_watch_stats (user_id, profile_id, day, kind, item_key, title, episodes, minutes, plays)
values ('00000000-0000-4000-8000-000000000001', 'p2', '2026-11-07', 'episode', 'series:1', 'enc1:T', '{e3,e4}', 20, 1);
select pg_temp.check((select (r->>'plays')::int = 3 and (r->>'minutes')::numeric = 137.5 and (r->>'episodes')::int = 4
  from jsonb_array_elements(public.bingr_recap_rows('00000000-0000-4000-8000-000000000001', '2026-11')) r where r->>'item_key' = 'series:1'),
  'rows: over profielen, unieke afleveringen');
select pg_temp.check(jsonb_array_length(public.bingr_recap_rows('00000000-0000-4000-8000-000000000001', '2026-11')) = 3, 'rows: drie titels');

-- titel versleuteld door het onderhoud: meegenomen
update public.account_watch_stats set title = 'enc1:NIEUW' where item_key = 'movie:9';
select pg_temp.check((select title = 'enc1:NIEUW' and minutes = 110 from public.watch_month where item_key = 'movie:9'), 'alleen titel bijgewerkt');

-- statistieken wissen (profiel p2): de maandrij van dat profiel gaat weg, p1 blijft
delete from public.account_watch_stats where user_id = '00000000-0000-4000-8000-000000000001' and profile_id = 'p2';
select pg_temp.check(not exists (select 1 from public.watch_month where profile_id = 'p2'), 'wissen per profiel');
select pg_temp.check(exists (select 1 from public.watch_month where profile_id = 'p1' and item_key = 'series:1'), 'ander profiel blijft');

-- 13 maanden bewaren: in november 2026 blijft november 2025 en gaat oktober 2025 weg
select pg_temp.check(public.bingr_watch_month_cutoff('2026-11-01 00:30+00') = '2025-11', 'grens nov 2026');
select pg_temp.check(public.bingr_watch_month_cutoff('2027-01-31 23:00+00') = '2026-01', 'grens jan 2027');
insert into public.watch_month (user_id, month, kind, item_key, minutes) values
  ('00000000-0000-4000-8000-000000000004', '2025-10', 'movie', 'old', 5), ('00000000-0000-4000-8000-000000000004', '2025-11', 'movie', 'keep', 5);

-- kandidaten oktober: account 2 (Lifetime, keek), 3 (Gratis, keek), 4 (Lifetime, afgemeld), 5 (Gratis, keek weinig)
insert into public.watch_month (user_id, month, kind, item_key, minutes, tz) values
  ('00000000-0000-4000-8000-000000000002', '2026-10', 'movie', 'm', 50, 'America/New_York'),
  ('00000000-0000-4000-8000-000000000003', '2026-10', 'movie', 'm', 50, null),
  ('00000000-0000-4000-8000-000000000005', '2026-10', 'movie', 'm', 0.5, null),
  ('00000000-0000-4000-8000-000000000004', '2026-10', 'movie', 'm', 50, null);
insert into public.account_email_prefs (user_id, newsletter_opt_out) values ('00000000-0000-4000-8000-000000000004', true);
insert into public.account_country (user_id, country) values ('00000000-0000-4000-8000-000000000002', 'US');
select pg_temp.check(jsonb_array_length(public.bingr_recap_candidates(array['2026-10'], null, 100)) = 1, 'kandidaten: alleen Lifetime die keek en ingeschreven is');
select pg_temp.check((select r->>'tz' = 'America/New_York' and r->>'country' = 'US' from jsonb_array_elements(public.bingr_recap_candidates(array['2026-10'], null, 100)) r),
  'kandidaat: tijdzone en land');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.bingr_recap_candidates(array['2026-10'], null, 100)) r
  where r->>'id' = '00000000-0000-4000-8000-000000000003'), 'Gratis: geen recap');
select pg_temp.check(jsonb_array_length(public.bingr_recap_candidates(array['2026-11'], null, 100)) = 1, 'november: account 1 (Lifetime)');

-- één keer per account en maand
select pg_temp.check((select r->>'display_name' = 'Sam' and r->>'lang' = 'en' from jsonb_array_elements(public.bingr_recap_claim('2026-10', array['00000000-0000-4000-8000-000000000002'::uuid])) r),
  'claim: naam en taal');
select pg_temp.check(jsonb_array_length(public.bingr_recap_claim('2026-10', array['00000000-0000-4000-8000-000000000002'::uuid])) = 0, 'claim: niet twee keer');
select pg_temp.check(jsonb_array_length(public.bingr_recap_candidates(array['2026-10'], null, 100)) = 0, 'na de claim geen kandidaat meer');
-- tijdelijke fout: opnieuw (max. 3 pogingen), daarna failed
select public.bingr_recap_mark('2026-10', '{}', '{}', '{}', array['00000000-0000-4000-8000-000000000002'::uuid], '{}', '{}');
select pg_temp.check((select state = 'queued' from public.recap_deliveries where user_id = '00000000-0000-4000-8000-000000000002'), 'retry: queued');
select pg_temp.check(jsonb_array_length(public.bingr_recap_candidates(array['2026-10'], null, 100)) = 1, 'retry: weer kandidaat');
select public.bingr_recap_claim('2026-10', array['00000000-0000-4000-8000-000000000002'::uuid]);
select public.bingr_recap_mark('2026-10', '{}', '{}', '{}', array['00000000-0000-4000-8000-000000000002'::uuid], '{}', '{}');
select public.bingr_recap_claim('2026-10', array['00000000-0000-4000-8000-000000000002'::uuid]);
select public.bingr_recap_mark('2026-10', '{}', '{}', '{}', array['00000000-0000-4000-8000-000000000002'::uuid], '{}', '{}');
select pg_temp.check((select state = 'failed' and attempts = 3 from public.recap_deliveries where user_id = '00000000-0000-4000-8000-000000000002'), 'na 3 pogingen failed');
select pg_temp.check(jsonb_array_length(public.bingr_recap_claim('2026-10', array['00000000-0000-4000-8000-000000000002'::uuid])) = 0, 'failed: nooit opnieuw');
-- verstuurd en overgeslagen; afgemeld bij de claim = skipped
select public.bingr_recap_claim('2026-11', array['00000000-0000-4000-8000-000000000001'::uuid, '00000000-0000-4000-8000-000000000004'::uuid]);
select pg_temp.check((select state = 'skipped' and reason = 'unsubscribed' from public.recap_deliveries where user_id = '00000000-0000-4000-8000-000000000004'), 'afgemeld: skipped');
select public.bingr_recap_mark('2026-11', array['00000000-0000-4000-8000-000000000001'::uuid], '{}', '{}', '{}', '{}', '{}');
select pg_temp.check((select (h->>'sent')::int = 1 and (h->>'skipped')::int = 1 from jsonb_array_elements(public.bingr_recap_history(13)) h where h->>'month' = '2026-11'), 'geschiedenis november');
select pg_temp.check((select (h->>'failed')::int = 1 from jsonb_array_elements(public.bingr_recap_history(13)) h where h->>'month' = '2026-10'), 'geschiedenis oktober');
select pg_temp.check((public.bingr_recap_account('A@example.invalid')->>'first_name') = 'Alex', 'account bij adres');
select pg_temp.check(public.bingr_recap_account('niemand@example.invalid') is null, 'geen account');

-- opruimen: ouder dan 13 maanden weg (de test rekent met de echte datum: alleen wat zeker oud genoeg is)
insert into public.watch_month (user_id, month, kind, item_key, minutes) values ('00000000-0000-4000-8000-000000000004', '2020-01', 'movie', 'heel-oud', 5);
select public.bingr_recap_cleanup();
select pg_temp.check(not exists (select 1 from public.watch_month where month = '2020-01'), 'opruimen: oud weg');
select pg_temp.check(exists (select 1 from public.watch_month where month = '2026-11'), 'opruimen: deze maand blijft');
