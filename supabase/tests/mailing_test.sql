-- Unittests van de eigen mailing (bingr_mailing_*). Draait via mailing_test.sh in een tijdelijke database. Alleen testadressen.
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
-- accounts: 1 nl, 2 de (-> en), 3 leeg (-> nl), 4 nieuwsbrief uit (en), 5 alle mail uit (nl), 6 geblokkeerd, 7 blokkade
-- verlopen (en), 8 onbevestigd, 9 verwijderd, 10 zonder adres
insert into auth.users (id, email, email_confirmed_at, deleted_at, banned_until, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'u1@example.invalid', now(), null, null, '{"lang":"nl","first_name":"Een"}'),
  ('00000000-0000-4000-8000-000000000002', 'u2@example.invalid', now(), null, null, '{"lang":"de"}'),
  ('00000000-0000-4000-8000-000000000003', 'u3@example.invalid', now(), null, null, '{}'),
  ('00000000-0000-4000-8000-000000000004', 'u4@example.invalid', now(), null, null, '{"lang":"en"}'),
  ('00000000-0000-4000-8000-000000000005', 'u5@example.invalid', now(), null, null, '{"lang":"NL-be"}'),
  ('00000000-0000-4000-8000-000000000006', 'u6@example.invalid', now(), null, now() + interval '10 days', '{"lang":"nl"}'),
  ('00000000-0000-4000-8000-000000000007', 'u7@example.invalid', now(), null, now() - interval '1 day', '{"lang":"fr"}'),
  ('00000000-0000-4000-8000-000000000008', 'u8@example.invalid', null, null, null, '{"lang":"nl"}'),
  ('00000000-0000-4000-8000-000000000009', 'u9@example.invalid', now(), now(), null, '{"lang":"nl"}'),
  ('00000000-0000-4000-8000-000000000010', null, now(), null, null, '{"lang":"nl"}');
insert into public.account_email_prefs (user_id, email_opt_out, newsletter_opt_out) values
  ('00000000-0000-4000-8000-000000000004', false, true),
  ('00000000-0000-4000-8000-000000000005', true, false);

-- doelgroep
select pg_temp.ok(public.bingr_mailing_count('newsletter') = '{"nl": 2, "en": 2, "total": 4}'::jsonb, 'nieuwsbrief: 1, 2, 3, 7');
select pg_temp.ok(public.bingr_mailing_count('service') = '{"nl": 3, "en": 3, "total": 6}'::jsonb, 'service: ook 4 en 5 (afgemeld)');
select pg_temp.ok((select array_agg(user_id order by user_id)::text from public.bingr_mailing_audience('newsletter'))
  = '{00000000-0000-4000-8000-000000000001,00000000-0000-4000-8000-000000000002,00000000-0000-4000-8000-000000000003,00000000-0000-4000-8000-000000000007}', 'nieuwsbrief: precies deze');
select pg_temp.ok((select lang from public.bingr_mailing_audience('service') where user_id = '00000000-0000-4000-8000-000000000005') = 'nl', 'NL-be -> nl');
select pg_temp.ok((select lang from public.bingr_mailing_audience('service') where user_id = '00000000-0000-4000-8000-000000000003') = 'nl', 'leeg -> nl');
select pg_temp.ok((select lang from public.bingr_mailing_audience('service') where user_id = '00000000-0000-4000-8000-000000000002') = 'en', 'de -> en');
select pg_temp.ok(not exists (select 1 from public.bingr_mailing_audience('service') where user_id in
  ('00000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000008', '00000000-0000-4000-8000-000000000009', '00000000-0000-4000-8000-000000000010')),
  'nooit geblokkeerd, onbevestigd, verwijderd of zonder adres');
select pg_temp.ok(public.bingr_mailing_count('iets') = '{"nl": 0, "en": 0, "total": 0}'::jsonb, 'onbekende doelgroep: niemand');
-- eligible gelijk aan audience
select pg_temp.ok((select count(*) from auth.users u where public.bingr_mailing_eligible(u.id, 'newsletter')) = 4, 'eligible nieuwsbrief');
select pg_temp.ok((select count(*) from auth.users u where public.bingr_mailing_eligible(u.id, 'service')) = 6, 'eligible service');

