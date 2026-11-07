-- Unittests van de Apple-omzet (apple_sales_daily en de functies in het blok "unittest apple-sales"). Draait via
-- apple_sales_test.sh in een tijdelijke database. Alleen verzonnen rapportregels en testaccounts.
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception 'MISLUKT: %', msg; end if;
end $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin
  execute q; return false;
exception when others then return true;
end $$;

-- standaardwaarden
select pg_temp.ok((select value from public.app_settings where key = 'fx_rates') = '{}'::jsonb, 'fx_rates standaard leeg');
select pg_temp.ok(public.bingr_apple_commission() = 15, 'commissie standaard 15%');

-- een dag opslaan; dubbele sleutels samengevoegd (gewogen opbrengst)
select pg_temp.ok(public.bingr_apple_sales_put('2026-11-03', '[
  {"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":3,"customer_price":4.99,"developer_proceeds":3.48},
  {"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":4.99,"developer_proceeds":3.52},
  {"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"US","customer_currency":"USD","proceeds_currency":"USD","units":2,"customer_price":4.99,"developer_proceeds":4.24},
  {"kind":"refund","product_id":"nl.lrvdlinden.bingr.lifetime","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":4.99,"developer_proceeds":3.48}
]'::jsonb) = 3, 'drie rijen (NL samengevoegd)');
select pg_temp.ok((select units from public.apple_sales_daily where date = '2026-11-03' and country = 'NL' and kind = 'sale') = 4, 'units opgeteld');
select pg_temp.ok((select developer_proceeds from public.apple_sales_daily where date = '2026-11-03' and country = 'NL' and kind = 'sale') = 3.49, 'gewogen opbrengst');
-- opnieuw dezelfde dag = overschrijven (idempotent)
select public.bingr_apple_sales_put('2026-11-03', '[
  {"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":4,"customer_price":4.99,"developer_proceeds":3.49},
  {"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"US","customer_currency":"USD","proceeds_currency":"USD","units":2,"customer_price":4.99,"developer_proceeds":4.24},
  {"kind":"refund","product_id":"nl.lrvdlinden.bingr.lifetime","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":4.99,"developer_proceeds":3.48}
]'::jsonb);
select public.bingr_apple_sales_put('2026-11-03', (select jsonb_agg(to_jsonb(s) - 'id' - 'date' - 'fetched_at') from public.apple_sales_daily s where date = '2026-11-03'));
select pg_temp.ok((select count(*) from public.apple_sales_daily where date = '2026-11-03') = 3 and
  (select sum(units) from public.apple_sales_daily where date = '2026-11-03') = 7, 'twee keer dezelfde dag = gelijk');
-- ongeldige rij: alles of niets, de oude rijen blijven
select pg_temp.ok(pg_temp.fails($q$select public.bingr_apple_sales_put('2026-11-03', '[{"kind":"sale","product_id":"x","country":"Nederland","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":1,"developer_proceeds":1}]'::jsonb)$q$), 'land geen code = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_apple_sales_put('2026-11-03', '[{"kind":"gift","product_id":"x","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":1,"developer_proceeds":1}]'::jsonb)$q$), 'onbekende soort = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_apple_sales_put('2026-11-03', '[{"kind":"sale","product_id":"x","country":"NL","customer_currency":"EUR","proceeds_currency":"EUR","units":-1,"customer_price":1,"developer_proceeds":1}]'::jsonb)$q$), 'negatieve units = fout');
select pg_temp.ok(pg_temp.fails($q$select public.bingr_apple_sales_put(null, '[]'::jsonb)$q$), 'zonder datum = fout');
select pg_temp.ok((select count(*) from public.apple_sales_daily where date = '2026-11-03') = 3, 'fout = niets veranderd');
-- lege dag mag (geen verkopen): alles van die dag weg
select public.bingr_apple_sales_put('2026-11-02', '[{"kind":"sale","product_id":"nl.lrvdlinden.bingr.lifetime","country":"BE","customer_currency":"EUR","proceeds_currency":"EUR","units":1,"customer_price":4.99,"developer_proceeds":3.5}]'::jsonb);
select pg_temp.ok(public.bingr_apple_sales_put('2026-11-02', '[]'::jsonb) = 0, 'lege dag: 0 rijen');
select pg_temp.ok(not exists (select 1 from public.apple_sales_daily where date = '2026-11-02'), 'lege dag: oude rij weg');

-- "bijgewerkt t/m" gaat nooit terug
select public.bingr_apple_sales_status_set('2026-11-05', '{"ok": 3}'::jsonb);
select public.bingr_apple_sales_status_set('2026-11-01', '{"ok": 1}'::jsonb);
select public.bingr_apple_sales_status_set(null, '{"ok": 0}'::jsonb);
select pg_temp.ok((select value->>'through' from public.app_settings where key = 'apple_sales_status') = '2026-11-05', 'through blijft 2026-11-05');
select pg_temp.ok((select value->'last_run'->>'ok' from public.app_settings where key = 'apple_sales_status') = '0', 'laatste ronde');

-- omrekenen: zonder koers telt USD niet mee en staat apart
select pg_temp.ok(public.bingr_apple_eur(4.99, 'eur', '{}'::jsonb) = 4.99, 'EUR blijft');
select pg_temp.ok(public.bingr_apple_eur(10, 'USD', '{"USD": 0.9}'::jsonb) = 9.0, 'USD met koers');
select pg_temp.ok(public.bingr_apple_eur(10, 'USD', '{"USD": "0.9"}'::jsonb) is null and public.bingr_apple_eur(10, 'JPY', '{"USD": 0.9}'::jsonb) is null, 'zonder geldige koers null');
create temp table r1 as select public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'all') s;
select pg_temp.ok((select (s->>'units')::int from r1) = 4 and (select (s->>'gross')::int from r1) = 1996 and (select (s->>'proceeds')::int from r1) = 1396, 'alleen EUR: 4 × 4,99 en 4 × 3,49');
select pg_temp.ok((select (s->>'refund_units')::int from r1) = 1 and (select (s->>'refunds')::int from r1) = 499 and (select (s->>'refund_proceeds')::int from r1) = 348, 'terugbetaling apart');
select pg_temp.ok((select s->'unconverted' from r1) = '[{"currency": "USD", "units": 2, "refund_units": 0}]'::jsonb, 'USD niet omgerekend');
update public.app_settings set value = '{"USD": 0.9}'::jsonb where key = 'fx_rates';
select pg_temp.ok((public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'all')->>'gross')::int = 1996 + 898, 'met koers: 2 × 4,99 × 0,9');
select pg_temp.ok(public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'all')->'unconverted' = '[]'::jsonb, 'alles omgerekend');
select pg_temp.ok((public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'test')->>'units')::int = 0, 'testmodus: geen Apple-rapport');
-- moment: 12:00 Nederlandse tijd van de rapportdag
select pg_temp.ok((select min(at) from public.bingr_apple_sales_rows('all')) = '2026-11-03 11:00:00+00', '12:00 NL-tijd (wintertijd)');
select pg_temp.ok((public.bingr_apple_sales_sum('2026-11-03 11:00+00', '2026-11-03 11:00:01+00', 'all')->>'units')::int = 6
  and (public.bingr_apple_sales_sum('2026-11-03 11:00:01+00', '2026-11-04', 'all')->>'units')::int = 0, 'grenzen [van, tot)');

