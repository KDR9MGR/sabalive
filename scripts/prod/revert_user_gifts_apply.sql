-- WRITES. Run only through scripts/prod/revert_user_gifts.sh --apply (placeholders __DISPLAY_ID__, __FROM__, __TO__ are replaced by the script).
-- Undoes every gift one person SENT or RECEIVED in a time window, so the database looks as if those gifts were never sent (what and how: revert_user_gifts_plan.sql).
--
--   * One transaction: any blocker or error and NOTHING is kept. The blockers are the plan's: no gifts, a ledger row that does not match a gift exactly, a receiver who no longer
--     holds the diamonds (a wallet cannot go below 0), XP that would go below 0.
--   * The row-by-row triggers are switched off for THIS transaction only (`set local session_replication_role = replica`: it ends with the transaction): the XP triggers fire on
--     INSERT only, the wallet trigger fires on ledger INSERT only, so deleting rows does not move anything by itself; every number is moved here, once, by exactly the gift amounts.
--   * It returns `report`: what was done plus `pack`, everything that was removed (the gift rows, their ledger rows, the per-account amounts, the live totals). The script saves
--     the pack in a private file; revert_user_gifts_undo.sql puts it all back from that file.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local session_replication_role = replica;

create temp table _t on commit drop as
  select id from public.profiles where display_id = __DISPLAY_ID__ and not coalesce(is_ghost, false);
do $$
begin
  if (select count(*) from _t) <> 1 then
    raise exception 'revert_user_gifts: User ID __DISPLAY_ID__ was not found (or it is a monitoring account). Nothing was changed.';
  end if;
end $$;

create temp table _g on commit drop as
  select gt.id, gt.sender_id, gt.receiver_id, gt.coins, gt.created_at, gt.live_stream_id
    from public.gift_transactions gt, _t
   where gt.created_at >= timestamptz '__FROM__' and gt.created_at < timestamptz '__TO__'
     and (gt.sender_id = _t.id or gt.receiver_id = _t.id);
do $$
begin
  if (select count(*) from _g) = 0 then
    raise exception 'revert_user_gifts: no gifts of User ID __DISPLAY_ID__ between __FROM__ and __TO__. Nothing was changed.';
  end if;
end $$;

-- the two ledger rows of every gift (person + amount + moment; identical rows are interchangeable, so the first n of each kind are taken)
create temp table _ls on commit drop as
  select id from (
    select l.id, row_number() over (partition by l.profile_id, l.amount, l.created_at order by l.id) as rn, k.n
      from public.wallet_ledger l
      join (select sender_id as profile_id, -coins as amount, created_at, count(*) as n from _g group by 1, 2, 3) k
        on k.profile_id = l.profile_id and k.amount = l.amount and k.created_at = l.created_at
     where l.kind = 'gift_sent' and l.currency = 'coins') s
   where rn <= n;
create temp table _lr on commit drop as
  select id from (
    select l.id, row_number() over (partition by l.profile_id, l.amount, l.created_at order by l.id) as rn, k.n
      from public.wallet_ledger l
      join (select receiver_id as profile_id, coins as amount, created_at, count(*) as n from _g group by 1, 2, 3) k
        on k.profile_id = l.profile_id and k.amount = l.amount and k.created_at = l.created_at
     where l.kind = 'gift_received' and l.currency = 'diamonds') s
   where rn <= n;

-- what each person gets back / loses; xp is the combined xp (the trigger adds a gift once to the sender and once to the receiver, once if they are the same person)
create temp table _acc on commit drop as
  select a.pid, a.coins_back, a.diamonds_out, coalesce(x.xp, 0) as xp, a.wealth, a.charm
    from (select pid, sum(coins_back) as coins_back, sum(diamonds_out) as diamonds_out, sum(wealth) as wealth, sum(charm) as charm
            from (select sender_id as pid, coins as coins_back, 0 as diamonds_out, coins as wealth, 0 as charm from _g
                  union all select receiver_id, 0, coins, 0, coins from _g) y
           group by pid) a
    left join (select pid, sum(coins) as xp
                 from (select sender_id as pid, coins from _g union all select receiver_id, coins from _g where receiver_id <> sender_id) z
                group by pid) x on x.pid = a.pid;

do $$
declare
  v text;
