-- Unittests van de registratiebescherming (build 134). Draait via signup_guard_test.sh in een tijdelijke database.
-- Alleen testadressen (example.*, documentatie-IP's 192.0.2.x / 198.51.100.x / 2001:db8::).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
-- event zoals Supabase Auth het stuurt (Before User Created)
create function pg_temp.ev(ip text, email text, meta jsonb default '{}'::jsonb, provider text default 'email') returns jsonb
language sql as $$
  select jsonb_build_object(
    'metadata', jsonb_build_object('uuid', gen_random_uuid(), 'time', now(), 'name', 'before-user-created', 'ip_address', ip),
    'user', jsonb_build_object('id', gen_random_uuid(), 'aud', 'authenticated', 'role', '', 'email', email, 'phone', '',
      'app_metadata', jsonb_build_object('provider', provider, 'providers', jsonb_build_array(provider)),
      'user_metadata', meta, 'identities', '[]'::jsonb, 'is_anonymous', false))
$$;
create function pg_temp.code(r jsonb) returns int language sql as $$ select (r->'error'->>'http_code')::int $$;

-- naamregel
select pg_temp.ok(not public.bingr_person_name_invalid('Anna'), 'gewone naam');
select pg_temp.ok(not public.bingr_person_name_invalid('van der Linden'), 'naam met spaties');
select pg_temp.ok(not public.bingr_person_name_invalid(null), 'geen naam');
select pg_temp.ok(public.bingr_person_name_invalid('www.spam.example'), 'www.');
select pg_temp.ok(public.bingr_person_name_invalid('https://x.example'), '://');
select pg_temp.ok(public.bingr_person_name_invalid('a@b.example'), '@');
select pg_temp.ok(public.bingr_person_name_invalid('<b>x</b>'), 'HTML');
select pg_temp.ok(public.bingr_person_name_invalid(repeat('a', 51)), 'langer dan 50');
select pg_temp.ok(not public.bingr_person_name_invalid(repeat('a', 50)), 'precies 50');

-- trigger bingr_user_names (build 136): opschonen, en weigeren met SQLSTATE PT400 (Supabase Auth: HTTP 400) i.p.v. 22023 (500)
create function pg_temp.name_err(q text) returns text language plpgsql as $$
declare st text; dt text; hn text;
begin
  execute q;
  return 'geen fout';
exception when others then
  get stacked diagnostics st = returned_sqlstate, dt = pg_exception_detail, hn = pg_exception_hint;
  return st || '/' || coalesce(dt, '') || '/' || coalesce(hn, '');
end $$;
insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-4000-8000-000000000136', 'naam@example.com', '{"lang":"nl","first_name":"  Ci \t Test ","last_name":" van  der Bingr "}');
select pg_temp.ok((select raw_user_meta_data->>'first_name' = 'Ci Test' and raw_user_meta_data->>'last_name' = 'van der Bingr'
  from auth.users where id = '00000000-0000-4000-8000-000000000136'), 'naam opgeschoond bij aanmaken');
select pg_temp.ok(pg_temp.name_err($q$update auth.users set raw_user_meta_data = raw_user_meta_data || '{"first_name":"<b>x</b>"}'
  where id = '00000000-0000-4000-8000-000000000136'$q$) = 'PT400/first_name/bingr_invalid_name', 'HTML bij wijzigen: PT400');
select pg_temp.ok(pg_temp.name_err($q$update auth.users set raw_user_meta_data = raw_user_meta_data || '{"last_name":"a@b.example"}'
  where id = '00000000-0000-4000-8000-000000000136'$q$) = 'PT400/last_name/bingr_invalid_name', 'e-mailadres bij wijzigen: PT400');
select pg_temp.ok(pg_temp.name_err($q$update auth.users set raw_user_meta_data = raw_user_meta_data || '{"first_name":42}'
  where id = '00000000-0000-4000-8000-000000000136'$q$) = 'PT400/first_name/bingr_invalid_name', 'geen tekst: PT400');
select pg_temp.ok(pg_temp.name_err($q$insert into auth.users (email, raw_user_meta_data) values ('x@example.com', '{"first_name":"www.spam.example"}')$q$)
  = 'PT400/first_name/bingr_invalid_name', 'link bij aanmaken: PT400');
select pg_temp.ok((select raw_user_meta_data->>'first_name' = 'Ci Test' from auth.users where id = '00000000-0000-4000-8000-000000000136'),
  'geweigerde naam: oude naam blijft');
update auth.users set raw_user_meta_data = raw_user_meta_data || '{"first_name":" Anna ","last_name":null}'
  where id = '00000000-0000-4000-8000-000000000136';
select pg_temp.ok((select raw_user_meta_data->>'first_name' = 'Anna' and not raw_user_meta_data ? 'last_name' and raw_user_meta_data->>'lang' = 'nl'
  from auth.users where id = '00000000-0000-4000-8000-000000000136'), 'naam wijzigen: opgeschoond, null = weg, lang blijft');
delete from auth.users where id = '00000000-0000-4000-8000-000000000136';

-- netwerk en hash
select pg_temp.ok(public.bingr_signup_ip_key('192.0.2.10') = '192.0.2.10', 'IPv4');
select pg_temp.ok(public.bingr_signup_ip_key(' ::ffff:192.0.2.10 ') = '192.0.2.10', 'IPv4 in IPv6');
select pg_temp.ok(public.bingr_signup_ip_key('2001:db8:1:2:3:4:5:6') = public.bingr_signup_ip_key('2001:DB8:1:2:ffff::1'), 'IPv6 per /64');
select pg_temp.ok(public.bingr_signup_ip_key('2001:db8:1:2::1') <> public.bingr_signup_ip_key('2001:db8:1:3::1'), 'ander /64');
select pg_temp.ok(public.bingr_signup_ip_key('geen-ip') = 'geen-ip', 'onleesbaar IP');
select pg_temp.ok(public.bingr_signup_ip_hash('192.0.2.10') ~ '^[0-9a-f]{64}$', 'hash = sha256-hex');
select pg_temp.ok(public.bingr_signup_ip_hash('192.0.2.10') = public.bingr_signup_ip_hash('::ffff:192.0.2.10'), 'zelfde netwerk, zelfde hash');
select pg_temp.ok(public.bingr_signup_ip_hash('192.0.2.10') <> public.bingr_signup_ip_hash('192.0.2.11'), 'ander adres, andere hash');
select pg_temp.ok(public.bingr_signup_ip_hash('192.0.2.10') <> encode(sha256(convert_to('192.0.2.10', 'UTF8')), 'hex'), 'hash met salt');
select pg_temp.ok((select count(*) from public.signup_guard_secret) = 1, 'één salt');

-- wegwerpdomeinen
insert into public.disposable_domains (domain, source) values ('wegwerp.example', 'list');
select pg_temp.ok(public.bingr_email_disposable('a@mailinator.com'), 'eigen lijst');
select pg_temp.ok(public.bingr_email_disposable('a@X.Mailinator.COM'), 'subdomein, hoofdletters');
select pg_temp.ok(public.bingr_email_disposable('a@mailinator.com.'), 'punt aan het eind');
select pg_temp.ok(public.bingr_email_disposable('a@wegwerp.example'), 'uit de lijst');
select pg_temp.ok(not public.bingr_email_disposable('a@notmailinator.com'), 'geen achtervoegsel zonder punt');
select pg_temp.ok(not public.bingr_email_disposable('a@gmail.com'), 'gewoon adres');
select pg_temp.ok(not public.bingr_email_disposable('a@com'), 'alleen tld');
select pg_temp.ok(not public.bingr_email_disposable(''), 'leeg');
select pg_temp.ok(not public.bingr_email_disposable(null), 'null');
select pg_temp.ok(not public.bingr_email_disposable('geen-at'), 'zonder @');

-- hook: toestaan en limiet per uur (3)
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a1@example.com', '{"first_name":"Anna","last_name":"Bingr","lang":"nl"}')) = '{}'::jsonb, '1e toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a2@example.com')) = '{}'::jsonb, '2e toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a3@example.com')) = '{}'::jsonb, '3e toegestaan');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a4@example.com'))) = 429, '4e binnen een uur geweigerd (429)');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a4@example.com'))->'error'->>'message' like 'Too many%', 'melding begint met Too many');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.2', 'b1@example.com')) = '{}'::jsonb, 'ander IP toegestaan');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.1')) = 5, 'pogingen geteld');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.1') and not allowed and reason = 'rate_limit') = 2, 'geweigerd met reden');
-- na een uur weer toegestaan (pogingen een uur terugzetten)
update public.signup_attempts set at = now() - interval '61 minutes' where ip_hash = public.bingr_signup_ip_hash('192.0.2.1');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'a5@example.com')) = '{}'::jsonb, 'na een uur weer toegestaan');

