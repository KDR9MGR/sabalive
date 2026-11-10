-- The panel's Games page stopped loading (owner, 2026-11-10). Cause: game_transactions grew to 360k+ rows, and its read policy ("Staff read game transactions": using (is_admin_or_above()))
-- runs that function ONCE PER ROW, so every report that goes through the three monitoring views (security_invoker, so the policy applies) takes 5 to 11 seconds; the winner-gifting
-- one passed the 8 second statement timeout of signed-in users and failed. Without the per-row check the same queries take 0.3 to 0.5 seconds.
--
-- WHAT THIS DOES. Four NEW functions (new names, nothing existing is touched: no policy, view or table changes) that check the caller's role ONCE and then read the same views as
-- the function owner. The panel calls them and falls back to the old direct reads while they are missing.
--   admin_game_day_totals(p_days)        per player per day, the last p_days days            (game_player_day_totals)
--   admin_game_winner_gifting(p_limit)   players who won in games and gifted                  (game_winner_gifting)
--   admin_game_host_inflow(p_limit)      hosts whose gifts came partly from game winners      (game_host_inflow)
--   admin_game_transactions(p_limit)     the most recent game transactions with the player's name
-- Master and Super Admin only (is_admin_or_above()), exactly who could read these tables before. Rollback: supabase/rollbacks/20261110100000_down.sql.
set local lock_timeout = '5s';

create or replace function public.admin_game_day_totals(p_days integer default 14)
returns setof public.game_player_day_totals
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can read game reports' using errcode = '42501';
  end if;
  return query select * from public.game_player_day_totals where day >= current_date - greatest(1, least(coalesce(p_days, 14), 365));
end;
$$;

create or replace function public.admin_game_winner_gifting(p_limit integer default 100)
returns setof public.game_winner_gifting
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can read game reports' using errcode = '42501';
  end if;
  return query select * from public.game_winner_gifting order by day desc, gifted desc limit greatest(1, least(coalesce(p_limit, 100), 1000));
end;
$$;

create or replace function public.admin_game_host_inflow(p_limit integer default 100)
returns setof public.game_host_inflow
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can read game reports' using errcode = '42501';
  end if;
  return query select * from public.game_host_inflow where from_game_winners > 0 order by day desc, from_game_winners desc limit greatest(1, least(coalesce(p_limit, 100), 1000));
end;
$$;

-- one JSON row each, with the player's name and app User ID next to the transaction
create or replace function public.admin_game_transactions(p_limit integer default 200)
returns setof jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can read game reports' using errcode = '42501';
  end if;
  return query
    select to_jsonb(t) || jsonb_build_object('player_name', p.name, 'player_display_id', p.display_id)
      from (select * from public.game_transactions order by created_at desc limit greatest(1, least(coalesce(p_limit, 200), 1000))) t
      left join public.profiles p on p.id = t.profile_id
     order by t.created_at desc;
end;
$$;

revoke execute on function public.admin_game_day_totals(integer), public.admin_game_winner_gifting(integer), public.admin_game_host_inflow(integer), public.admin_game_transactions(integer) from public, anon;
grant execute on function public.admin_game_day_totals(integer), public.admin_game_winner_gifting(integer), public.admin_game_host_inflow(integer), public.admin_game_transactions(integer) to authenticated;
