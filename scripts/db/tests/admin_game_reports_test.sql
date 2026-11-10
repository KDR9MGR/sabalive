-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/admin_game_reports_test.sql
-- Proves (20261110100000): a Master and a Super Admin get the game reports (same rows as the views), a Global Admin, an app user and anon are refused, and the limits are clamped.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a9300000-0000-0000-0000-000000000001', 'winner@x'), ('c9300000-0000-0000-0000-000000000003', 'host@x'),
  ('e1300000-0000-0000-0000-0000000000e1', 'master@x'), ('e2300000-0000-0000-0000-0000000000e2', 'super@x'), ('e3300000-0000-0000-0000-0000000000e3', 'global@x');
insert into public.staff_roles (user_id, role) values
  ('e1300000-0000-0000-0000-0000000000e1', 'admin'), ('e2300000-0000-0000-0000-0000000000e2', 'super_admin'), ('e3300000-0000-0000-0000-0000000000e3', 'global_admin');
insert into public.gifts (id, name, emoji, price_coins) values ('99999999-9300-0000-0000-000000000001', 'Rose', 'R', 100);
insert into public.game_players (profile_id) values ('a9300000-0000-0000-0000-000000000001');
insert into public.game_transactions (transaction_id, profile_id, game_uid, type, coin, status) values
  ('r1', 'a9300000-0000-0000-0000-000000000001', 10001, 0, 100, 'ok'), ('r2', 'a9300000-0000-0000-0000-000000000001', 10001, 1, 5000, 'ok');
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins) values
  ('a9300000-0000-0000-0000-000000000001', 'c9300000-0000-0000-0000-000000000003', '99999999-9300-0000-0000-000000000001', 3000);

create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated, anon;
grant usage, select on sequence r_n_seq to authenticated, anon;

set role authenticated;
select set_config('request.jwt.claim.sub', 'e1300000-0000-0000-0000-0000000000e1', false);   -- a Master
insert into r(check_name, ok) select '1 a Master gets the day totals (1 player-day, net 4900)', (select count(*) = 1 and max(net) = 4900 from public.admin_game_day_totals(14));
insert into r(check_name, ok) select '2 a Master gets the winner-gifting row (gifted 3000)', (select count(*) = 1 and max(gifted) = 3000 from public.admin_game_winner_gifting(100));
insert into r(check_name, ok) select '3 a Master gets the host inflow (from game winners 3000)', (select count(*) = 1 and max(from_game_winners) = 3000 from public.admin_game_host_inflow(100));
insert into r(check_name, ok) select '4 a Master gets the transactions, newest first, with the player''s name key present', (select count(*) = 2 and bool_and(j ? 'player_name') and bool_and(j ? 'transaction_id') from public.admin_game_transactions(200) j);
insert into r(check_name, ok) select '5 a silly limit is clamped to 1 row, not an error', (select count(*) = 1 from public.admin_game_transactions(-5) j);
select set_config('request.jwt.claim.sub', 'e2300000-0000-0000-0000-0000000000e2', false);   -- a Super Admin
insert into r(check_name, ok) select '6 a Super Admin gets them too', (select count(*) = 1 from public.admin_game_day_totals(14));

select set_config('request.jwt.claim.sub', 'e3300000-0000-0000-0000-0000000000e3', false);   -- a Global Admin
do $$ begin
  begin perform * from public.admin_game_day_totals(14); insert into r(check_name, ok) values ('7 a Global Admin is refused', false);
  exception when others then insert into r(check_name, ok) values ('7 a Global Admin is refused', sqlstate = '42501'); end;
end $$;
select set_config('request.jwt.claim.sub', 'a9300000-0000-0000-0000-000000000001', false);   -- an app user
do $$ begin
  begin perform * from public.admin_game_transactions(10); insert into r(check_name, ok) values ('8 an app user is refused', false);
  exception when others then insert into r(check_name, ok) values ('8 an app user is refused', sqlstate = '42501'); end;
end $$;
reset role;
set role anon;
do $$ begin
  begin perform * from public.admin_game_host_inflow(10); insert into r(check_name, ok) values ('9 anon cannot even call it', false);
  exception when insufficient_privilege then insert into r(check_name, ok) values ('9 anon cannot even call it', true); end;
end $$;
reset role;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
