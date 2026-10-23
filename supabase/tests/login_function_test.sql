-- Unittests van inloggen via de functie login (build 141): limieten per IP en e-mail, blokkade per account (oplopend),
-- tickets (enkel gebruik, < 60 s), de Custom Access Token hook en de schakelaar. Draait via login_function_test.sh in een
-- tijdelijke database. Alleen testadressen (example.com) en test-IP's (documentatiebereik).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
create function pg_temp.ev(u uuid, m text, app jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('user_id', u, 'authentication_method', m,
    'claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1', 'app_metadata', app))
$$;
create function pg_temp.hook(u uuid, m text, app jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select public.bingr_access_token_hook(pg_temp.ev(u, m, app))
$$;
create function pg_temp.passes(r jsonb, u uuid) returns boolean language sql as $$
  select r ? 'claims' and not r ? 'error' and r->'claims'->>'sub' = u::text
$$;
create function pg_temp.refused(r jsonb) returns boolean language sql as $$
  select (r->'error'->>'http_code')::int = 403 and not r ? 'claims'
$$;
create function pg_temp.tickets(u uuid) returns int language sql as $$
  select count(*)::int from public.login_tickets where user_id = u
$$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000b1', 'login-a@example.com'),
  ('00000000-0000-4000-8000-0000000000b2', 'login-b@example.com'),
  ('00000000-0000-4000-8000-0000000000b3', 'login-c@example.com');

-- rechten: begin/ticket/finish alleen service_role, de hook alleen supabase_auth_admin; tabellen dicht, RLS aan
select pg_temp.ok(has_function_privilege('service_role', 'public.bingr_login_begin(text, text, int, int, int, int)', 'execute'), 'service_role mag begin');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_login_begin(text, text, int, int, int, int)', 'execute'), 'anon geen begin');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_login_finish(uuid, text)', 'execute'), 'authenticated geen finish');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_login_ticket(uuid)', 'execute'), 'anon geen ticket');
select pg_temp.ok(has_function_privilege('supabase_auth_admin', 'public.bingr_access_token_hook(jsonb)', 'execute'), 'auth mag de hook');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_access_token_hook(jsonb)', 'execute'), 'service_role geen hook');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_access_token_hook(jsonb)', 'execute'), 'authenticated geen hook');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.login_tickets', 'select'), 'tickets dicht');
select pg_temp.ok(not has_table_privilege('service_role', 'public.login_guard_secret', 'select'), 'salt dicht');
select pg_temp.ok((select relrowsecurity from pg_class where oid = 'public.login_tickets'::regclass), 'RLS tickets');
select pg_temp.ok((select relrowsecurity from pg_class where oid = 'public.login_guard_secret'::regclass), 'RLS salt');
-- schakelaar standaard uit, en een herhaald schema zet hem niet terug
select pg_temp.ok((select value from public.app_settings where key = 'login_via_function_required') = 'false'::jsonb, 'schakelaar standaard uit');

-- begin: bekend adres (hoofdletters/spaties maken niet uit) -> continue met user_id en één ticket; onbekend -> geen user_id
select pg_temp.ok(public.bingr_login_begin('  Login-A@Example.com ', '192.0.2.1') = jsonb_build_object('status', 'continue', 'user_id', '00000000-0000-4000-8000-0000000000b1'), 'begin bekend adres');
select pg_temp.ok(pg_temp.tickets('00000000-0000-4000-8000-0000000000b1') = 1, 'ticket gezet');
select pg_temp.ok(public.bingr_login_begin('nobody@example.com', '192.0.2.1') = '{"status":"continue"}'::jsonb, 'onbekend adres: geen user_id');
-- geen IP's of adressen in rate_limits: alleen hashes
select pg_temp.ok(not exists (select 1 from public.rate_limits where key like '%192.0.2%' or key like '%example%'), 'alleen hashes in rate_limits');
select pg_temp.ok((select count(*) from public.rate_limits where key ~ '^login:(ip|e):[0-9a-f]{64}$') = 3, 'drie tellers (1 IP, 2 adressen)');