-- limiet per 24 uur (10), en geweigerde pogingen tellen niet mee
insert into public.signup_attempts (ip_hash, at, allowed, reason)
select public.bingr_signup_ip_hash('198.51.100.7'), now() - interval '5 hours', true, null from generate_series(1, 10);
insert into public.signup_attempts (ip_hash, at, allowed, reason)
select public.bingr_signup_ip_hash('198.51.100.8'), now() - interval '5 minutes', false, 'disposable' from generate_series(1, 20);
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('198.51.100.7', 'c@example.com'))) = 429, '11e in 24 uur geweigerd');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('198.51.100.8', 'd@example.com')) = '{}'::jsonb, 'geweigerde pogingen tellen niet');
-- IPv6: hele /64 telt samen
select public.bingr_before_user_created(pg_temp.ev('2001:db8:aa:bb::' || i, 'v6-' || i || '@example.com')) from generate_series(1, 3) i;
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('2001:db8:aa:bb:1234::9', 'v6x@example.com'))) = 429, 'IPv6 /64 samen');

-- instelbare limieten (app_settings.signup_limits)
update public.app_settings set value = '{"per_hour": 1, "per_day": 10}' where key = 'signup_limits';
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.30', 'e1@example.com')) = '{}'::jsonb, 'per_hour 1: 1e');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.30', 'e2@example.com'))) = 429, 'per_hour 1: 2e geweigerd');
update public.app_settings set value = '{"per_hour": "x"}' where key = 'signup_limits';
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.31', 'f@example.com')) = '{}'::jsonb, 'ongeldige instelling: standaard');
update public.app_settings set value = '{"per_hour": 3, "per_day": 10}' where key = 'signup_limits';