-- gekoppeld aan een account (apple_verify, billing_purchases)
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-4000-8000-0000000000a1', 'apple1@example.invalid', now());
insert into public.billing_purchases (user_id, provider, apple_original_transaction_id, apple_transaction_id, environment, amount, currency, status, paid_at)
values ('00000000-0000-4000-8000-0000000000a1', 'apple', '3000000000000001', '3000000000000001', 'live', 499, 'eur', 'paid', '2026-11-03 10:00+00'),
       (null, 'apple', '3000000000000002', '3000000000000002', 'test', 499, 'eur', 'paid', '2026-11-03 10:00+00');
insert into public.billing_purchases (user_id, stripe_session_id, amount, currency, status, paid_at)
values ('00000000-0000-4000-8000-0000000000a1', 'cs_live_web1', 499, 'eur', 'paid', '2026-11-03 10:00+00');
select pg_temp.ok((public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'all')->>'linked')::int = 2, 'gekoppeld: alles');
select pg_temp.ok((public.bingr_apple_sales_sum('2026-11-01', '2026-11-08', 'live')->>'linked')::int = 1, 'gekoppeld: live');

-- website apart (modus web_*): geen Apple uit billing_purchases
select pg_temp.ok((public.bingr_revenue_sum('2026-11-01', '2026-11-08', 'all')->>'count')::int = 3, 'alles: website + Apple uit billing_purchases');
select pg_temp.ok((public.bingr_revenue_sum('2026-11-01', '2026-11-08', 'web_all')->>'count')::int = 1, 'web_all: alleen Stripe');
select pg_temp.ok((public.bingr_revenue_sum('2026-11-01', '2026-11-08', 'web_live')->>'count')::int = 1 and
  (public.bingr_revenue_sum('2026-11-01', '2026-11-08', 'web_test')->>'count')::int = 0, 'web_live / web_test');
