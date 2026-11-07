-- Unittests van build 167 (alleen Lifetime). Draait via lifetime_test.sh in een tijdelijke database. Alleen testadressen.
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin
  execute q; return false;
exception when others then return true;
end $$;

-- standaardwaarden: uit, zoals nu; bestaande upgrade_link krijgt apple_eu false (en blijft verder gelijk)
select pg_temp.ok((select value->>'enabled' from public.app_settings where key = 'lifetime_only') = 'false', 'lifetime_only standaard uit');
select pg_temp.ok((select (value->>'discount_pct')::int from public.app_settings where key = 'lifetime_only') = 30, '30% standaard');
select pg_temp.ok((select (value->>'trial_days')::int from public.app_settings where key = 'lifetime_only') = 0, 'geen proefperiode');
select pg_temp.ok((select (value->>'cutover_at')::timestamptz from public.app_settings where key = 'lifetime_only') = '2026-11-30T23:00:00Z'
  and (select value->>'code_valid_until' from public.app_settings where key = 'lifetime_only') = '2026-12-01T00:00:00+01:00', 'aanvulling 2: 1 december 2026');
select pg_temp.ok((select value->>'apple' from public.app_settings where key = 'iap') = 'false', 'iap.apple standaard uit');
select pg_temp.ok((select value from public.app_settings where key = 'upgrade_link') =
  '{"apple": false, "android": true, "androidtv": true, "tizen": true, "web": true, "apple_eu": false}'::jsonb, 'upgrade_link + apple_eu false');

-- instellingen: lezen, samenvoegen, controleren
select pg_temp.ok((public.bingr_admin_lifetime_settings())->'lifetime_only'->>'enabled' = 'false', 'lezen');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"enabled": true, "cutover_at": null}'::jsonb)$q$), 'aan zonder cutover_at = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"discount_pct": 95}'::jsonb)$q$), 'korting > 90 = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"cutover_at": "morgen"}'::jsonb)$q$), 'geen tijd = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"onbekend": 1}'::jsonb)$q$), 'onbekende sleutel = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings(null, '{"apple": "ja"}'::jsonb)$q$), 'iap.apple geen boolean = fout');
select pg_temp.ok((select value->>'enabled' from public.app_settings where key = 'lifetime_only') = 'false', 'fout = niets veranderd');
select public.bingr_admin_lifetime_settings(
  jsonb_build_object('enabled', true, 'announce_at', now()::text, 'cutover_at', (now() + interval '30 days')::text), '{"apple": true}'::jsonb, true);
select pg_temp.ok((select value->>'enabled' from public.app_settings where key = 'lifetime_only') = 'true'
  and (select (value->>'discount_pct')::int from public.app_settings where key = 'lifetime_only') = 30, 'samengevoegd met de oude waarde');
select pg_temp.ok((select value->>'apple' from public.app_settings where key = 'iap') = 'true', 'iap aan');
select pg_temp.ok((select value->>'apple_eu' from public.app_settings where key = 'upgrade_link') = 'true'
  and (select value->>'android' from public.app_settings where key = 'upgrade_link') = 'true', 'apple_eu aan, rest blijft');

-- accounts: A gratis bevestigd, B gratis onbevestigd, C Lifetime, D geblokkeerd, E geband, F gratis bevestigd
insert into auth.users (id, email, email_confirmed_at, created_at) values
  ('00000000-0000-4000-8000-00000000000a', 'a@example.invalid', now(), now() - interval '9 days'),
  ('00000000-0000-4000-8000-00000000000b', 'b@example.invalid', null, now() - interval '8 days'),
  ('00000000-0000-4000-8000-00000000000c', 'c@example.invalid', now(), now() - interval '7 days'),
  ('00000000-0000-4000-8000-00000000000d', 'd@example.invalid', now(), now() - interval '6 days'),
  ('00000000-0000-4000-8000-00000000000f', 'f@example.invalid', now(), now() - interval '4 days');
insert into auth.users (id, email, email_confirmed_at, banned_until) values
  ('00000000-0000-4000-8000-00000000000e', 'e@example.invalid', now(), now() + interval '1 day');
insert into public.account_plans (user_id, plan, source) values ('00000000-0000-4000-8000-00000000000c', 'lifetime', 'legacy');
insert into public.account_blocks (user_id, reason) values ('00000000-0000-4000-8000-00000000000d', 'test');

select pg_temp.ok(public.bingr_lifetime_candidates(10) =
  '["00000000-0000-4000-8000-00000000000a", "00000000-0000-4000-8000-00000000000f"]'::jsonb, 'alleen gratis, bevestigd, niet geblokkeerd');
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_candidates(1)) = 1, 'limiet');
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'candidates')::int = 2, 'stats: 2 kandidaten');

