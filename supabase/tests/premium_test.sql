-- Unittests van build 181 (Bingr Premium). Draait via premium_test.sh in een tijdelijke database; :'cases' =
-- docs/build181_cases.json. Alleen testadressen (example.invalid).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin
  execute q; return false;
exception when others then return true;
end $$;
create temp table cases as select :'cases'::jsonb c;

-- standaardwaarden: uit, zoals nu
select pg_temp.ok((select value from public.app_settings where key = 'premium') = (select c -> 'defaults' from cases), 'standaard = defaults van de testgevallen');
select pg_temp.ok((select pg_get_constraintdef(oid) like '%subscription%' from pg_constraint where conname = 'account_plans_source_check'), 'source subscription toegestaan');

-- instellingen: de gedeelde gevallen (groep settings), telkens vanaf de standaard
do $$
declare x jsonb; d jsonb; good boolean;
begin
  select c -> 'defaults' into d from cases;
  for x in select jsonb_array_elements(c -> 'settings') from cases loop
    update public.app_settings set value = d where key = 'premium';
    if x -> 'input' = 'null'::jsonb then
      perform pg_temp.ok((public.bingr_admin_premium_settings(null) @> (x -> 'expect')), 'settings: ' || (x ->> 'name'));
      continue;
    end if;
    good := not pg_temp.fails(format('select public.bingr_admin_premium_settings(%L::jsonb)', x -> 'input'));
    perform pg_temp.ok(good = (x ->> 'ok')::boolean, 'settings: ' || (x ->> 'name'));
    if not good then perform pg_temp.ok((select value from public.app_settings where key = 'premium') = d, 'fout = niets veranderd: ' || (x ->> 'name')); end if;
  end loop;
  update public.app_settings set value = d where key = 'premium';
