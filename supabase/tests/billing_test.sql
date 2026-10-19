-- Unittests van de bewaarplicht van aankopen. Draait via billing_test.sh in een tijdelijke database. Alleen testadressen.
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
-- migratie: user_id mag leeg, één foreign key met on delete set null, oude rij nog daar
select pg_temp.ok((select attnotnull from pg_attribute where attrelid = 'public.billing_purchases'::regclass and attname = 'user_id') = false, 'user_id nullable');
select pg_temp.ok((select count(*) from pg_constraint where conrelid = 'public.billing_purchases'::regclass and contype = 'f'
                    and confrelid = 'auth.users'::regclass) = 1, 'één foreign key naar auth.users');
select pg_temp.ok((select confdeltype from pg_constraint where conrelid = 'public.billing_purchases'::regclass and contype = 'f'
                    and confrelid = 'auth.users'::regclass) = 'n', 'on delete set null');
select pg_temp.ok((select count(*) from public.billing_purchases) = 1, 'bestaande aankoop blijft bij de migratie');
-- geen persoonsgegevens in de kolommen
select pg_temp.ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
                   and table_name in ('billing_purchases', 'billing_refunds', 'billing_events')
                   and column_name ~ '(mail|name|naam|address|adres|phone|telefoon|receipt|invoice|ip_|card|iban)'), 'geen e-mail, naam, adres, kaart of kwitantie-URL');

-- twee accounts met aankopen, A ook met een terugbetaling
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000000b', 'b@example.invalid');
insert into public.billing_purchases (user_id, stripe_session_id, payment_intent, amount, status, paid_at, tax_amount, payment_method, country, fee)
values ('00000000-0000-4000-8000-00000000000a', 'cs_live_a', 'pi_a', 499, 'paid', now() - interval '1 day', 87, 'ideal', 'NL', 39),
       ('00000000-0000-4000-8000-00000000000b', 'cs_live_b', 'pi_b', 499, 'paid', now() - interval '25 hours', null, 'card', 'BE', 40);
insert into public.billing_refunds (id, purchase_id, kind, amount, refunded_at)
select 're_a1', id, 'refund', 100, now() - interval '1 hour' from public.billing_purchases where stripe_session_id = 'cs_live_a';

create temp table before as
select public.bingr_revenue_sum(now() - interval '30 days', now() + interval '1 day', 'all') s,
       public.bingr_admin_revenue_rows(now() - interval '30 days', now() + interval '1 day', 'all') r,
       public.bingr_admin_revenue(array[now() - interval '30 days', now(), now() + interval '1 day'], 'all', '[]'::jsonb) v;
select pg_temp.ok((select (s->>'count')::int from before) = 3 and (select (s->>'refunds')::int from before) = 100, 'omzet vooraf');

-- RLS vooraf: A ziet zijn eigen twee aankopen
set role authenticated;
select set_config('test.uid', '00000000-0000-4000-8000-00000000000a', false);
select pg_temp.ok((select count(*) from public.billing_purchases) = 2, 'A ziet eigen aankopen');
reset role;

-- account A verwijderen (zoals auth.admin.deleteUser)
delete from auth.users where id = '00000000-0000-4000-8000-00000000000a';
select pg_temp.ok((select count(*) from public.billing_purchases) = 3, 'aankopen blijven na verwijderen account');
select pg_temp.ok((select count(*) from public.billing_purchases where user_id is null and user_deleted_at is not null) = 2, 'user_id leeg, user_deleted_at gezet');
select pg_temp.ok((select count(*) from public.billing_purchases where user_id is null and user_deleted_at is null) = 0, 'geen leeg account zonder moment');
select pg_temp.ok((select user_id from public.billing_purchases where stripe_session_id = 'cs_live_b') = '00000000-0000-4000-8000-00000000000b', 'B blijft gekoppeld');
select pg_temp.ok((select count(*) from public.billing_refunds) = 1, 'terugbetaling blijft');
select pg_temp.ok((select country || payment_method || tax_amount from public.billing_purchases where stripe_session_id = 'cs_live_a') = 'NLideal87', 'land, methode en btw blijven');