-- aanmaken: idempotent per request_id, één tegelijk
select pg_temp.ok(public.bingr_mailing_create('11111111-1111-4111-8111-111111111111', 'iets', '{}') ->> 'error' = 'bad_audience', 'foute doelgroep');
create temp table c1 as select public.bingr_mailing_create('11111111-1111-4111-8111-111111111111', 'newsletter', '{"nl":{"subject":"a"}}') r;
select pg_temp.ok((select r->>'duplicate' from c1) = 'false' and (select r->'recipients' from c1) = '{"nl": 2, "en": 2, "total": 4}'::jsonb, 'aangemaakt met 4 ontvangers');
create temp table c2 as select public.bingr_mailing_create('11111111-1111-4111-8111-111111111111', 'newsletter', '{}') r;
select pg_temp.ok((select r->>'duplicate' from c2) = 'true' and (select r->>'id' from c2) = (select r->>'id' from c1), 'zelfde request_id: zelfde mailing');
select pg_temp.ok(public.bingr_mailing_create('22222222-2222-4222-8222-222222222222', 'service', '{}') ->> 'error' = 'mailing_busy', 'tweede tegelijk: busy');
select pg_temp.ok((select count(*) from public.mailings) = 1, 'één mailing');
select pg_temp.ok((select count(*) from public.mailing_recipients) = 4, 'vier ontvangers, elk één keer');

-- wachtrij: take claimt, niemand twee keer
create temp table t1 as select public.bingr_mailing_take((select (r->>'id')::bigint from c1), 2) r;
select pg_temp.ok(jsonb_array_length((select r->'items' from t1)) = 2, 'batch van 2');
select pg_temp.ok((select r->'items'->0->>'email' from t1) = 'u1@example.invalid' and (select r->'items'->0->>'lang' from t1) = 'nl'
  and (select r->'items'->0->>'first_name' from t1) = 'Een', 'eerste ontvanger met taal en voornaam');
-- intussen meldt account 3 zich af voor de nieuwsbrief: wordt overgeslagen
insert into public.account_email_prefs (user_id, newsletter_opt_out) values ('00000000-0000-4000-8000-000000000003', true);
create temp table t2 as select public.bingr_mailing_take((select (r->>'id')::bigint from c1), 10) r;
select pg_temp.ok(jsonb_array_length((select r->'items' from t2)) = 1 and (select r->'items'->0->>'id' from t2) = '00000000-0000-4000-8000-000000000007', 'tweede batch: alleen 7 (3 overgeslagen, 1 en 2 al geclaimd)');
select pg_temp.ok((select skipped from public.mailings) = 1, 'skipped geteld');
create temp table t3 as select public.bingr_mailing_take((select (r->>'id')::bigint from c1), 10) r;
select pg_temp.ok(jsonb_array_length((select r->'items' from t3)) = 0 and (select r->>'busy' from t3) = 'true', 'niets meer vrij, nog bezig');
-- resultaat: 1 verstuurd, 2 tijdelijke fout (terug), 7 niet aan toegekomen (release)
select public.bingr_mailing_mark((select (r->>'id')::bigint from c1), array['00000000-0000-4000-8000-000000000001']::uuid[],
  '{}', array['00000000-0000-4000-8000-000000000002']::uuid[], array['00000000-0000-4000-8000-000000000007']::uuid[]);
