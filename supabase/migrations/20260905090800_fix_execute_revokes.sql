-- The previous migration's `revoke execute ... from anon, authenticated`
-- didn't actually close anything: Postgres grants EXECUTE to the PUBLIC
-- pseudo-role by default on function creation, and every role (including
-- anon/authenticated) implicitly inherits PUBLIC's privileges. Revoking from
-- a named role only removes an *explicit* grant to that role — it does
-- nothing about access coming through PUBLIC. The fix is to revoke from
-- PUBLIC itself, then explicitly re-grant to authenticated where intended.

revoke execute on function public.apply_wallet_ledger_entry() from public;
revoke execute on function public.create_wallet_for_profile() from public;
revoke execute on function public.handle_coin_grant() from public;
revoke execute on function public.handle_coin_purchase_success() from public;
revoke execute on function public.handle_follow_change() from public;
revoke execute on function public.handle_new_user() from public;
revoke execute on function public.notify_new_follower() from public;
revoke execute on function public.set_updated_at() from public;

revoke execute on function public.send_gift(uuid, uuid, uuid) from public;
grant execute on function public.send_gift(uuid, uuid, uuid) to authenticated;

revoke execute on function public.request_withdrawal(integer) from public;
grant execute on function public.request_withdrawal(integer) to authenticated;

revoke execute on function public.decide_withdrawal(uuid, boolean) from public;
grant execute on function public.decide_withdrawal(uuid, boolean) to authenticated;

revoke execute on function public.decide_transfer_request(uuid, boolean) from public;
grant execute on function public.decide_transfer_request(uuid, boolean) to authenticated;

revoke execute on function public.set_profile_status(uuid, text) from public;
grant execute on function public.set_profile_status(uuid, text) to authenticated;