begin
  if (select count(*) from _ls) <> (select count(*) from _g) then
    raise exception 'revert_user_gifts: % gift_sent ledger rows match % gifts. Nothing was changed.', (select count(*) from _ls), (select count(*) from _g);
  end if;
  if (select count(*) from _lr) <> (select count(*) from _g) then
    raise exception 'revert_user_gifts: % gift_received ledger rows match % gifts. Nothing was changed.', (select count(*) from _lr), (select count(*) from _g);
  end if;
  if (select count(*) from _acc a join public.wallets w on w.profile_id = a.pid join public.profiles p on p.id = a.pid) <> (select count(*) from _acc) then
    raise exception 'revert_user_gifts: a person in these gifts has no wallet or profile. Nothing was changed.';
  end if;

  -- lock the rows that will change, in a fixed order
  perform 1 from public.wallets w where w.profile_id in (select pid from _acc) order by w.profile_id for update;
  perform 1 from public.profiles p where p.id in (select pid from _acc) order by p.id for update;

  select string_agg('account ' || p.display_id || ' holds ' || w.diamonds || ' diamonds, needs ' || a.diamonds_out, '; ') into v
    from _acc a join public.wallets w on w.profile_id = a.pid join public.profiles p on p.id = a.pid where w.diamonds < a.diamonds_out;
  if v is not null then
    raise exception 'revert_user_gifts: %. Nothing was changed.', v;
  end if;
  select string_agg('account ' || p.display_id || ' has too little XP', '; ') into v
    from _acc a join public.profiles p on p.id = a.pid where p.xp < a.xp or p.wealth_xp < a.wealth or p.charm_xp < a.charm;
  if v is not null then
    raise exception 'revert_user_gifts: %. Nothing was changed.', v;
  end if;
end $$;

-- everything that is about to go, kept for the undo
create temp table _pack on commit drop as
  select jsonb_build_object(
    'target', __DISPLAY_ID__, 'from', '__FROM__', 'to', '__TO__',
    'gifts', (select coalesce(jsonb_agg(to_jsonb(gt) order by gt.created_at, gt.id), '[]'::jsonb) from public.gift_transactions gt where gt.id in (select id from _g)),
    'ledger', (select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at, l.id), '[]'::jsonb) from public.wallet_ledger l where l.id in (select id from _ls union all select id from _lr)),
    'deltas', (select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) from _acc a),
    'streams', (select coalesce(jsonb_agg(jsonb_build_object('live_stream_id', live_stream_id, 'coins', c)), '[]'::jsonb)
                  from (select live_stream_id, sum(coins) as c from _g where live_stream_id is not null group by live_stream_id) s)
  ) as p;

delete from public.wallet_ledger where id in (select id from _ls union all select id from _lr);
delete from public.gift_transactions where id in (select id from _g);

update public.wallets w
   set coins = w.coins + a.coins_back, diamonds = w.diamonds - a.diamonds_out, updated_at = now()
  from _acc a where w.profile_id = a.pid;

-- the levels follow the XP exactly as the award triggers work them out (combined: level_thresholds; wealth / charm: the panel's track_levels, level 1 when none is reached)
update public.profiles p set
  xp = p.xp - a.xp,
  level = coalesce((select max(level) from public.level_thresholds where xp_required <= p.xp - a.xp), 1),
  wealth_xp = p.wealth_xp - a.wealth,
  wealth_level = coalesce((select max(level) from public.track_levels where track = 'wealth' and xp_required <= p.wealth_xp - a.wealth), 1),
  charm_xp = p.charm_xp - a.charm,
  charm_level = coalesce((select max(level) from public.track_levels where track = 'charm' and xp_required <= p.charm_xp - a.charm), 1)
 from _acc a where p.id = a.pid;

update public.live_streams s set gift_coin_total = greatest(s.gift_coin_total - x.c, 0)
  from (select live_stream_id, sum(coins) as c from _g where live_stream_id is not null group by live_stream_id) x
 where s.id = x.live_stream_id;

insert into public.audit_logs (actor_id, action, target, severity)
  select null, 'gifts.reverted',
         'User ID __DISPLAY_ID__: ' || (select count(*) from _g) || ' gifts (' || (select sum(coins) from _g) || ' coins) between __FROM__ and __TO__ undone, '
           || (select count(*) from _acc) || ' accounts',
         'critical';

-- what was done, and the pack the undo needs (read before the commit: after it the rows are gone)
select jsonb_build_object(
  'gifts_undone', (select count(*) from _g),
  'coins', (select sum(coins) from _g),
  'accounts_changed', (select count(*) from _acc),
  'ledger_rows_removed', (select count(*) from _ls) + (select count(*) from _lr),
  'pack', (select p from _pack)
) as report;
commit;
