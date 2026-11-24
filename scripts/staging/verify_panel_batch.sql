-- Exercises the 2026-11-24 panel batch on STAGING with the real grants, then rolls back. Run through scripts/staging/verify_panel_batch.sh.
--   20261124100000 agency photo, 20261124110000 diamond reset at 05:00 India time, 20261124120000 Lucky Box by month, and the Store lock on a non-frame item (20261031100000).
-- It builds its own hosts, wins, Country Admin, agency and Store item inside the transaction. Safe: ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  h1 uuid := gen_random_uuid(); h2 uuid := gen_random_uuid(); c1 uuid := gen_random_uuid();
  a1 uuid := gen_random_uuid(); item uuid := gen_random_uuid(); win2 uuid := gen_random_uuid();
  staff uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
  master uuid := (select user_id from public.staff_roles where role = 'admin' order by user_id limit 1);
begin
  if staff is null then
    insert into res(step, ok, info) values ('setup: a Super Admin exists on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (h1, 'authenticated', 'authenticated', 'zz-smoke-pb-h1@staging.sabalive.test', '{"name":"ZZ Host One","username":"zz_pb_h1"}'),
    (h2, 'authenticated', 'authenticated', 'zz-smoke-pb-h2@staging.sabalive.test', '{"name":"ZZ Host Two","username":"zz_pb_h2"}'),
    (c1, 'authenticated', 'authenticated', 'zz-smoke-pb-c1@staging.sabalive.test', '{"name":"ZZ Country One","username":"zz_pb_c1"}');
  insert into public.staff_roles (user_id, role) values (c1, 'country_admin');
  insert into public.agencies (id, name) values (a1, 'ZZ photo agency');
  insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values (item, 'entry_effect', 'ZZ lock test', '✨', 0, 7);
  -- wins: 23:59 IST on 31 Oct and 00:00 IST on 1 Nov for host one; host two has an October win that was pulled back in November
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at) values
    (h1, 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-31 18:29:00+00'),
    (h1, 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-31 18:30:00+00');
  insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
    values (win2, h2, 'grant', 'diamonds', 2000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-20 12:00:00+00');
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
    values (h2, 'grant_reversal', 'diamonds', -2000, 'wallet_ledger', win2, 'ZZ pulled back', '2026-11-03 09:00:00+00');
  insert into ids values ('staff', staff::text), ('master', coalesce(master::text, '')), ('h1', h1::text), ('h2', h2::text), ('c1', c1::text), ('a1', a1::text), ('item', item::text);
end
$$;

-- the 05:00 schedule (read as the owner: the cron table is not for app roles)
insert into res(step, ok, info)
  select '1 the automatic diamond reset job is scheduled at 05:00 India time (23:30 UTC)', exists (select 1 from cron.job where jobname = 'diamond-reset-auto' and schedule = '30 23 * * *'),
         (select schedule from cron.job where jobname = 'diamond-reset-auto');

set local role authenticated;
do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
  master uuid := nullif((select val from ids where k = 'master'), '')::uuid;
  c1 uuid := (select val::uuid from ids where k = 'c1');
  a1 uuid := (select val::uuid from ids where k = 'a1');
  item uuid := (select val::uuid from ids where k = 'item');
  n bigint; r record; t text;
begin
  if staff is null then return; end if;

  -- Lucky Box by month, as the Super Admin
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);
  select * into r from public.lucky_box_month_people('2026-10') where name = 'ZZ Host One';
  insert into res(step, ok, info) values ('2 October: the win at 23:59 IST on 31 Oct is October (1 win, 3000)', r.wins = 1 and r.diamonds = 3000, coalesce(r.wins::text, '-') || ' / ' || coalesce(r.diamonds::text, '-'));
  select * into r from public.lucky_box_month_people('2026-11') where name = 'ZZ Host One';
  insert into res(step, ok, info) values ('3 November: the win at 00:00 IST on 1 Nov is November (1 win, 3000)', r.wins = 1 and r.diamonds = 3000, coalesce(r.wins::text, '-') || ' / ' || coalesce(r.diamonds::text, '-'));
  select * into r from public.lucky_box_month_people('2026-10') where name = 'ZZ Host Two';
  insert into res(step, ok, info) values ('4 a win pulled back a month later is still shown in its own month as pulled back', r.wins = 1 and r.diamonds = 2000 and r.pulled_back_diamonds = 2000, coalesce(r.pulled_back_diamonds::text, '-'));
  select * into r from public.lucky_box_month_rewards('2026-10', (select display_id from public.profiles where id = (select val::uuid from ids where k = 'h2'))) limit 1;
  insert into res(step, ok, info) values ('5 one person by app User ID: the win, its exact time (20 Oct 17:30 IST) and the pulled-back mark',
    r.pulled_back is true and to_char(r.won_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') = '20 Oct 17:30', to_char(r.won_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'));

  -- the Store lock on an entry effect (not a frame), as the Super Admin
  update public.store_items set locked = true where id = item;
  insert into res(step, ok, info) values ('6 a Super Admin can lock an Entry Effect', (select locked from public.store_items where id = item), '');
  update public.store_items set locked = false where id = item;
  insert into res(step, ok, info) values ('7 ... and unlock it', not (select locked from public.store_items where id = item), '');

  -- the agency photo, as the Super Admin
  update public.agencies set avatar_url = 'https://example.test/agency.png' where id = a1;
  insert into res(step, ok, info) values ('8 a Super Admin can set an agency photo', (select avatar_url from public.agencies where id = a1) = 'https://example.test/agency.png', '');
  if master is not null then
    perform set_config('request.jwt.claim.sub', master::text, true);
    perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
    select count(*) into n from public.lucky_box_month_people('2026-10');
    insert into res(step, ok, info) values ('9 a Master can read the Lucky Box months', n >= 2, n::text);
    update public.store_items set locked = true where id = item;
    insert into res(step, ok, info) values ('10 a Master can lock a Store item', (select locked from public.store_items where id = item), '');
    update public.store_items set locked = false where id = item;
    update public.agencies set avatar_url = 'https://example.test/master.png' where id = a1;
    insert into res(step, ok, info) values ('11 a Master can change an agency photo', (select avatar_url from public.agencies where id = a1) = 'https://example.test/master.png', '');
  end if;

  -- a Country Admin: no Lucky Box, no lock, no agency photo
  perform set_config('request.jwt.claim.sub', c1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', c1), true);
  begin
    perform * from public.lucky_box_month_people('2026-10');
    insert into res(step, ok, info) values ('12 a Country Admin cannot read the Lucky Box months', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('12 a Country Admin cannot read the Lucky Box months', sqlerrm like 'Only a Master or Super Admin%', sqlerrm); end;
  begin
    update public.store_items set locked = true where id = item;
    get diagnostics n = row_count;
    insert into res(step, ok, info) values ('13 a Country Admin cannot lock a Store item', n = 0 and not (select locked from public.store_items where id = item), n::text);
  exception when others then insert into res(step, ok, info) values ('13 a Country Admin cannot lock a Store item', true, sqlerrm); end;
  update public.agencies set avatar_url = 'https://example.test/country.png' where id = a1;
  get diagnostics n = row_count;
  insert into res(step, ok, info) values ('14 a Country Admin cannot change an agency photo', n = 0, n::text);
end
$$;

select n, step, ok, info from res order by n;

rollback;