-- omzet en tellingen precies gelijk (geen join die aankopen zonder account wegfiltert)
select pg_temp.ok((select s from before) = public.bingr_revenue_sum(now() - interval '30 days', now() + interval '1 day', 'all'), 'bingr_revenue_sum gelijk');
select pg_temp.ok((select r from before) = public.bingr_admin_revenue_rows(now() - interval '30 days', now() + interval '1 day', 'all'), 'CSV-rijen gelijk');
select pg_temp.ok((select v from before) = public.bingr_admin_revenue(array[now() - interval '30 days', now(), now() + interval '1 day'], 'all', '[]'::jsonb), 'bingr_admin_revenue gelijk');
select pg_temp.ok(public.bingr_admin_purchase('00000000-0000-4000-8000-00000000000a') is null, 'beheer: geen aankoop meer bij het verwijderde account');

-- RLS: een rij zonder account ziet niemand; B alleen de eigen
set role authenticated;
select set_config('test.uid', '00000000-0000-4000-8000-00000000000a', false);
select pg_temp.ok((select count(*) from public.billing_purchases) = 0, 'verwijderd account ziet niets');
select set_config('test.uid', '00000000-0000-4000-8000-00000000000b', false);
select pg_temp.ok((select count(*) from public.billing_purchases) = 1, 'B ziet alleen de eigen aankoop');
select set_config('test.uid', '', false);
select pg_temp.ok((select count(*) from public.billing_purchases) = 0, 'zonder account niets');
reset role;

-- bewaartermijn: 7 jaar na het einde van het boekjaar, alleen zonder account
update public.billing_purchases set created_at = '2019-06-01 12:00+02', paid_at = '2019-06-01 12:00+02' where stripe_session_id = 'cs_live_a';
update public.billing_refunds set refunded_at = '2019-07-01 12:00+02' where id = 're_a1';
update public.billing_purchases set created_at = '2018-03-01 12:00+01', paid_at = '2018-03-01 12:00+01' where stripe_session_id = 'cs_test_old';
insert into public.billing_refunds (id, purchase_id, kind, amount, refunded_at)
select 're_old', id, 'refund', 499, '2020-02-01 12:00+01' from public.billing_purchases where stripe_session_id = 'cs_test_old';
update public.billing_purchases set created_at = '2010-01-01 12:00+01', paid_at = '2010-01-01 12:00+01' where stripe_session_id = 'cs_live_b';
select pg_temp.ok(public.bingr_billing_retention('2026-12-31 23:59+01') = 0, '2019 nog binnen de termijn op 31-12-2026');
select pg_temp.ok(public.bingr_billing_retention('2026-12-31 22:30+00') = 0, 'jaargrens: 23:30 lokaal op 31-12-2026 nog binnen de termijn');
select pg_temp.ok(public.bingr_billing_retention('2026-12-31 23:30+00') = 1, '2019 weg vanaf 1-1-2027 (00:30 lokaal, Europe/Amsterdam)');
select pg_temp.ok(not exists (select 1 from public.billing_purchases where stripe_session_id = 'cs_live_a'), 'aankoop uit 2019 weg');
select pg_temp.ok(not exists (select 1 from public.billing_refunds where id = 're_a1'), 'terugbetaling gaat mee');
select pg_temp.ok(exists (select 1 from public.billing_purchases where stripe_session_id = 'cs_test_old'), 'aankoop 2018 met terugbetaling in 2020 blijft');
select pg_temp.ok(exists (select 1 from public.billing_purchases where stripe_session_id = 'cs_live_b'), 'gekoppelde aankoop blijft (account bestaat)');
select pg_temp.ok(public.bingr_billing_retention('2028-01-01 00:30+01') = 1, 'terugbetaling uit 2020 weg vanaf 1-1-2028');
select pg_temp.ok((select count(*) from public.billing_purchases) = 1 and (select count(*) from public.billing_refunds) = 0, 'alleen B over');
-- rechten: niet voor de API-rollen
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_billing_retention(timestamptz)', 'execute'), 'retention niet voor authenticated');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_billing_retention(timestamptz)', 'execute'), 'retention niet voor anon');
