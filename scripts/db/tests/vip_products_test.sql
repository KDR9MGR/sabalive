-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/vip_products_test.sql
-- Proves (20261106120000_vip_products): only a Master / Super Admin can create, change or delete a VIP product; a product is validated (price, days, status, benefits, pictures,
-- linked Store items); buying takes the coins, starts the days, and buying again ADDS days; the Store items linked to the product are given until the VIP's end and put on
-- only when nothing is on in that category; a hidden product, too few coins and a ghost are refused; what the app can read (active products and their benefits, who owns
-- what) and cannot (anon, inactive products, writes); deleting removes ownership. Every line ends in ok = t; the last line says ALL PASSED or how many failed.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'buyer@x'), ('a2000000-0000-0000-0000-000000000002', 'poor@x'), ('a3000000-0000-0000-0000-000000000003', 'ghost@x'),
  ('e1000000-0000-0000-0000-0000000000e1', 'master@x'), ('e2000000-0000-0000-0000-0000000000e2', 'super@x'), ('e3000000-0000-0000-0000-0000000000e3', 'global@x');
insert into public.staff_roles (user_id, role) values
  ('e1000000-0000-0000-0000-0000000000e1', 'admin'), ('e2000000-0000-0000-0000-0000000000e2', 'super_admin'), ('e3000000-0000-0000-0000-0000000000e3', 'global_admin');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'a3000000-0000-0000-0000-000000000003';
set session_replication_role = origin;
-- coins: the buyer has plenty, the poor one has 10, the ghost has plenty
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values
  ('a1000000-0000-0000-0000-000000000001', 'grant', 'coins', 10000000, 'test'),
  ('a2000000-0000-0000-0000-000000000002', 'grant', 'coins', 10, 'test'),
  ('a3000000-0000-0000-0000-000000000003', 'grant', 'coins', 10000000, 'test');
insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('51000000-0000-0000-0000-000000000001', 'frame', 'Crown Frame', 'f', 100, 7),
  ('52000000-0000-0000-0000-000000000002', 'entry_effect', 'Royal Entry', 'e', 100, 7),
  ('53000000-0000-0000-0000-000000000003', 'frame', 'Other Frame', 'f', 100, 7);
-- the buyer already wears Other Frame (so the VIP frame must NOT replace it), and has nothing on in entry effects
insert into public.user_items (profile_id, item_id, expires_at, equipped) values
  ('a1000000-0000-0000-0000-000000000001', '53000000-0000-0000-0000-000000000003', now() + interval '30 days', true);

create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated, anon;
grant usage, select on sequence r_n_seq to authenticated, anon;
create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.refused(sql text, expected text) returns boolean language plpgsql as $$
begin
  execute sql;
  return false;
exception when others then
  return sqlerrm like '%' || expected || '%';
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

-- ---------------------------------------------------------------- 1. who may manage
set role authenticated;
select set_config('request.jwt.claim.sub', 'e3000000-0000-0000-0000-0000000000e3', false);  -- a Global Admin
insert into r(check_name, ok) select '1 a Global Admin cannot create a VIP product',
  pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[]')$q$, 'Only a Master or Super Admin');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);  -- a plain user
insert into r(check_name, ok) select '1b a plain user cannot create one, change one or delete one',
  pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[]')$q$, 'Only a Master or Super Admin')
  and pg_temp.refused($q$select public.admin_delete_vip_product(gen_random_uuid())$q$, 'Only a Master or Super Admin');

-- ---------------------------------------------------------------- 2. a Master creates products
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
insert into ctx select 'vip1', public.admin_save_vip_product(null, 'VIP1', 'Start here', null, 1000, 30, 'active', 1, jsonb_build_array(
  jsonb_build_object('kind', 'identity', 'title', null),
  jsonb_build_object('kind', 'avatar_frame', 'link_item_id', '51000000-0000-0000-0000-000000000001'),
  jsonb_build_object('kind', 'entry_effect', 'link_item_id', '52000000-0000-0000-0000-000000000002'),
  jsonb_build_object('kind', 'anti_kick'),
  jsonb_build_object('kind', 'custom', 'title', 'Golden mic')))::text;
