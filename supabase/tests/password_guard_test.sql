-- Unittests van de inlogbescherming per account (hook Password Verification Attempt). Draait via password_guard_test.sh
-- in een tijdelijke database. Alleen testadressen (example.com).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
create function pg_temp.try(u uuid, valid boolean) returns jsonb language sql as $$
  select public.bingr_password_attempt(jsonb_build_object('user_id', u, 'valid', valid))
$$;
create function pg_temp.cont(r jsonb) returns boolean language sql as $$ select r = '{"decision":"continue"}'::jsonb $$;
create function pg_temp.locked(r jsonb) returns boolean language sql as $$
  select (r->'error'->>'http_code')::int = 429 and r->'error'->>'message' ~ '^Too many attempts\. Try again in [0-9]+ minutes?\.$'
$$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'pw-a@example.com'),
  ('00000000-0000-4000-8000-0000000000a2', 'pw-b@example.com');

-- rechten: alleen supabase_auth_admin mag de hook uitvoeren; niemand anders bij de tabel
select pg_temp.ok(has_function_privilege('supabase_auth_admin', 'public.bingr_password_attempt(jsonb)', 'execute'), 'auth mag de hook');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_password_attempt(jsonb)', 'execute'), 'anon niet');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_password_attempt(jsonb)', 'execute'), 'authenticated niet');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_password_attempt(jsonb)', 'execute'), 'service_role niet');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.auth_password_failures', 'select'), 'tabel dicht');
select pg_temp.ok((select relrowsecurity from pg_class where oid = 'public.auth_password_failures'::regclass), 'RLS aan');

-- goed wachtwoord zonder geschiedenis: door, geen rij
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a1', true)), 'goed = continue');
select pg_temp.ok(not exists (select 1 from public.auth_password_failures), 'geen rij na goed');
-- 4 fouten: door; goed daarna: teller weg
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)), 'fout 1') from generate_series(1, 4);
select pg_temp.ok((select failures from public.auth_password_failures where user_id = '00000000-0000-4000-8000-0000000000a1') = 4, '4 fouten geteld');
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a1', true)), 'goed na 4 fouten');
select pg_temp.ok(not exists (select 1 from public.auth_password_failures), 'teller weg na gelukt');
-- 5 fouten: de 5e geeft de blokkade van 15 minuten; daarna ook goed geweigerd; ander account niet geraakt
select pg_temp.try('00000000-0000-4000-8000-0000000000a1', false) from generate_series(1, 4);
select pg_temp.ok(pg_temp.locked(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)), '5e fout = dicht');
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000a1', true)->'error'->>'message' = 'Too many attempts. Try again in 15 minutes.', 'melding 15 minuten');
select pg_temp.ok(pg_temp.locked(pg_temp.try('00000000-0000-4000-8000-0000000000a1', true)), 'goed wachtwoord tijdens blokkade geweigerd');
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a2', true)), 'ander account niet geraakt');
-- 4 fouten in een venster dat al voorbij is tellen niet mee
select pg_temp.try('00000000-0000-4000-8000-0000000000a2', false) from generate_series(1, 4);
update public.auth_password_failures set window_start = now() - interval '16 minutes' where user_id = '00000000-0000-4000-8000-0000000000a2';
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a2', false)), 'oud venster telt niet');
select pg_temp.ok((select failures from public.auth_password_failures where user_id = '00000000-0000-4000-8000-0000000000a2') = 1, 'nieuw venster begint bij 1');
-- oplopend: blokkade verlopen, weer 5 fouten = 30 minuten, daarna 60, en niet langer
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.try('00000000-0000-4000-8000-0000000000a1', false) from generate_series(1, 4);
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)->'error'->>'message' = 'Too many attempts. Try again in 30 minutes.', 'tweede blokkade 30 minuten');
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.try('00000000-0000-4000-8000-0000000000a1', false) from generate_series(1, 4);
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)->'error'->>'message' = 'Too many attempts. Try again in 60 minutes.', 'derde blokkade 60 minuten');
update public.auth_password_failures set locked_until = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.try('00000000-0000-4000-8000-0000000000a1', false) from generate_series(1, 4);
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)->'error'->>'message' = 'Too many attempts. Try again in 60 minutes.', 'max. 60 minuten');
-- melding enkelvoud
select pg_temp.ok(public.bingr_password_lock_message(now() + interval '30 seconds')->'error'->>'message' = 'Too many attempts. Try again in 1 minute.', '1 minuut');
-- na een dag zonder blokkade: alles opnieuw (ook het niveau)
update public.auth_password_failures set locked_until = now() - interval '1 hour', updated_at = now() - interval '25 hours' where user_id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.ok(pg_temp.cont(pg_temp.try('00000000-0000-4000-8000-0000000000a1', false)), 'na een dag weer door');
select pg_temp.ok((select lock_level from public.auth_password_failures where user_id = '00000000-0000-4000-8000-0000000000a1') = 0, 'niveau terug op 0');
-- kapotte of lege invoer: nooit tegenhouden
select pg_temp.ok(pg_temp.cont(public.bingr_password_attempt('{}'::jsonb)), 'leeg event');
select pg_temp.ok(pg_temp.cont(public.bingr_password_attempt('{"user_id":"geen-uuid","valid":false}'::jsonb)), 'ongeldig user_id');
select pg_temp.ok(pg_temp.cont(public.bingr_password_attempt('{"user_id":"00000000-0000-4000-8000-0000000000ff","valid":false}'::jsonb)), 'onbekend account (foreign key) = door');
-- opruimen na 1 dag; lopende blokkade blijft
update public.auth_password_failures set updated_at = now() - interval '2 days';
update public.auth_password_failures set locked_until = now() + interval '10 minutes' where user_id = '00000000-0000-4000-8000-0000000000a2';
select pg_temp.ok(public.bingr_password_failures_cleanup() = 1, 'oude rij opgeruimd');
select pg_temp.ok((select count(*) from public.auth_password_failures) = 1, 'lopende blokkade blijft');
-- account weg = teller weg
delete from auth.users where id = '00000000-0000-4000-8000-0000000000a2';
select pg_temp.ok(not exists (select 1 from public.auth_password_failures), 'cascade bij verwijderen');