select pg_temp.ok(public.bingr_admin_revenue(array['2026-11-01'::timestamptz, '2026-11-08'], 'web_all', '[]'::jsonb) is not null, 'bingr_admin_revenue kent web_all');
select pg_temp.ok(public.bingr_admin_revenue(array['2026-11-01'::timestamptz, '2026-11-08'], 'web_x', '[]'::jsonb) is null, 'onbekende modus');
select pg_temp.ok(jsonb_array_length(public.bingr_admin_revenue_rows('2026-11-01', '2026-11-08', 'web_all')) = 1, 'CSV web_all');

-- tab Omzet: series per tijdvak en bereiken
create temp table a1 as select public.bingr_admin_revenue_apple(array['2026-11-02'::timestamptz, '2026-11-03', '2026-11-04', '2026-11-05'], 'all',
  '[{"key": "period", "from": "2026-11-02", "to": "2026-11-05"}, {"key": "all", "from": "2020-01-01", "to": "2030-01-01"}]'::jsonb) v;
select pg_temp.ok((select v->'series'->'units' from a1) = '[0, 6, 0]'::jsonb, 'units per dag');
select pg_temp.ok((select v->'series'->'gross' from a1) = '[0, 2894, 0]'::jsonb, 'bruto per dag');
select pg_temp.ok((select v->'series'->'refunds' from a1) = '[0, 499, 0]'::jsonb, 'terugbetaald per dag');
select pg_temp.ok((select (v->'ranges'->'period'->>'units')::int from a1) = 6 and (select (v->'ranges'->'all'->>'gross')::int from a1) = 2894, 'bereiken');
select pg_temp.ok((select (v->>'commission')::numeric from a1) = 15 and (select v->'fx_rates' from a1) = '{"USD": 0.9}'::jsonb, 'commissie en koersen');
select pg_temp.ok((select v->'status'->>'through' from a1) = '2026-11-05' and (select (v->>'rows')::int from a1) = 3, 'stand');
select pg_temp.ok(public.bingr_admin_revenue_apple(array['2026-11-02'::timestamptz, '2026-11-01'], 'all', '[]'::jsonb) is null, 'grenzen niet oplopend');
select pg_temp.ok(public.bingr_admin_revenue_apple(array['2026-11-02'::timestamptz, '2026-11-03'], 'web_all', '[]'::jsonb) is null, 'alleen live/test/all');
select pg_temp.ok((select (public.bingr_admin_revenue_apple(array['2026-11-02'::timestamptz, '2026-11-05'], 'test', '[]'::jsonb))->'series'->'units') = '[0]'::jsonb, 'test: geen Apple');
-- CSV-rijen en totaal voor het overzicht
select pg_temp.ok(jsonb_array_length(public.bingr_admin_apple_sales_rows('2026-11-01', '2026-11-08', 'all')) = 3, 'CSV: drie rijen');
select pg_temp.ok((public.bingr_apple_sales_total()->>'cents')::int = 2894 - 499 and (public.bingr_apple_sales_total()->>'count')::int = 5, 'totaal: verkopen − terugbetalingen');
-- commissie instellen: alleen 0–50
update public.app_settings set value = '{"rate": 30}'::jsonb where key = 'apple_commission';
select pg_temp.ok(public.bingr_apple_commission() = 30, 'commissie 30%');
update public.app_settings set value = '{"rate": 80}'::jsonb where key = 'apple_commission';
select pg_temp.ok(public.bingr_apple_commission() = 15, 'ongeldig = 15');

-- rechten: alleen de service role
select pg_temp.ok(not has_table_privilege('anon', 'public.apple_sales_daily', 'select') and not has_table_privilege('authenticated', 'public.apple_sales_daily', 'select')
  and not has_table_privilege('authenticated', 'public.apple_sales_daily', 'insert'), 'tabel dicht voor anon en authenticated');
select pg_temp.ok((select relrowsecurity from pg_class where oid = 'public.apple_sales_daily'::regclass), 'RLS aan');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.bingr_apple_sales_put(date, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.bingr_admin_revenue_apple(timestamptz[], text, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.bingr_apple_sales_status_set(date, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.bingr_apple_sales_put(date, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.bingr_admin_revenue_apple(timestamptz[], text, jsonb)', 'execute'), 'functies alleen service role');
select pg_temp.ok(not has_function_privilege('service_role', 'public.bingr_apple_sales_rows(text)', 'execute'), 'interne hulpfunctie dicht');
-- geen persoonsgegevens: de tabel heeft geen kolom voor account, e-mail of transactie
select pg_temp.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'apple_sales_daily'
  and column_name ~ '(user|email|mail|name|transaction|account)'), 'geen persoonsgegevens');