-- build 168: nieuwe accounts eerst kopen. Instellingen: null of een tijd; accounts op of na de vroegste datum krijgen geen
-- code en geen mail (de korting is voor bestaande accounts). Daarna weer null: precies zoals build 167.
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"new_paid_from": "straks"}'::jsonb)$q$), 'new_paid_from geen tijd = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_admin_lifetime_settings('{"new_paid_from_apple": 5}'::jsonb)$q$), 'new_paid_from_apple geen tijd = fout');
select pg_temp.ok((select value ? 'new_paid_from' from public.app_settings where key = 'lifetime_only') = false, 'fout = niets veranderd');
select public.bingr_admin_lifetime_settings(jsonb_build_object('new_paid_from', (now() - interval '5 days')::text));
select pg_temp.ok((select value->>'enabled' from public.app_settings where key = 'lifetime_only') = 'true'
  and (select (value->>'new_paid_from')::timestamptz from public.app_settings where key = 'lifetime_only') < now(), 'new_paid_from gezet, rest blijft');
select pg_temp.ok(public.bingr_lifetime_candidates(10) = '["00000000-0000-4000-8000-00000000000a"]'::jsonb, 'F (na new_paid_from) krijgt geen code');
select public.bingr_admin_lifetime_settings('{"new_paid_from": null}'::jsonb);
select public.bingr_admin_lifetime_settings(jsonb_build_object('new_paid_from_apple', (now() - interval '5 days')::text));
select pg_temp.ok(public.bingr_lifetime_candidates(10) = '["00000000-0000-4000-8000-00000000000a"]'::jsonb, 'ook met alleen de Apple-datum');
select public.bingr_admin_lifetime_settings(jsonb_build_object('new_paid_from', (now() - interval '20 days')::text, 'new_paid_from_apple', null));
select pg_temp.ok(public.bingr_lifetime_candidates(10) = '[]'::jsonb, 'vroegste datum telt');
select public.bingr_admin_lifetime_settings('{"new_paid_from": null, "new_paid_from_apple": null}'::jsonb);
select pg_temp.ok(public.bingr_lifetime_candidates(10) =
  '["00000000-0000-4000-8000-00000000000a", "00000000-0000-4000-8000-00000000000f"]'::jsonb, 'null = zoals build 167');

-- codes: vorm en uniek
select pg_temp.ok(pg_temp.fails($q$insert into public.lifetime_codes (user_id, code, expires_at) values ('00000000-0000-4000-8000-00000000000a', 'BINGR-0OI1-AAAA', now() + interval '1 day')$q$), 'verwarrende tekens geweigerd');
insert into public.lifetime_codes (user_id, code, expires_at, stripe_promotion_code_id, stripe_mode) values
  ('00000000-0000-4000-8000-00000000000a', 'BINGR-ABCD-EFGH', now() + interval '30 days', 'promo_a', 'test');
insert into public.lifetime_codes (user_id, code, expires_at, stripe_mode) values
  ('00000000-0000-4000-8000-00000000000f', 'BINGR-HJKM-NPQR', now() + interval '30 days', 'test');
select pg_temp.ok(pg_temp.fails($q$insert into public.lifetime_codes (user_id, code, expires_at) values ('00000000-0000-4000-8000-00000000000b', 'BINGR-ABCD-EFGH', now())$q$), 'code uniek');
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'candidates')::int = 0 and (public.bingr_admin_lifetime_stats()->>'pending_stripe')::int = 1, 'stats na aanmaken');

