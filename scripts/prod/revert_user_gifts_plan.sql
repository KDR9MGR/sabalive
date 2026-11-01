-- READ-ONLY. What scripts/prod/revert_user_gifts.sh would undo for one person in one time window (placeholders __DISPLAY_ID__, __FROM__ and __TO__ are replaced by the script:
-- digits, and two timestamps like 2026-11-01 20:30:00+00). Writes nothing.
--
-- A GIFT is one gift_transactions row. "Undoing" it makes the database look as if it was never sent: the sender gets the coins back, the receiver loses the diamonds, the gift row and
-- its two wallet_ledger rows are gone (so rankings, Salary and the diamond reset no longer count it), wealth / charm / combined XP and the levels they give are lowered by the same
-- amount, and the live's gift total is lowered. The gifts in the window are every gift the person SENT or RECEIVED in it.
-- The ledger rows are not linked to the gift row by id, so they are matched by person, amount and moment (send_gift writes the gift row and both ledger rows in ONE transaction, so
-- they share created_at). Anything that does not match exactly is a BLOCKER and the apply refuses to run; so is a receiver who no longer holds the diamonds (a wallet cannot go below 0).
-- The same rules are in revert_user_gifts_apply.sql; scripts/db/tests/revert_user_gifts_test.sql proves the two agree.
with t as (
  select id, coalesce(is_ghost, false) as ghost from public.profiles where display_id = __DISPLAY_ID__
),
g as (
  select gt.id, gt.sender_id, gt.receiver_id, gt.coins, gt.created_at, gt.live_stream_id
    from public.gift_transactions gt, t
   where gt.created_at >= timestamptz '__FROM__' and gt.created_at < timestamptz '__TO__'
     and (gt.sender_id = t.id or gt.receiver_id = t.id)
),
sk as (select sender_id as profile_id, -coins as amount, created_at, count(*) as n from g group by 1, 2, 3),
rk as (select receiver_id as profile_id, coins as amount, created_at, count(*) as n from g group by 1, 2, 3),
ls as (
  select l.id, row_number() over (partition by l.profile_id, l.amount, l.created_at order by l.id) as rn, k.n
    from public.wallet_ledger l
    join sk k on k.profile_id = l.profile_id and k.amount = l.amount and k.created_at = l.created_at
   where l.kind = 'gift_sent' and l.currency = 'coins'
),
lr as (
  select l.id, row_number() over (partition by l.profile_id, l.amount, l.created_at order by l.id) as rn, k.n
    from public.wallet_ledger l
    join rk k on k.profile_id = l.profile_id and k.amount = l.amount and k.created_at = l.created_at
   where l.kind = 'gift_received' and l.currency = 'diamonds'
),
xpd as (
  select pid, sum(coins) as xp
    from (select sender_id as pid, coins from g union all select receiver_id, coins from g where receiver_id <> sender_id) x
   group by pid
),
acc as (
  select pid, sum(coins_back) as coins_back, sum(diamonds_out) as diamonds_out, sum(wealth) as wealth, sum(charm) as charm
    from (select sender_id as pid, coins as coins_back, 0 as diamonds_out, coins as wealth, 0 as charm from g
          union all select receiver_id, 0, coins, 0, coins from g) x
   group by pid
),
detail as (
  select p.display_id, a.coins_back, a.diamonds_out, coalesce(x.xp, 0) as xp, a.wealth, a.charm,
         w.coins as coins_now, w.diamonds as diamonds_now, p.xp as xp_now, p.wealth_xp as wealth_xp_now, p.charm_xp as charm_xp_now
    from acc a
    join public.profiles p on p.id = a.pid
    join public.wallets w on w.profile_id = a.pid
    left join xpd x on x.pid = a.pid
),
blockers as (
  select 'person not found' as why where (select count(*) from t) <> 1
  union all select 'person is a monitoring account' where exists (select 1 from t where ghost)
  union all select 'no gifts in this window' where not exists (select 1 from g)
  union all select 'gift_sent ledger rows found ' || (select count(*) from ls where rn <= n) || ', gifts ' || (select count(*) from g)
    where (select count(*) from ls where rn <= n) <> (select count(*) from g)
  union all select 'gift_received ledger rows found ' || (select count(*) from lr where rn <= n) || ', gifts ' || (select count(*) from g)
    where (select count(*) from lr where rn <= n) <> (select count(*) from g)
  union all select 'a person in these gifts has no wallet or profile' where (select count(*) from acc) <> (select count(*) from detail)
  union all select 'account ' || display_id || ' holds ' || diamonds_now || ' diamonds, needs ' || diamonds_out from detail where diamonds_now < diamonds_out
  union all select 'account ' || display_id || ' has too little XP (' || xp_now || ' / ' || wealth_xp_now || ' / ' || charm_xp_now || ' against ' || xp || ' / ' || wealth || ' / ' || charm || ')'
    from detail where xp_now < xp or wealth_xp_now < wealth or charm_xp_now < charm
)
select jsonb_build_object(
  'target_found', (select count(*) from t),
  'target_is_ghost', (select count(*) from t where ghost),
  'gifts', (select count(*) from g),
  'coins', (select coalesce(sum(coins), 0) from g),
  'sent_by_target', (select count(*) from g, t where g.sender_id = t.id),
  'received_by_target', (select count(*) from g, t where g.receiver_id = t.id),
  'self_gifts', (select count(*) from g where sender_id = receiver_id),
  'first_gift_at', (select min(created_at) from g),
  'last_gift_at', (select max(created_at) from g),
  'ledger_sent_matched', (select count(*) from ls where rn <= n),
  'ledger_received_matched', (select count(*) from lr where rn <= n),
  'streams', (select count(distinct live_stream_id) from g),
  'accounts', (select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', display_id, 'coins_back', coins_back, 'diamonds_out', diamonds_out, 'diamonds_now', diamonds_now, 'coins_now', coins_now)
        order by diamonds_out desc, coins_back desc, display_id), '[]'::jsonb) from detail),
  'blockers', (select coalesce(jsonb_agg(why), '[]'::jsonb) from blockers)
) as plan;
