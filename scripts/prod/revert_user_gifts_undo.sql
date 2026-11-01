-- WRITES. Run only through scripts/prod/revert_user_gifts.sh --undo <pack file>. The placeholder __PACK__ is replaced by the script with the JSON that --apply saved.
-- Puts back exactly what revert_user_gifts_apply.sql removed: the gift rows and their ledger rows (same ids and times), the coins and diamonds, the XP (levels worked out again),
-- the live totals. Amounts are put back as DIFFERENCES, not as old absolute values, so anything that happened to the wallets since stays.
--   * One transaction. Refused (nothing kept) if any of the gifts is already back, or if a person no longer has the coins that were refunded (a wallet cannot go below 0).
--   * Triggers off for this transaction only, for the same reason as in the apply: the rows come back without the XP / wallet triggers adding a second time.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local session_replication_role = replica;

create temp table _p on commit drop as select $pack$__PACK__$pack$::jsonb as p;
do $$
begin
  if (select jsonb_array_length(p -> 'gifts') from _p) = 0 then
    raise exception 'revert_user_gifts undo: the pack has no gifts. Nothing was changed.';
  end if;
  if exists (select 1 from public.gift_transactions where id in (select (e ->> 'id')::uuid from _p, jsonb_array_elements(p -> 'gifts') e)) then
    raise exception 'revert_user_gifts undo: some of these gifts are already back. Nothing was changed.';
  end if;
  if exists (select 1 from public.wallet_ledger where id in (select (e ->> 'id')::uuid from _p, jsonb_array_elements(p -> 'ledger') e)) then
    raise exception 'revert_user_gifts undo: some of these ledger rows are already back. Nothing was changed.';
  end if;
end $$;

create temp table _d on commit drop as
  select (e ->> 'pid')::uuid as pid, (e ->> 'coins_back')::bigint as coins_back, (e ->> 'diamonds_out')::bigint as diamonds_out,
         (e ->> 'xp')::bigint as xp, (e ->> 'wealth')::bigint as wealth, (e ->> 'charm')::bigint as charm
    from _p, jsonb_array_elements(p -> 'deltas') e;

do $$
begin
  perform 1 from public.wallets w where w.profile_id in (select pid from _d) order by w.profile_id for update;
  perform 1 from public.profiles p where p.id in (select pid from _d) order by p.id for update;
end $$;

insert into public.gift_transactions select * from jsonb_populate_recordset(null::public.gift_transactions, (select p -> 'gifts' from _p));
insert into public.wallet_ledger select * from jsonb_populate_recordset(null::public.wallet_ledger, (select p -> 'ledger' from _p));

update public.wallets w
   set coins = w.coins - d.coins_back, diamonds = w.diamonds + d.diamonds_out, updated_at = now()
  from _d d where w.profile_id = d.pid;

update public.profiles p set
  xp = p.xp + d.xp,
  level = coalesce((select max(level) from public.level_thresholds where xp_required <= p.xp + d.xp), 1),
  wealth_xp = p.wealth_xp + d.wealth,
  wealth_level = coalesce((select max(level) from public.track_levels where track = 'wealth' and xp_required <= p.wealth_xp + d.wealth), 1),
  charm_xp = p.charm_xp + d.charm,
  charm_level = coalesce((select max(level) from public.track_levels where track = 'charm' and xp_required <= p.charm_xp + d.charm), 1)
 from _d d where p.id = d.pid;

update public.live_streams s set gift_coin_total = s.gift_coin_total + x.c
  from (select (e ->> 'live_stream_id')::uuid as id, (e ->> 'coins')::bigint as c from _p, jsonb_array_elements(p -> 'streams') e) x
 where s.id = x.id;

insert into public.audit_logs (actor_id, action, target, severity)
  select null, 'gifts.revert_undone',
         'User ID ' || (p ->> 'target') || ': ' || jsonb_array_length(p -> 'gifts') || ' gifts put back (window ' || (p ->> 'from') || ' to ' || (p ->> 'to') || ')',
         'critical'
    from _p;

select jsonb_build_object('gifts_restored', (select jsonb_array_length(p -> 'gifts') from _p),
                          'ledger_rows_restored', (select jsonb_array_length(p -> 'ledger') from _p),
                          'accounts_changed', (select count(*) from _d)) as report;
commit;