-- naam
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.40', 'g1@example.com', '{"first_name":"www.spam.example","last_name":"x"}'))) = 400, 'naam met link');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.40', 'g2@example.com', '{"first_name":"Anna","last_name":"<b>x</b>"}'))) = 400, 'achternaam met HTML');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.40', 'g3@example.com', '{"first_name":123}'))) = 400, 'naam geen tekst');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.40', 'g4@example.com', '{"first_name":null,"other":"www.x"}')) = '{}'::jsonb, 'null-naam en andere velden ok');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.40', 'g5@example.com', 'null'::jsonb)) = '{}'::jsonb, 'geen user_metadata');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.40') and reason = 'name') = 3, 'reden name');

-- wegwerp
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.50', 'h@mailinator.com'))) = 400, 'wegwerpadres');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.50', 'h@in.wegwerp.example'))) = 400, 'wegwerp-subdomein');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.50') and reason = 'disposable') = 2, 'reden disposable');

-- honeypot en tijdmeting van de webformulieren (build 138): hp gevuld of fill_ms < 1500 = 400 met een neutrale melding;
-- ontbreken (apps) of leeg/null = toestaan
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.80', 'k1@example.com', '{"first_name":"Anna","hp":"https://spam.example","fill_ms":9000}'))) = 400, 'honeypot gevuld');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.80', 'k1@example.com', '{"hp":"x"}'))->'error'->>'message' = 'Something went wrong. Please try again.', 'honeypot: neutrale melding');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.80', 'k2@example.com', '{"hp":1}'))) = 400, 'honeypot: geen tekst');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.80', 'k3@example.com', '{"hp":"x","fill_ms":100}'))) = 400, 'honeypot en te snel: honeypot');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.80') and reason = 'honeypot' and not allowed) = 4, 'reden honeypot');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.81', 'k4@example.com', '{"first_name":"Anna","fill_ms":1499}'))) = 400, 'te snel (1499 ms)');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.81', 'k5@example.com', '{"fill_ms":0}'))->'error'->>'message' = 'Something went wrong. Please try again.', 'te snel: neutrale melding');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.81', 'k6@example.com', '{"fill_ms":-5}'))) = 400, 'te snel: negatief');
select pg_temp.ok(pg_temp.code(public.bingr_before_user_created(pg_temp.ev('192.0.2.81', 'k7@example.com', '{"fill_ms":" 300 "}'))) = 400, 'te snel: als tekst');
select pg_temp.ok((select count(*) from public.signup_attempts where ip_hash = public.bingr_signup_ip_hash('192.0.2.81') and reason = 'too_fast' and not allowed) = 4, 'reden too_fast');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.82', 'k8@example.com', '{"first_name":"Anna","fill_ms":1500}')) = '{}'::jsonb, '1500 ms toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.82', 'k9@example.com', '{"hp":"","fill_ms":8123.5}')) = '{}'::jsonb, 'leeg veld en traag toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.83', 'k10@example.com', '{"hp":"  ","fill_ms":"abc"}')) = '{}'::jsonb, 'spaties en onleesbare tijd toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.83', 'k11@example.com', '{"hp":null,"fill_ms":null}')) = '{}'::jsonb, 'null toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.83', 'k12@example.com', '{"first_name":"Anna","last_name":"Bingr","lang":"en"}')) = '{}'::jsonb, 'zonder hp/fill_ms (apps) toegestaan');
-- geweigerde bots tellen niet mee voor de limiet: na 4 honeypots nog 3 aanmeldingen vanaf dat netwerk
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.80', 'k13@example.com', '{"fill_ms":5000}')) = '{}'::jsonb, 'na honeypots: mens toegestaan');
-- hp en fill_ms worden niet bewaard (trigger bingr_user_names), de rest wel
insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-4000-8000-000000000138', 'hp@example.com', '{"lang":"nl","first_name":"Anna","hp":"","fill_ms":4321}');
select pg_temp.ok((select not raw_user_meta_data ? 'hp' and not raw_user_meta_data ? 'fill_ms' and raw_user_meta_data->>'first_name' = 'Anna'
  and raw_user_meta_data->>'lang' = 'nl' from auth.users where id = '00000000-0000-4000-8000-000000000138'), 'hp en fill_ms niet opgeslagen');