-- mail: alleen A (F heeft nog geen promotion code); claimen = geen dubbele ronde
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'mail_pending')::int = 1, 'één wacht op de mail');
create temp table t1 as select public.bingr_lifetime_mail_take('notice', 10) j;
select pg_temp.ok(jsonb_array_length((select j from t1)) = 1 and (select j->0->>'code' from t1) = 'BINGR-ABCD-EFGH'
  and (select j->0->>'email' from t1) = 'a@example.invalid', 'ontvanger met code');
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_mail_take('notice', 10)) = 0, 'tweede ronde krijgt hem niet');
select public.bingr_lifetime_mail_mark('notice', '{}', '{}', '{}', array['00000000-0000-4000-8000-00000000000a']::uuid[]);
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_mail_take('notice', 10)) = 1, 'retry: volgende ronde opnieuw');
select pg_temp.ok((public.bingr_lifetime_mail_mark('notice', array['00000000-0000-4000-8000-00000000000a']::uuid[], '{}', '{}', '{}'))->>'sent' = '1', 'verstuurd');
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_mail_take('notice', 10)) = 0, 'idempotent via mailed_at');
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'mailed')::int = 1, 'stats: gemaild');
-- herinnering apart; mailfout = niet opnieuw
create temp table t2 as select public.bingr_lifetime_mail_take('remind', 10) j;
select pg_temp.ok(jsonb_array_length((select j from t2)) = 1, 'herinnering');
select public.bingr_lifetime_mail_mark('remind', '{}', array['00000000-0000-4000-8000-00000000000a']::uuid[], array['smtp_550'], '{}');
select pg_temp.ok((select remind_error from public.lifetime_codes where user_id = '00000000-0000-4000-8000-00000000000a') = 'smtp_550', 'foutcode');
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_mail_take('remind', 10)) = 0, 'fout = niet opnieuw');
-- Lifetime gekocht = geen mail meer
update public.lifetime_codes set stripe_promotion_code_id = 'promo_f' where user_id = '00000000-0000-4000-8000-00000000000f';
insert into public.account_plans (user_id, plan, source) values ('00000000-0000-4000-8000-00000000000f', 'lifetime', 'purchase');
select pg_temp.ok(jsonb_array_length(public.bingr_lifetime_mail_take('notice', 10)) = 0, 'Lifetime krijgt geen mail');
select pg_temp.ok(public.bingr_lifetime_code_of('00000000-0000-4000-8000-00000000000a')->>'status' = 'mailed', 'status per account');
select pg_temp.ok(public.bingr_lifetime_code_of('00000000-0000-4000-8000-00000000000b') is null, 'geen code = null');
update public.lifetime_codes set expires_at = now() - interval '1 second' where user_id = '00000000-0000-4000-8000-00000000000a';
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'expired')::int = 1 and public.bingr_lifetime_code_of('00000000-0000-4000-8000-00000000000a')->>'status' = 'expired', 'verlopen');

-- Apple-aankoop: provider, uniek op originalTransactionId, geen Stripe-sessie
insert into public.billing_purchases (user_id, provider, apple_original_transaction_id, apple_transaction_id, environment, amount, currency, status, paid_at)
values ('00000000-0000-4000-8000-00000000000a', 'apple', '2000000000000001', '2000000000000001', 'test', 499, 'eur', 'paid', now());
select pg_temp.ok(pg_temp.fails($q$insert into public.billing_purchases (user_id, provider, apple_original_transaction_id, amount, status) values ('00000000-0000-4000-8000-00000000000f', 'apple', '2000000000000001', 499, 'paid')$q$), 'originalTransactionId uniek');
select pg_temp.ok(pg_temp.fails($q$insert into public.billing_purchases (provider, amount, status) values ('apple', 499, 'paid')$q$), 'apple zonder transactie-id geweigerd');
select pg_temp.ok(pg_temp.fails($q$insert into public.billing_purchases (provider, stripe_session_id, amount, status) values ('paypal', 'cs_test_x', 499, 'paid')$q$), 'onbekende provider geweigerd');
insert into public.billing_refunds (id, purchase_id, kind, amount, refunded_at)
select 'apl_2000000000000001', id, 'refund', 0, now() from public.billing_purchases where apple_original_transaction_id = '2000000000000001';
select pg_temp.ok((select count(*) from public.billing_refunds where id like 'apl\_%') = 1, 'terugbetaling van Apple (apl_)');
select pg_temp.ok((public.bingr_revenue_sum(now() - interval '1 day', now() + interval '1 day', 'test')->>'count')::int = 1, 'Apple sandbox = test');
select pg_temp.ok((public.bingr_revenue_sum(now() - interval '1 day', now() + interval '1 day', 'live')->>'count')::int = 0, 'niet live');
select pg_temp.ok(public.bingr_revenue_sum(now() - interval '1 day', now() + interval '1 day', 'all')->'by_provider' =
  '[{"key": "apple", "count": 1, "gross": 499}]'::jsonb, 'by_provider');