insert into ctx select 'vip_hidden', public.admin_save_vip_product(null, 'Hidden VIP', null, null, 500, 10, 'inactive', 9, '[]')::text;
insert into ctx select 'vip_cheap', public.admin_save_vip_product(null, 'Cheap VIP', null, null, 50, 5, 'active', 2, '[]')::text;
reset role;
insert into r(check_name, ok) select '2 a Master created three products; VIP1 has its five benefits in the order given',
  (select count(*) from public.vip_products) = 3
  and (select array_agg(kind order by sort_order) from public.vip_product_benefits where product_id = (select v::uuid from ctx where k = 'vip1')) = array['identity','avatar_frame','entry_effect','anti_kick','custom'];
insert into r(check_name, ok) select '2b every create was written to the audit log',
  (select count(*) from public.audit_logs where action = 'vip_product.create') = 3;

-- ---------------------------------------------------------------- 3. validation
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
insert into r(check_name, ok) select '3 bad input is refused: empty name, price 0, days 0 / 4000, bad status, long short line',
  pg_temp.refused($q$select public.admin_save_vip_product(null, '  ', null, null, 100, 30, 'active', 0, '[]')$q$, 'A VIP name')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 0, 30, 'active', 0, '[]')$q$, 'at least 1 coin')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 0, 'active', 0, '[]')$q$, 'days')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 4000, 'active', 0, '[]')$q$, 'days')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'maybe', 0, '[]')$q$, 'Status')
  and pg_temp.refused('select public.admin_save_vip_product(null, ''X'', ' || quote_literal(repeat('a', 121)) || ', null, 100, 30, ''active'', 0, ''[]'')', 'short line');
insert into r(check_name, ok) select '3b bad benefits are refused: custom without a title, the same fixed kind twice, a picture that is not an upload, a missing Store item, a Lucky ID link',
  pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[{"kind":"custom"}]')$q$, 'needs a title')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[{"kind":"anti_ban"},{"kind":"anti_ban"}]')$q$, 'twice')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[{"kind":"theme","image_url":"https://evil.example/x.png"}]')$q$, 'uploaded from the panel')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, 'https://evil.example/b.png', 100, 30, 'active', 0, '[]')$q$, 'uploaded from the panel')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[{"kind":"theme","link_item_id":"99999999-9999-9999-9999-999999999999"}]')$q$, 'no longer exists')
  and pg_temp.refused($q$select public.admin_save_vip_product(null, 'X', null, null, 100, 30, 'active', 0, '[{"kind":"Bad Kind!"}]')$q$, 'valid kind');
insert into r(check_name, ok) select '3c several custom benefits are allowed, and an upload address is accepted',
  (select public.admin_save_vip_product(null, 'Many', null, 'https://abc.supabase.co/storage/v1/object/public/gift-assets/vip/b.png', 100, 30, 'inactive', 50,
     '[{"kind":"custom","title":"A"},{"kind":"custom","title":"B","image_url":"https://abc.supabase.co/storage/v1/object/public/gift-assets/vip/x.png"}]')) is not null;
reset role;
delete from public.vip_products where name = 'Many';

-- ---------------------------------------------------------------- 3b. the owner's switch (app_config.feature_flags.vip_enabled, off by default)
select set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0000-0000000000e2', false);   -- only a Super Admin may change release controls
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) - 'vip_enabled';   -- (a later migration turns it on: start from off)
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
do $$
begin
  begin
    perform public.purchase_vip_product((select v::uuid from ctx where k = 'vip1'));
    insert into r(check_name, ok) values ('3b with the vip_enabled switch off a purchase is refused', false);
  exception when others then
    insert into r(check_name, ok) values ('3b with the vip_enabled switch off a purchase is refused ("VIP is coming soon")', sqlerrm = 'VIP is coming soon');
  end;
end $$;
reset role;
select set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0000-0000000000e2', false);   -- only a Super Admin may change release controls
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"vip_enabled": true}'::jsonb;
insert into r(check_name, ok) select '3b the switch is now on', coalesce((select feature_flags -> 'vip_enabled' = 'true'::jsonb from public.app_config where id), false);