end $$;
select pg_temp.ok((public.bingr_admin_premium_settings('{"foo": 1}'::jsonb)) ? 'foo' = false, 'onbekende sleutel niet opgeslagen');
select public.bingr_admin_premium_settings('{"stripe_prices": {"test": {"month": "price_a"}}}'::jsonb);
select public.bingr_admin_premium_settings('{"stripe_prices": {"test": {"year": "price_c"}}, "prices": {"month": 599}}'::jsonb);
select pg_temp.ok((select value #> '{stripe_prices,test}' from public.app_settings where key = 'premium') = '{"month": "price_a", "year": "price_c"}'::jsonb
  and (select (value #>> '{prices,year}')::int from public.app_settings where key = 'premium') = 2999, 'samenvoegen per sleutel');
update public.app_settings set value = (select c -> 'defaults' from cases) where key = 'premium';

-- accounts
insert into auth.users (id, email, email_confirmed_at, created_at) values
  ('00000000-0000-4000-8000-0000000000a1', 'p1@example.invalid', now(), now() - interval '30 days'),
  ('00000000-0000-4000-8000-0000000000a2', 'p2@example.invalid', now(), now() - interval '30 days'),
  ('00000000-0000-4000-8000-0000000000a3', 'p3@example.invalid', null, now() - interval '1 day');
select pg_temp.ok(public.bingr_admin_premium_test('00000000-0000-4000-8000-0000000000a1', true) = '["00000000-0000-4000-8000-0000000000a1"]'::jsonb, 'testaccount aan');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_premium_test('00000000-0000-4000-8000-0000000000ff', true)$q$), 'onbekend account = fout');
select pg_temp.ok(public.bingr_admin_premium_test('00000000-0000-4000-8000-0000000000a1', false) = '[]'::jsonb, 'testaccount uit');

-- spiegel: de gedeelde gevallen (groep mirror). access_until in de toekomst = nu + 30 dagen.
do $$
declare x jsonb; u uuid := '00000000-0000-4000-8000-0000000000a2'; res text; r record; au timestamptz;
begin
  for x in select jsonb_array_elements(c -> 'mirror') from cases loop
    delete from public.premium_subscriptions; delete from public.account_plans where user_id = u;
    if x -> 'row' <> 'null'::jsonb then
      insert into public.account_plans (user_id, plan, source, premium_until, max_streams, max_devices)
      values (u, x #>> '{row,plan}', x #>> '{row,source}', (x #>> '{row,premium_until}')::timestamptz,
              (x #>> '{row,max_streams}')::int, (x #>> '{row,max_devices}')::int);
    end if;
    au := case when x -> 'access_until' = 'null'::jsonb then null else date_trunc('second', now() + interval '30 days') end;
    insert into public.premium_subscriptions (user_id, provider, plan, status, stripe_subscription_id, access_until, expires_at)
    values (u, 'stripe', 'year', case when au is null then 'expired' else 'active' end, 'sub_t1', au, now());
    res := public.bingr_premium_mirror(u);
    perform pg_temp.ok(res = x #>> '{expect,action}', 'mirror ' || (x ->> 'name') || ': actie ' || res);
    select * into r from public.account_plans where user_id = u;
    if res = 'delete' then perform pg_temp.ok(not found, 'mirror ' || (x ->> 'name') || ': rij weg'); end if;
    if res in ('upsert', 'update') then
      perform pg_temp.ok(r.plan = x #>> '{expect,plan}' and r.source is not distinct from (x #>> '{expect,source}')
        and r.premium_until is not distinct from au, 'mirror ' || (x ->> 'name') || ': rij');
      if x #> '{expect,max_devices}' is not null then perform pg_temp.ok(r.max_devices = (x #>> '{expect,max_devices}')::int, 'mirror: limieten blijven'); end if;
    end if;
    if res = 'keep' and x -> 'row' <> 'null'::jsonb then
      perform pg_temp.ok(r.plan = x #>> '{row,plan}' and r.source is not distinct from (x #>> '{row,source}'), 'mirror ' || (x ->> 'name') || ': ongewijzigd');
    end if;
  end loop;
  delete from public.premium_subscriptions; delete from public.account_plans where user_id = u;
end $$;

-- sweep: verlopen spiegel weg, lopende blijft, Lifetime blijft
insert into public.account_plans (user_id, plan, source, premium_until) values
  ('00000000-0000-4000-8000-0000000000a1', 'lifetime', 'legacy', null),
  ('00000000-0000-4000-8000-0000000000a2', 'lifetime', 'subscription', now() - interval '1 minute');
select pg_temp.ok(public.bingr_premium_sweep() = '{"expired": 1}'::jsonb, 'sweep ruimt 1 op');
select pg_temp.ok(not exists (select 1 from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2'), 'verlopen spiegel weg');
select pg_temp.ok(exists (select 1 from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a1' and source = 'legacy'), 'legacy blijft');
-- een gekochte Lifetime overschrijft een spiegel (bingr_billing_attach)
insert into public.premium_subscriptions (user_id, provider, plan, status, stripe_subscription_id, access_until, expires_at)
values ('00000000-0000-4000-8000-0000000000a2', 'stripe', 'month', 'active', 'sub_t2', now() + interval '20 days', now() + interval '19 days');
select public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a2');
select pg_temp.ok((select source from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2') = 'subscription', 'spiegel gezet');
insert into public.billing_purchases (user_id, stripe_session_id, amount, currency, status, paid_at, plan)
values (null, 'cs_test_p49', 4999, 'eur', 'paid', now(), 'lifetime49');
select pg_temp.ok(public.bingr_billing_attach((select id from public.billing_purchases where stripe_session_id = 'cs_test_p49'), '00000000-0000-4000-8000-0000000000a2', 'stripe'), 'Lifetime gekoppeld');
select pg_temp.ok((select source from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2') = 'purchase', 'gekochte Lifetime over de spiegel');
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a2') = 'keep', 'daarna beschermd');
select pg_temp.ok(pg_temp.fails($q$insert into public.billing_purchases (user_id, stripe_session_id, amount, currency, status, plan) values (null, 'cs_test_x', 1, 'eur', 'paid', 'lifetime99')$q$), 'onbekend Lifetime-plan geweigerd');

-- gast-abonnement claimen: token één keer, verlopen, e-mail alleen bevestigd, Lifetime-account niet
delete from public.account_plans;
insert into public.premium_subscriptions (provider, plan, status, stripe_subscription_id, access_until, expires_at, trial_until, claim_token_hash, claim_expires_at, claim_email_hash)
values ('stripe', 'year', 'trialing', 'sub_g1', now() + interval '3 days', now() + interval '3 days', now() + interval '3 days', repeat('a', 64), now() + interval '30 days', null),
       ('stripe', 'month', 'active', 'sub_g2', now() + interval '30 days', now() + interval '30 days', null, repeat('b', 64), now() - interval '1 day', public.bingr_email_hash('P2@example.invalid ')),
       ('stripe', 'month', 'active', 'sub_g3', now() + interval '30 days', now() + interval '30 days', null, repeat('c', 64), now() + interval '30 days', public.bingr_email_hash('p3@example.invalid'));
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a2', repeat('a', 64)) ->> 'result' = 'claimed', 'token: geclaimd');
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a2', repeat('a', 64)) ->> 'result' = 'already_yours', 'token: al van jou');
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a3', repeat('a', 64)) ->> 'result' = 'owned_by_other_account', 'token: ander account');
select pg_temp.ok(exists (select 1 from public.premium_trials where user_id = '00000000-0000-4000-8000-0000000000a2'), 'proef vastgelegd bij claimen');
select pg_temp.ok((select source from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2') = 'subscription', 'spiegel na claimen');
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a3', repeat('b', 64)) ->> 'result' = 'expired', 'token verlopen');
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a3', repeat('d', 64)) ->> 'result' = 'invalid', 'onbekend token');
select pg_temp.ok(public.bingr_premium_claim_email('00000000-0000-4000-8000-0000000000a2') = '{"claimed": 1}'::jsonb, 'e-mail (getrimd, kleine letters) koppelt ook een verlopen token');
select pg_temp.ok(public.bingr_premium_claim_email('00000000-0000-4000-8000-0000000000a3') = '{"claimed": 0}'::jsonb, 'onbevestigd adres koppelt niet');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-4000-8000-0000000000a3';
select pg_temp.ok((select user_id from public.premium_subscriptions where stripe_subscription_id = 'sub_g3') = '00000000-0000-4000-8000-0000000000a3', 'trigger bij bevestigen koppelt');
insert into public.premium_subscriptions (provider, plan, status, stripe_subscription_id, access_until, claim_token_hash, claim_expires_at)
values ('stripe', 'year', 'active', 'sub_g4', now() + interval '30 days', repeat('e', 64), now() + interval '30 days');
insert into public.account_plans (user_id, plan, source) values ('00000000-0000-4000-8000-0000000000a1', 'lifetime', 'admin');
select pg_temp.ok(public.bingr_premium_claim('00000000-0000-4000-8000-0000000000a1', repeat('e', 64)) ->> 'result' = 'already_lifetime', 'Lifetime-account claimt geen abonnement');
select pg_temp.ok((select user_id from public.premium_subscriptions where stripe_subscription_id = 'sub_g4') is null, 'blijft ongekoppeld');

-- één proef per account
select pg_temp.ok(pg_temp.fails($q$insert into public.premium_trials (user_id, provider) values ('00000000-0000-4000-8000-0000000000a2', 'apple')$q$), 'tweede proef geweigerd');
-- stripe- of apple-referentie verplicht
select pg_temp.ok(pg_temp.fails($q$insert into public.premium_subscriptions (provider, plan, status) values ('apple', 'year', 'active')$q$), 'Apple zonder transactie-id');

-- statistieken (alleen totalen)
insert into public.premium_payments (id, subscription_id, user_id, plan, amount, currency, mode, paid_at)
values ('in_t1', (select id from public.premium_subscriptions where stripe_subscription_id = 'sub_g2'), '00000000-0000-4000-8000-0000000000a2', 'month', 499, 'eur', 'test', now());
select pg_temp.ok((public.bingr_admin_premium_stats() ->> 'trialing')::int = 1 and (public.bingr_admin_premium_stats() ->> 'active')::int = 4, 'stats: proef en actief (ook ongekoppeld)');
select pg_temp.ok((public.bingr_admin_premium_stats() ->> 'mrr_cents')::int = 1747 and (public.bingr_admin_premium_stats() ->> 'unclaimed')::int = 1, 'stats: MRR 3 x maand + jaar / 12, 1 ongekoppeld');
select pg_temp.ok((public.bingr_admin_premium_stats() #>> '{stripe_revenue,test,gross}')::int = 499, 'stats: omzet test');
select pg_temp.ok((public.bingr_admin_premium_stats() ->> 'trials_converted')::int = 1, 'stats: proef omgezet (betaald)');
select pg_temp.ok((public.bingr_admin_premium_stats() #>> '{lifetime49,count}')::int = 1, 'stats: Lifetime 49');
select pg_temp.ok(public.bingr_admin_premium_stats()::text !~ '@example', 'stats zonder e-mailadressen');

-- ---------------- build 193: sandbox ----------------
delete from public.premium_subscriptions; delete from public.account_plans; delete from public.billing_purchases;
-- de trigger: alleen "gekocht bij Apple, notitie Apple sandbox" is sandbox en mag tijdelijk zijn
insert into public.account_plans (user_id, plan, source, granted_by, note, premium_until) values
  ('00000000-0000-4000-8000-0000000000a1', 'lifetime', 'purchase', 'apple', 'Apple sandbox 2000001', null),
  ('00000000-0000-4000-8000-0000000000a2', 'lifetime', 'purchase', 'apple', 'Apple sandbox 2000002', now() + interval '2 days'),
  ('00000000-0000-4000-8000-0000000000a3', 'lifetime', 'purchase', 'apple', 'Apple 100001', now() + interval '2 days');
select pg_temp.ok((select sandbox and sandbox_at is not null and premium_until is null from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a1'), 'sandbox blijvend: gemerkt');
select pg_temp.ok((select sandbox and premium_until is not null from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2'), 'sandbox tijdelijk: gemerkt, einde blijft');
select pg_temp.ok((select not sandbox and premium_until is null from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a3'), 'echte Apple-aankoop: nooit tijdelijk, geen vlag');
select pg_temp.ok(public.bingr_admin_sandbox_stats() = '{"lifetime_accounts": 1, "active_7d": 0, "temporary": 1}'::jsonb, 'sandbox-tellingen');
-- testaccount telt niet mee als sandbox-Lifetime
select public.bingr_admin_premium_test('00000000-0000-4000-8000-0000000000a1', true);
select pg_temp.ok((public.bingr_admin_sandbox_stats() ->> 'lifetime_accounts')::int = 0, 'testaccount telt niet');
select public.bingr_admin_premium_test('00000000-0000-4000-8000-0000000000a1', false);
-- lopende tijdelijke Lifetime: de spiegel laat hem staan; de sweep ook
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a2') = 'keep', 'tijdelijk loopt nog: blijft');
select pg_temp.ok(public.bingr_premium_sweep() = '{"expired": 0}'::jsonb, 'sweep: niets verlopen');
-- voorbij: Gratis, de vlag blijft (de rij wordt niet gewist), en het filter toont hem niet meer
update public.account_plans set premium_until = now() - interval '1 minute' where user_id = '00000000-0000-4000-8000-0000000000a2';
select pg_temp.ok(public.bingr_premium_sweep() = '{"expired": 1}'::jsonb, 'sweep: tijdelijke sandbox-Lifetime verlopen');
select pg_temp.ok((select plan = 'free' and source is null and premium_until is null and sandbox from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2'), 'na 3 dagen Gratis, vlag blijft');
select pg_temp.ok((select plan = 'lifetime' and sandbox from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a1'), 'blijvende sandbox-Lifetime ongemoeid (alleen gemerkt)');
-- een echt abonnement gaat over een tijdelijke sandbox-Lifetime heen (en is geen sandbox); een blijvende Lifetime blijft beschermd
update public.account_plans set plan = 'lifetime', source = 'purchase', granted_by = 'apple', note = 'Apple sandbox 2000002', premium_until = now() + interval '1 day'
 where user_id = '00000000-0000-4000-8000-0000000000a2';
insert into public.premium_subscriptions (user_id, provider, plan, status, stripe_subscription_id, access_until, expires_at, mode)
values ('00000000-0000-4000-8000-0000000000a2', 'stripe', 'month', 'active', 'sub_s1', now() + interval '20 days', now() + interval '19 days', 'live');
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a2') = 'upsert', 'abonnement over tijdelijke sandbox');
select pg_temp.ok((select source = 'subscription' and not sandbox and premium_until > now() + interval '19 days' from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a2'), 'spiegel, geen sandbox meer');
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a1') = 'keep', 'blijvende Lifetime beschermd');
-- alleen een testabonnement = sandbox (gemerkt door de spiegel); na afloop Gratis met de vlag (rij blijft)
delete from public.premium_subscriptions;
insert into public.premium_subscriptions (user_id, provider, plan, status, apple_original_transaction_id, access_until, expires_at, mode)
values ('00000000-0000-4000-8000-0000000000a3', 'apple', 'year', 'trialing', '2000009', now() + interval '3 days', now() + interval '3 days', 'test');
delete from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a3';
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a3') = 'upsert', 'testabonnement gespiegeld');
select pg_temp.ok((select sandbox and source = 'subscription' from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a3'), 'testabonnement = sandbox');
update public.premium_subscriptions set access_until = now() - interval '1 minute';
select pg_temp.ok(public.bingr_premium_mirror('00000000-0000-4000-8000-0000000000a3') = 'update', 'testabonnement voorbij: Gratis (rij blijft)');
-- beheer geeft Lifetime, of een echte aankoop: blijvend en geen sandbox
update public.account_plans set plan = 'lifetime', source = 'admin', granted_by = 'beheer', premium_until = now() + interval '1 day' where user_id = '00000000-0000-4000-8000-0000000000a3';
select pg_temp.ok((select not sandbox and premium_until is null from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a3'), 'beheer: blijvend, geen sandbox');
update public.account_plans set source = 'purchase', granted_by = 'stripe', note = 'Stripe cs_x / pi_x' where user_id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.ok((select not sandbox and premium_until is null from public.account_plans where user_id = '00000000-0000-4000-8000-0000000000a1'), 'Stripe-aankoop: geen sandbox');
-- ---------------- build 193: betaaltrechter ----------------
select pg_temp.ok(public.bingr_funnel_hit('ios', 'paywall_shown') and public.bingr_funnel_hit('ios', 'paywall_shown') and public.bingr_funnel_hit('web', 'purchase_failed', 'year', 'http_500'), 'trechter: tellen');
select pg_temp.ok((select n from public.billing_funnel_daily where platform = 'ios' and step = 'paywall_shown') = 2, 'trechter: zelfde stap telt op');
select pg_temp.ok((select count(*) from public.billing_funnel_daily) = 2 and (select product || '/' || error from public.billing_funnel_daily where platform = 'web') = 'year/http_500', 'trechter: rij per product en foutcode');
select pg_temp.ok(not public.bingr_funnel_hit('tizen', 'paywall_shown') and not public.bingr_funnel_hit('ios', 'iets') and not public.bingr_funnel_hit('ios', 'purchase_failed', 'week')
  and not public.bingr_funnel_hit('ios', 'purchase_failed', '', 'Vrije tekst') and not public.bingr_funnel_hit(null, 'paywall_shown'), 'trechter: ongeldig telt niet');
select pg_temp.ok((select count(*) from public.billing_funnel_daily) = 2, 'trechter: niets bijgekomen');
do $$ begin for i in 1..70 loop perform public.bingr_funnel_hit('android', 'purchase_failed', '', 'code_' || i); end loop; end $$;
select pg_temp.ok((select count(distinct error) from public.billing_funnel_daily where error <> '') = 61 and (select n from public.billing_funnel_daily where error = 'other') = 11, 'trechter: hooguit 60 foutcodes per dag, de rest als other');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.billing_funnel_daily', 'select') and not has_table_privilege('anon', 'public.billing_funnel_daily', 'insert'), 'trechter: tabel alleen service role');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_funnel_hit(text, text, text, text)', 'execute') and has_function_privilege('service_role', 'public.bingr_funnel_hit(text, text, text, text)', 'execute'), 'trechter: functie alleen service role');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_admin_sandbox_stats()', 'execute'), 'sandbox-tellingen alleen service role');

-- rechten: alleen service role
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_admin_premium_settings(jsonb)', 'execute'), 'settings niet voor authenticated');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_premium_mirror(uuid)', 'execute'), 'mirror niet voor anon');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_premium_attach(bigint, uuid)', 'execute'), 'attach intern');
select pg_temp.ok(has_function_privilege('service_role', 'public.bingr_admin_premium_stats()', 'execute'), 'stats voor service role');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.premium_subscriptions', 'select'), 'tabel niet voor authenticated');
