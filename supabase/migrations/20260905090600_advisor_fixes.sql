-- Cleanup pass driven by `supabase db advisors`:
--   1. Replace the 5 RLS-bypassing views with SECURITY DEFINER functions —
--      the sanctioned pattern (flagged ERROR as views, clean as functions).
--   2. Pin search_path on the handful of helper functions that were missing it.
--   3. Lock down EXECUTE: trigger-only functions need it from no one; the
--      gift/withdrawal RPCs need it from authenticated but not anon.
--   4. Add covering indexes for every unindexed foreign key.

drop view public.rankings_all_time;
drop view public.rankings_monthly;
drop view public.rankings_weekly;
drop view public.rankings_daily;
drop view public.rankings_top_gifters_monthly;

create function public.rankings_all_time()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  group by receiver_id
  order by score desc;
$$;

create function public.rankings_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('month', now())
  group by receiver_id
  order by score desc;
$$;

create function public.rankings_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('week', now())
  group by receiver_id
  order by score desc;
$$;

create function public.rankings_daily()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('day', now())
  group by receiver_id
  order by score desc;
$$;

create function public.rankings_top_gifters_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('month', now())
  group by sender_id
  order by score desc;
$$;

-- ------------------------------------------------------- search_path fixes
create or replace function public.is_super_admin()
returns boolean language sql stable set search_path = public
as $$ select public.current_staff_role() = 'super_admin'; $$;

create or replace function public.is_admin_or_above()
returns boolean language sql stable set search_path = public
as $$ select public.current_staff_role() in ('super_admin', 'admin'); $$;

create or replace function public.is_staff()
returns boolean language sql stable set search_path = public
as $$ select public.current_staff_role() is not null; $$;

create or replace function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable set search_path = public
as $$
  select public.is_admin_or_above()
    or (public.current_staff_role() in ('agency_manager', 'sub_admin')
        and public.current_agency_id() = target_agency_id);
$$;

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ------------------------------------------------------------- EXECUTE grants
-- Trigger-only functions: never meant to be called directly (Postgres would
-- refuse anyway — "trigger functions can only be called as triggers" — but
-- there's no reason to expose the RPC endpoint at all).
revoke execute on function public.apply_wallet_ledger_entry() from anon, authenticated;
revoke execute on function public.create_wallet_for_profile() from anon, authenticated;
revoke execute on function public.handle_coin_grant() from anon, authenticated;
revoke execute on function public.handle_coin_purchase_success() from anon, authenticated;
revoke execute on function public.handle_follow_change() from anon, authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated;
revoke execute on function public.notify_new_follower() from anon, authenticated;

-- Money-moving RPCs require a real signed-in user; block anonymous callers
-- at the grant level too (defense in depth on top of the auth.uid() check
-- already inside each function body).
revoke execute on function public.send_gift(uuid, uuid, uuid) from anon;
revoke execute on function public.request_withdrawal(integer) from anon;
revoke execute on function public.decide_withdrawal(uuid, boolean) from anon;

-- ------------------------------------------------------- FK covering indexes
create index agencies_manager_idx on public.agencies (manager_id);
create index audit_logs_actor_idx on public.audit_logs (actor_id);
create index coin_grants_granted_by_idx on public.coin_grants (granted_by);
create index coin_grants_granted_to_idx on public.coin_grants (granted_to);
create index coin_purchases_package_idx on public.coin_purchases (package_id);
create index coin_purchases_profile_idx on public.coin_purchases (profile_id);
create index conversation_participants_profile_idx on public.conversation_participants (profile_id);
create index conversations_created_by_idx on public.conversations (created_by);
create index dm_messages_gift_idx on public.dm_messages (gift_id);
create index dm_messages_sender_idx on public.dm_messages (sender_id);
create index follows_followee_idx on public.follows (followee_id);
create index gift_transactions_gift_idx on public.gift_transactions (gift_id);
create index gift_transactions_live_stream_idx on public.gift_transactions (live_stream_id);
create index gift_transactions_sender_idx on public.gift_transactions (sender_id);
create index host_applications_agency_idx on public.host_applications (agency_id);
create index host_applications_applicant_idx on public.host_applications (applicant_id);
create index host_applications_reviewed_by_idx on public.host_applications (reviewed_by);
create index host_profiles_agency_idx on public.host_profiles (agency_id);
create index kyc_verifications_profile_idx on public.kyc_verifications (profile_id);
create index kyc_verifications_reviewed_by_idx on public.kyc_verifications (reviewed_by);
create index live_chat_messages_sender_idx on public.live_chat_messages (sender_id);
create index live_requests_host_idx on public.live_requests (host_id);
create index live_requests_reviewed_by_idx on public.live_requests (reviewed_by);
create index live_stream_viewers_viewer_idx on public.live_stream_viewers (viewer_id);
create index pk_battles_stream_a_idx on public.pk_battles (stream_a_id);
create index pk_battles_stream_b_idx on public.pk_battles (stream_b_id);
create index salary_payments_agency_idx on public.salary_payments (agency_id);
create index staff_roles_agency_idx on public.staff_roles (agency_id);
create index user_badges_badge_idx on public.user_badges (badge_id);
create index user_frames_frame_idx on public.user_frames (frame_id);
create index withdrawals_processed_by_idx on public.withdrawals (processed_by);
create index withdrawals_profile_idx on public.withdrawals (profile_id);

grant execute on function
  public.rankings_all_time(),
  public.rankings_monthly(),
  public.rankings_weekly(),
  public.rankings_daily(),
  public.rankings_top_gifters_monthly()
to authenticated, anon;