update auth.users set raw_user_meta_data = raw_user_meta_data || '{"fill_ms":1}' where id = '00000000-0000-4000-8000-000000000138';
select pg_temp.ok((select not raw_user_meta_data ? 'fill_ms' from auth.users where id = '00000000-0000-4000-8000-000000000138'), 'ook niet bij wijzigen');
delete from auth.users where id = '00000000-0000-4000-8000-000000000138';
-- de check op signup_attempts kent de nieuwe redenen, en niets anders
select pg_temp.ok(pg_temp.name_err($q$insert into public.signup_attempts (ip_hash, allowed, reason) values (repeat('a', 64), false, 'iets')$q$) like '23514/%', 'onbekende reden geweigerd');

-- meldingen: de apps herkennen geen andere fout in de tekst (already, banned, password, confirm)
select pg_temp.ok(not exists (
  select 1 from (values (public.bingr_before_user_created(pg_temp.ev('198.51.100.7', 'z@example.com'))),
                        (public.bingr_before_user_created(pg_temp.ev('192.0.2.60', 'z@mailinator.com'))),
                        (public.bingr_before_user_created(pg_temp.ev('192.0.2.61', 'z@example.com', '{"first_name":"a@b"}'))),
                        (public.bingr_before_user_created(pg_temp.ev('192.0.2.62', 'z@example.com', '{"hp":"x"}'))),
                        (public.bingr_before_user_created(pg_temp.ev('192.0.2.63', 'z@example.com', '{"fill_ms":10}')))) v(r)
  where r->'error'->>'message' is null or lower(r->'error'->>'message') ~ '(already|banned|password|confirm|invalid login)'), 'neutrale meldingen');

-- niet blokkeren: zonder IP (admin), andere provider, anoniem; niets opgeslagen
select count(*) as before_n from public.signup_attempts \gset
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev(null, 'adm@mailinator.com')) = '{}'::jsonb, 'zonder IP toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('', 'adm@mailinator.com')) = '{}'::jsonb, 'leeg IP toegestaan');
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.1', 'o@mailinator.com', '{}', 'google')) = '{}'::jsonb, 'andere provider');
select pg_temp.ok(public.bingr_before_user_created(jsonb_set(pg_temp.ev('192.0.2.1', 'x@mailinator.com'), '{user,is_anonymous}', 'true')) = '{}'::jsonb, 'anoniem');
select pg_temp.ok(public.bingr_before_user_created('{}'::jsonb) = '{}'::jsonb, 'leeg event');
select pg_temp.ok((select count(*) from public.signup_attempts) = :before_n, 'niets opgeslagen');

-- storing in de hook: toestaan
begin;
alter table public.signup_attempts rename to signup_attempts_weg;
select pg_temp.ok(public.bingr_before_user_created(pg_temp.ev('192.0.2.70', 'q@mailinator.com')) = '{}'::jsonb, 'fout in de hook = toestaan');
rollback;