-- gastaankoop: zonder account, claimen met token (één keer, 30 dagen) of e-mailadres (alleen bevestigd)
select pg_temp.ok(public.bingr_email_hash(' A@Example.Invalid ') = encode(sha256('a@example.invalid'::bytea), 'hex'), 'e-mailhash');
insert into public.billing_purchases (user_id, stripe_session_id, amount, status, paid_at, claim_token_hash, claim_expires_at, claim_email_hash) values
  (null, 'cs_test_g1', 499, 'paid', now(), repeat('1', 64), now() + interval '30 days', public.bingr_email_hash('nieuw@example.invalid')),
  (null, 'cs_test_g2', 499, 'paid', now(), repeat('2', 64), now() - interval '1 second', null),
  (null, 'cs_test_g3', 499, 'refunded', now(), repeat('3', 64), now() + interval '30 days', null),
  (null, 'cs_test_g4', 499, 'paid', now(), repeat('4', 64), now() + interval '30 days', public.bingr_email_hash('b@example.invalid'));
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'unclaimed')::int = 3, 'drie ongeclaimd (betaald)');
select pg_temp.ok((public.bingr_admin_unclaimed(10)->>'total')::int = 3 and public.bingr_admin_unclaimed(10)::text !~ '(@|claim_token_hash|claim_email_hash")', 'beheerlijst zonder adres of hash');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000b', repeat('9', 64))->>'result' = 'invalid', 'onbekend token');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000b', repeat('2', 64))->>'result' = 'expired', 'verlopen token');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000b', repeat('3', 64))->>'result' = 'revoked', 'terugbetaald');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000b', repeat('1', 64))->>'result' = 'claimed', 'claimen');
select pg_temp.ok((select plan || source || granted_by from public.account_plans where user_id = '00000000-0000-4000-8000-00000000000b') = 'lifetimepurchasestripe', 'Lifetime na claimen');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000b', repeat('1', 64))->>'result' = 'already_yours', 'tweede keer: al van jou');
select pg_temp.ok(public.bingr_billing_claim('00000000-0000-4000-8000-00000000000a', repeat('1', 64))->>'result' = 'owned_by_other_account', 'ander account: nee');
-- e-mail: B is niet bevestigd -> g4 nog niet; na bevestigen koppelt de trigger hem
select pg_temp.ok((public.bingr_billing_claim_email('00000000-0000-4000-8000-00000000000b')->>'claimed')::int = 0, 'onbevestigd: niet via e-mail');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-4000-8000-00000000000b';
select pg_temp.ok((select user_id from public.billing_purchases where stripe_session_id = 'cs_test_g4') = '00000000-0000-4000-8000-00000000000b', 'bevestigen = automatisch claimen');
-- webhook: al een bevestigd account met dat adres
insert into public.billing_purchases (user_id, stripe_session_id, amount, status, paid_at, claim_email_hash) values
  (null, 'cs_test_g5', 499, 'paid', now(), public.bingr_email_hash('a@example.invalid'));
select pg_temp.ok((public.bingr_billing_claim_hash(public.bingr_email_hash('a@example.invalid'))->>'claimed')::int = 1, 'webhook koppelt meteen');
select pg_temp.ok((public.bingr_billing_claim_hash(public.bingr_email_hash('niemand@example.invalid'))->>'claimed')::int = 0, 'geen account: niets');
-- Lifetime uit het beheer blijft beheer
insert into public.billing_purchases (user_id, stripe_session_id, amount, status, paid_at) values (null, 'cs_test_g6', 499, 'paid', now());
select pg_temp.ok((public.bingr_admin_purchase_assign((select id from public.billing_purchases where stripe_session_id = 'cs_test_g6'),
  '00000000-0000-4000-8000-00000000000c'))->>'result' = 'assigned', 'handmatig koppelen');
select pg_temp.ok((select source from public.account_plans where user_id = '00000000-0000-4000-8000-00000000000c') = 'legacy', 'cadeau-Lifetime blijft legacy');
select pg_temp.ok((public.bingr_admin_purchase_assign((select id from public.billing_purchases where stripe_session_id = 'cs_test_g6'),
  '00000000-0000-4000-8000-00000000000a'))->>'result' = 'not_assignable', 'al gekoppeld: niet opnieuw');
select pg_temp.ok((public.bingr_admin_purchase_assign(999999, '00000000-0000-4000-8000-0000000000ff'))->>'result' = 'no_user', 'onbekend account');
select pg_temp.ok((public.bingr_admin_lifetime_stats()->>'unclaimed')::int = 1, 'alleen het verlopen token blijft over (beheer kan hem koppelen)');

-- rechten: alleen service role
select pg_temp.ok(not has_table_privilege('authenticated', 'public.lifetime_codes', 'select'), 'codes niet leesbaar voor apps');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_billing_claim(uuid, text)', 'execute'), 'claim alleen via de functie');
select pg_temp.ok(not has_function_privilege('anon', 'public.bingr_admin_purchase_assign(bigint, uuid)', 'execute'), 'assign alleen beheer');
select pg_temp.ok(has_function_privilege('service_role', 'public.bingr_admin_lifetime_stats()', 'execute'), 'stats voor service role');