-- hook met schakelaar uit: alles door, ook zonder ticket; claims ongewijzigd
delete from public.login_tickets;
select pg_temp.ok(pg_temp.hook('00000000-0000-4000-8000-0000000000b1', 'password') = jsonb_build_object('claims', pg_temp.ev('00000000-0000-4000-8000-0000000000b1', 'password')->'claims'), 'uit: claims ongewijzigd');
-- testmodus per account (app_metadata): zonder ticket geweigerd, met ticket één keer door
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b1', 'password', '{"bingr_login_ticket_required": true}')), 'testmodus: zonder ticket geweigerd');
select pg_temp.ok(public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b1'), 'ticket los gezet');
select pg_temp.ok(pg_temp.passes(pg_temp.hook('00000000-0000-4000-8000-0000000000b1', 'password', '{"bingr_login_ticket_required": true}'), '00000000-0000-4000-8000-0000000000b1'), 'testmodus: met ticket door');
select pg_temp.ok(pg_temp.tickets('00000000-0000-4000-8000-0000000000b1') = 0, 'ticket verbruikt');
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b1', 'password', '{"bingr_login_ticket_required": true}')), 'ticket maar één keer');

-- schakelaar aan
update public.app_settings set value = 'true'::jsonb where key = 'login_via_function_required';
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password')), 'aan: password zonder ticket geweigerd');
-- andere routes blijven werken zonder ticket
select pg_temp.ok(pg_temp.passes(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', m), '00000000-0000-4000-8000-0000000000b2'), 'aan: ' || m || ' door')
from unnest(array['token_refresh', 'magiclink', 'otp', 'recovery', 'invite', 'email/signup', 'email_change', 'oauth', 'anonymous']) m;
select pg_temp.ok(pg_temp.passes(public.bingr_access_token_hook(jsonb_build_object('user_id', '00000000-0000-4000-8000-0000000000b2', 'claims', jsonb_build_object('sub', '00000000-0000-4000-8000-0000000000b2'))), '00000000-0000-4000-8000-0000000000b2'), 'aan: zonder methode door');
-- ticket van een ander account telt niet
select public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b1');
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password')), 'ticket van ander account telt niet');
-- verlopen ticket (> 60 s) telt niet
select public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b2');
update public.login_tickets set created_at = now() - interval '61 seconds' where user_id = '00000000-0000-4000-8000-0000000000b2';
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password')), 'verlopen ticket geweigerd');
-- vers ticket via begin: door, daarna weer dicht
select public.bingr_login_begin('login-b@example.com', '192.0.2.2');
select pg_temp.ok(pg_temp.passes(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password'), '00000000-0000-4000-8000-0000000000b2'), 'aan: met ticket door');
select pg_temp.ok(pg_temp.refused(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password')), 'aan: tweede keer geweigerd');
-- kapotte invoer houdt niemand tegen (fail open), kapotte schakelaar ook niet
select pg_temp.ok(pg_temp.passes(public.bingr_access_token_hook(jsonb_build_object('user_id', 'geen-uuid', 'authentication_method', 'password', 'claims', jsonb_build_object('sub', '00000000-0000-4000-8000-0000000000b2'))), '00000000-0000-4000-8000-0000000000b2'), 'kapotte user_id: door');
update public.app_settings set value = '"misschien"'::jsonb where key = 'login_via_function_required';
select pg_temp.ok(pg_temp.passes(pg_temp.hook('00000000-0000-4000-8000-0000000000b2', 'password'), '00000000-0000-4000-8000-0000000000b2'), 'kapotte schakelaar: door');
update public.app_settings set value = 'false'::jsonb where key = 'login_via_function_required';

-- finish: 4x fout = ok, 5e fout = dicht 15 min; begin geeft dan locked (ook met goed wachtwoord); tickets weg
select pg_temp.ok(public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong') = '{"status":"ok"}'::jsonb, 'fout 1-4') from generate_series(1, 4);
select public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b3');
select pg_temp.ok(public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong')->>'status' = 'locked', '5e fout = dicht');
select pg_temp.ok(pg_temp.tickets('00000000-0000-4000-8000-0000000000b3') = 0, 'finish ruimt tickets op');
select pg_temp.ok((public.bingr_login_begin('login-c@example.com', '192.0.2.3')->>'retry_after')::int between 890 and 900, 'begin: locked, ~15 min');
select pg_temp.ok(public.bingr_login_begin('login-c@example.com', '192.0.2.3')->>'status' = 'locked', 'begin: locked');
select pg_temp.ok(pg_temp.tickets('00000000-0000-4000-8000-0000000000b3') = 0, 'geen ticket als account dicht');
select pg_temp.ok(not public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b3'), 'geen los ticket als account dicht');
-- oplopend: 30, daarna 60 en niet langer
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000b3';
select public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong') from generate_series(1, 4);
select pg_temp.ok((public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong')->>'retry_after')::int between 1790 and 1800, 'tweede blokkade 30 min');
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000b3';
select public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong') from generate_series(1, 4);
select pg_temp.ok((public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong')->>'retry_after')::int between 3590 and 3600, 'derde blokkade 60 min');
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000b3';
select public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong') from generate_series(1, 4);
select pg_temp.ok((public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong')->>'retry_after')::int between 3590 and 3600, 'max. 60 min');
-- gelukt = teller weg; 'other' (bv. email_not_confirmed, storing) telt niet
update public.auth_password_failures set locked_until = null where user_id = '00000000-0000-4000-8000-0000000000b3';
select public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'wrong');
select pg_temp.ok(public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'other') = '{"status":"ok"}'::jsonb, 'other telt niet');
select pg_temp.ok((select failures from public.auth_password_failures where user_id = '00000000-0000-4000-8000-0000000000b3') = 1, 'other niet geteld');
select pg_temp.ok(public.bingr_login_finish('00000000-0000-4000-8000-0000000000b3', 'ok') = '{"status":"ok"}'::jsonb, 'gelukt');
select pg_temp.ok(not exists (select 1 from public.auth_password_failures where user_id = '00000000-0000-4000-8000-0000000000b3'), 'teller weg na gelukt');
select pg_temp.ok(public.bingr_login_finish(null, 'wrong') = '{"status":"ok"}'::jsonb, 'onbekend account: niets');

-- limiet per e-mailadres: 10 per 15 min, daarna rate met retry_after; ander adres niet geraakt
delete from public.rate_limits;
select public.bingr_login_begin('login-a@example.com', '192.0.2.' || i) from generate_series(10, 19) i;
select pg_temp.ok(public.bingr_login_begin('login-a@example.com', '192.0.2.20')->>'status' = 'rate', '11e poging op een adres = rate');
select pg_temp.ok((public.bingr_login_begin('LOGIN-A@example.com', '192.0.2.21')->>'retry_after')::int between 1 and 900, 'retry_after binnen het venster');
select pg_temp.ok(public.bingr_login_begin('login-b@example.com', '192.0.2.22')->>'status' = 'continue', 'ander adres niet geraakt');
-- limiet per IP: 30 per 10 min
delete from public.rate_limits;
select public.bingr_login_begin('ip-' || i || '@example.com', '198.51.100.7') from generate_series(1, 30) i;
select pg_temp.ok(public.bingr_login_begin('ip-31@example.com', '198.51.100.7')->>'status' = 'rate', '31e poging vanaf een IP = rate');
select pg_temp.ok(public.bingr_login_begin('ip-31@example.com', '198.51.100.8')->>'status' = 'continue', 'ander IP niet geraakt');
-- oude tickets worden bij begin opgeruimd
insert into public.login_tickets (user_id, created_at) values ('00000000-0000-4000-8000-0000000000b1', now() - interval '6 minutes');
select public.bingr_login_begin('nobody@example.com', '198.51.100.9');
select pg_temp.ok(not exists (select 1 from public.login_tickets where created_at < now() - interval '5 minutes'), 'oude tickets weg');
-- account weg = tickets weg
select public.bingr_login_ticket('00000000-0000-4000-8000-0000000000b2');
delete from auth.users where id = '00000000-0000-4000-8000-0000000000b2';
select pg_temp.ok(pg_temp.tickets('00000000-0000-4000-8000-0000000000b2') = 0, 'cascade');