-- rechten
select pg_temp.ok(has_function_privilege('supabase_auth_admin', 'public.bingr_before_user_created(jsonb)', 'execute'), 'auth mag de hook aanroepen');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_before_user_created(jsonb)', 'execute'), 'anon niet');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_before_user_created(jsonb)', 'execute'), 'authenticated niet');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_before_user_created(jsonb)', 'execute'), 'service_role niet');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_signup_cleanup(uuid)', 'execute'), 'opruimen alleen intern');
select pg_temp.ok(has_function_privilege('service_role', 'public.bingr_admin_signup_guard()', 'execute'), 'beheer mag tellingen lezen');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_admin_signup_guard()', 'execute'), 'anon geen tellingen');
select pg_temp.ok(not has_table_privilege('service_role', 'public.signup_guard_secret', 'select'), 'salt niet leesbaar');

-- onbevestigde accounts opruimen
insert into auth.users (id, email, created_at, email_confirmed_at, last_sign_in_at) values
  ('00000000-0000-0000-0000-000000000001', 'oud@example.com', now() - interval '49 hours', null, null),
  ('00000000-0000-0000-0000-000000000002', 'bevestigd@example.com', now() - interval '49 hours', now(), null),
  ('00000000-0000-0000-0000-000000000003', 'nieuw@example.com', now() - interval '47 hours', null, null),
  ('00000000-0000-0000-0000-000000000004', 'plan@example.com', now() - interval '49 hours', null, null),
  ('00000000-0000-0000-0000-000000000005', 'apparaat@example.com', now() - interval '49 hours', null, null),
  ('00000000-0000-0000-0000-000000000006', 'ingelogd@example.com', now() - interval '49 hours', null, now()),
  ('00000000-0000-0000-0000-000000000007', 'ticket@example.com', now() - interval '49 hours', null, null),
  ('00000000-0000-0000-0000-000000000008', 'oud2@example.com', now() - interval '72 hours', null, null);
insert into public.account_plans (user_id, plan) values ('00000000-0000-0000-0000-000000000004', 'lifetime');
insert into public.account_devices (user_id) values ('00000000-0000-0000-0000-000000000005');
insert into public.support_tickets (user_id) values ('00000000-0000-0000-0000-000000000007');
select pg_temp.ok(public.bingr_signup_cleanup('00000000-0000-0000-0000-000000000008') = '{"deleted": 1}'::jsonb, 'p_only: alleen dat account');
select pg_temp.ok((select count(*) from public.signup_cleanups) = 0, 'p_only telt niet mee');
select pg_temp.ok(public.bingr_signup_cleanup() = '{"deleted": 1}'::jsonb, 'één onbevestigd account verwijderd');
select pg_temp.ok(not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-000000000001'), 'oud onbevestigd weg');
select pg_temp.ok((select count(*) from auth.users) = 6, 'de rest blijft');
select pg_temp.ok((select sum(deleted) from public.signup_cleanups) = 1, 'aantal bewaard');
select pg_temp.ok(public.bingr_signup_cleanup() = '{"deleted": 0}'::jsonb, 'tweede ronde: niets');
select pg_temp.ok((select count(*) from public.signup_cleanups) = 1, 'geen rij bij 0');

-- beheer-tellingen
select pg_temp.ok((public.bingr_admin_signup_guard()->'rejected_24h'->>'rate_limit')::int >= 4, 'tellingen rate_limit');
select pg_temp.ok((public.bingr_admin_signup_guard()->'rejected_24h'->>'name')::int >= 3, 'tellingen name');
select pg_temp.ok((public.bingr_admin_signup_guard()->'rejected_7d'->>'disposable')::int >= 22, 'tellingen disposable');
select pg_temp.ok((public.bingr_admin_signup_guard()->>'unconfirmed_deleted_24h')::int = 1, 'tellingen verwijderd');
select pg_temp.ok((public.bingr_admin_signup_guard()->>'disposable_domains')::int >= 16, 'aantal wegwerpdomeinen');
select pg_temp.ok((public.bingr_admin_signup_guard()->'rejected_24h'->>'honeypot')::int >= 5, 'tellingen honeypot');
select pg_temp.ok((public.bingr_admin_signup_guard()->'rejected_7d'->>'too_fast')::int >= 5, 'tellingen too_fast');
select pg_temp.ok(public.bingr_admin_signup_guard()::text !~ '[0-9a-f]{64}', 'geen hashes in de tellingen');

-- pogingen na 7 dagen weg
insert into public.signup_attempts (ip_hash, at, allowed) values (public.bingr_signup_ip_hash('192.0.2.99'), now() - interval '8 days', true);
select pg_temp.ok(public.bingr_signup_attempts_cleanup() = 1, 'oude poging opgeruimd');
select pg_temp.ok(public.bingr_signup_attempts_cleanup() = 0, 'niets meer op te ruimen');