-- ---------------------------------------------------------------- 4. buying
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
create temp table before_buy as select (select coins from public.wallets where profile_id = 'a1000000-0000-0000-0000-000000000001') as coins;
grant all on before_buy to authenticated;
insert into ctx select 'bought', (public.purchase_vip_product((select v::uuid from ctx where k = 'vip1')))::text;
reset role;
insert into r(check_name, ok) select '4 buying VIP1 took exactly 1000 coins and wrote a store_purchase ledger row',
  (select b.coins - w.coins from before_buy b, public.wallets w where w.profile_id = 'a1000000-0000-0000-0000-000000000001') = 1000
  and exists (select 1 from public.wallet_ledger where profile_id = 'a1000000-0000-0000-0000-000000000001' and kind = 'store_purchase' and amount = -1000 and reference_table = 'vip_products');
insert into r(check_name, ok) select '4b the VIP runs for 30 days from now, and the answer says so',
  (select expires_at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001') between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour'
  and ((select v::jsonb from ctx where k = 'bought') ->> 'price_coins')::int = 1000;
insert into r(check_name, ok) select '4c the linked entry effect was given until the VIP ends and PUT ON (nothing was on in that category)',
  (select (expires_at, equipped) from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '52000000-0000-0000-0000-000000000002')
    = ((select expires_at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001'), true);
insert into r(check_name, ok) select '4d the linked frame was given but NOT put on: the buyer already wears Other Frame, which stays on',
  (select equipped from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '51000000-0000-0000-0000-000000000001') = false
  and (select equipped from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '53000000-0000-0000-0000-000000000003') = true;

-- buying again while it runs ADDS the days
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
create temp table first_end as select expires_at as at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001';
grant all on first_end to authenticated;
select public.purchase_vip_product((select v::uuid from ctx where k = 'vip1'));
reset role;
insert into r(check_name, ok) select '5 buying again adds 30 days on top (60 days from the first purchase), one ownership row, and the item keeps the later end date',
  (select expires_at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001') = (select at + interval '30 days' from first_end)
  and (select count(*) from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001') = 1
  and (select count(*) from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '52000000-0000-0000-0000-000000000002') = 1
  and (select expires_at from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '52000000-0000-0000-0000-000000000002')
      = (select expires_at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001');

-- an EXPIRED VIP starts over from now (not from the old end date)
update public.user_vip set expires_at = now() - interval '2 days' where profile_id = 'a1000000-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
select public.purchase_vip_product((select v::uuid from ctx where k = 'vip1'));
reset role;
insert into r(check_name, ok) select '5b an expired VIP starts again from now, not from its old end date',
  (select expires_at from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001') between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour';

-- ---------------------------------------------------------------- 6. refusals
set role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', false);  -- 10 coins
insert into r(check_name, ok) select '6 too few coins is refused and nothing is taken',
  pg_temp.refused(format('select public.purchase_vip_product(%L)', (select v from ctx where k = 'vip_cheap')), 'Insufficient coins');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
insert into r(check_name, ok) select '6b a hidden (inactive) product cannot be bought, and neither can one that does not exist',
  pg_temp.refused(format('select public.purchase_vip_product(%L)', (select v from ctx where k = 'vip_hidden')), 'not available')
  and pg_temp.refused($q$select public.purchase_vip_product(gen_random_uuid())$q$, 'not available');
select set_config('request.jwt.claim.sub', 'a3000000-0000-0000-0000-000000000003', false);  -- the ghost
insert into r(check_name, ok) select '6c a ghost account cannot buy',
  pg_temp.refused(format('select public.purchase_vip_product(%L)', (select v from ctx where k = 'vip1')), 'cannot buy');
select set_config('request.jwt.claim.sub', '', false);
insert into r(check_name, ok) select '6d nobody signed in cannot buy',
  pg_temp.refused(format('select public.purchase_vip_product(%L)', (select v from ctx where k = 'vip1')), 'signed in');
reset role;
insert into r(check_name, ok) select '6e the poor buyer and the ghost still have their coins and no VIP',
  (select coins from public.wallets where profile_id = 'a2000000-0000-0000-0000-000000000002') = 10
  and (select coins from public.wallets where profile_id = 'a3000000-0000-0000-0000-000000000003') = 10000000
  and not exists (select 1 from public.user_vip where profile_id in ('a2000000-0000-0000-0000-000000000002', 'a3000000-0000-0000-0000-000000000003'));

-- ---------------------------------------------------------------- 7. what the app can read
set role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', false);
insert into r(check_name, ok) select '7 an app user sees the ACTIVE products only (VIP1 and Cheap VIP, not Hidden VIP) and VIP1''s five benefits',
  (select count(*) from public.vip_products) = 2
  and not exists (select 1 from public.vip_products where name = 'Hidden VIP')
  and (select count(*) from public.vip_product_benefits where product_id = (select v::uuid from ctx where k = 'vip1')) = 5;
insert into r(check_name, ok) select '7b who owns what is readable (the buyer''s row), but an app user cannot write any of the three tables',
  (select count(*) from public.user_vip) = 1
  and pg_temp.refused($q$insert into public.vip_products (name, price_coins, duration_days) values ('Sneaky', 1, 1)$q$, 'permission denied')
  and pg_temp.refused($q$update public.user_vip set expires_at = now() + interval '9 years'$q$, 'permission denied')
  and pg_temp.refused($q$delete from public.vip_product_benefits$q$, 'permission denied');
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
insert into r(check_name, ok) select '7c a Master also sees the hidden product',
  (select count(*) from public.vip_products) = 3;
reset role;
set role anon;
insert into r(check_name, ok) select '7d anon can read nothing and call nothing',
  pg_temp.refused($q$select count(*) from public.vip_products$q$, 'permission denied')
  and pg_temp.refused($q$select public.purchase_vip_product(gen_random_uuid())$q$, 'permission denied');
reset role;
insert into r(check_name, ok) select '7e the grant helper is not callable by app users',
  not has_function_privilege('authenticated', 'public.vip_grant_items(uuid, uuid, timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'public.purchase_vip_product(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.purchase_vip_product(uuid)', 'execute');

-- ---------------------------------------------------------------- 8. change and delete
set role authenticated;
select set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0000-0000000000e2', false);  -- a Super Admin
select public.admin_save_vip_product((select v::uuid from ctx where k = 'vip_cheap'), 'Cheaper VIP', 'now with words', null, 40, 7, 'active', 3,
  '[{"kind":"theme"},{"kind":"hide_country"}]');
reset role;
insert into r(check_name, ok) select '8 a Super Admin changed a product: name, price, days and the benefits were replaced',
  (select (name, price_coins, duration_days) from public.vip_products where id = (select v::uuid from ctx where k = 'vip_cheap')) = row('Cheaper VIP'::text, 40, 7)
  and (select array_agg(kind order by sort_order) from public.vip_product_benefits where product_id = (select v::uuid from ctx where k = 'vip_cheap')) = array['theme', 'hide_country'];
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
insert into ctx select 'owners', public.admin_delete_vip_product((select v::uuid from ctx where k = 'vip1'))::text;
reset role;
insert into r(check_name, ok) select '8b deleting VIP1 reports its 1 active owner, removes the product, its benefits and the ownership, and keeps the items already given',
  (select v from ctx where k = 'owners') = '1'
  and not exists (select 1 from public.vip_products where name = 'VIP1')
  and not exists (select 1 from public.vip_product_benefits where product_id = (select v::uuid from ctx where k = 'vip1'))
  and not exists (select 1 from public.user_vip where profile_id = 'a1000000-0000-0000-0000-000000000001')
  and exists (select 1 from public.user_items where profile_id = 'a1000000-0000-0000-0000-000000000001' and item_id = '52000000-0000-0000-0000-000000000002');
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
insert into ctx select 'linked', public.admin_save_vip_product(null, 'Linked VIP', null, null, 100, 30, 'active', 5, '[{"kind":"theme","link_item_id":"53000000-0000-0000-0000-000000000003"}]')::text;
reset role;
delete from public.store_items where id = '53000000-0000-0000-0000-000000000003';
insert into r(check_name, ok) select '8c deleting a Store item that a product links to does not break the product: the benefit stays and its link goes empty',
  exists (select 1 from public.vip_products where id = (select v::uuid from ctx where k = 'linked'))
  and (select count(*) from public.vip_product_benefits where product_id = (select v::uuid from ctx where k = 'linked') and link_item_id is null and kind = 'theme') = 1;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