select pg_temp.ok((select sent from public.mailings) = 1, 'sent 1');
select pg_temp.ok((select state || attempts from public.mailing_recipients where user_id = '00000000-0000-4000-8000-000000000007') = 'queued0', 'release telt niet als poging');
select pg_temp.ok((select state || attempts from public.mailing_recipients where user_id = '00000000-0000-4000-8000-000000000002') = 'queued1', 'retry: weer in de wachtrij');
-- nog een keer mark met 1 als verstuurd: telt niet dubbel (staat niet meer op sending)
select public.bingr_mailing_mark((select (r->>'id')::bigint from c1), array['00000000-0000-4000-8000-000000000001']::uuid[], '{}', '{}', '{}');
select pg_temp.ok((select sent from public.mailings) = 1, 'idempotent mark');
-- 1 wordt nooit opnieuw geclaimd
create temp table t4 as select public.bingr_mailing_take((select (r->>'id')::bigint from c1), 10) r;
select pg_temp.ok(not (select r->'items' from t4) @> '[{"id":"00000000-0000-4000-8000-000000000001"}]', 'verstuurd: nooit opnieuw');
select pg_temp.ok(jsonb_array_length((select r->'items' from t4)) = 2, 'de twee open ontvangers');
select pg_temp.ok(public.bingr_mailing_open((select (r->>'id')::bigint from c1)) = 2, 'open: 2');
select public.bingr_mailing_mark((select (r->>'id')::bigint from c1), array['00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000007']::uuid[], '{}', '{}', '{}');
create temp table t5 as select public.bingr_mailing_take((select (r->>'id')::bigint from c1), 10) r;
select pg_temp.ok((select r->>'done' from t5) = 'true', 'klaar');
select pg_temp.ok((select status from public.mailings) = 'done' and (select finished_at is not null from public.mailings), 'status done');
select pg_temp.ok((select sent || '/' || failed || '/' || skipped from public.mailings) = '3/0/1', 'tellers 3 verstuurd, 1 overgeslagen');
select pg_temp.ok(public.bingr_mailing_sent_last_hour() = 3, 'laatste uur: 3');

-- vastgelopen verzending (30 min op sending) -> failed, niet opnieuw; annuleren
create temp table c3 as select public.bingr_mailing_create('33333333-3333-4333-8333-333333333333', 'service', '{}') r;
select pg_temp.ok((select r->'recipients'->>'total' from c3) = '6', 'service: 6');
select public.bingr_mailing_take((select (r->>'id')::bigint from c3), 1);
update public.mailing_recipients set claimed_at = now() - interval '31 minutes' where mailing_id = (select (r->>'id')::bigint from c3) and state = 'sending';
select public.bingr_mailing_take((select (r->>'id')::bigint from c3), 1);
select pg_temp.ok((select failed from public.mailings where id = (select (r->>'id')::bigint from c3)) = 1, 'vastgelopen -> failed');
select pg_temp.ok(public.bingr_mailing_cancel((select (r->>'id')::bigint from c3)) ->> 'cancelled' = '4', 'annuleren: 4 uit de wachtrij');
select pg_temp.ok(public.bingr_mailing_cancel((select (r->>'id')::bigint from c3)) ->> 'error' = 'not_active', 'twee keer annuleren');
-- de lopende batch (1 op sending) maakt af; mark daarna: verstuurd, rest blijft geannuleerd
select public.bingr_mailing_mark((select (r->>'id')::bigint from c3),
  (select array_agg(user_id) from public.mailing_recipients where mailing_id = (select (r->>'id')::bigint from c3) and state = 'sending'), '{}', '{}', '{}');
select pg_temp.ok((select sent || '/' || failed || '/' || cancelled || '/' || status from public.mailings where id = (select (r->>'id')::bigint from c3)) = '1/1/4/cancelled', 'geannuleerd: 1/1/4');
select pg_temp.ok((select r->>'done' from (select public.bingr_mailing_take((select (r->>'id')::bigint from c3), 10) r) x) = 'true', 'geannuleerd: niets meer');
-- daarna mag een nieuwe mailing weer
select pg_temp.ok(public.bingr_mailing_create('44444444-4444-4444-8444-444444444444', 'newsletter', '{}') ->> 'error' is null, 'na annuleren weer vrij');
-- account verwijderen: ontvangersrij weg, tellers blijven
delete from auth.users where id = '00000000-0000-4000-8000-000000000002';
select pg_temp.ok((select sent from public.mailings where request_id = '11111111-1111-4111-8111-111111111111') = 3, 'tellers blijven');
-- geen adressen of namen in de tabellen van de mailing
select pg_temp.ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
  and table_name in ('mailings', 'mailing_recipients') and column_name ~ '(email|name|naam|address|adres|^ip)'), 'geen e-mail of naam');
-- RLS aan, niets voor anon/authenticated
select pg_temp.ok((select bool_and(relrowsecurity) from pg_class where relname in ('mailings', 'mailing_recipients')), 'RLS aan');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.mailings', 'select') and not has_table_privilege('anon', 'public.mailing_recipients', 'select'), 'geen rechten voor anon/authenticated');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_mailing_create(uuid, text, jsonb)', 'execute'), 'create alleen service role');
