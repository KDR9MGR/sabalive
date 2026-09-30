-- Global Admin's "all users" list shows each user's coin balance, like the
-- Master/Admin list. wallets is readable only by its owner and by
-- is_admin_or_above(), so a Global Admin would otherwise see 0 for everyone.
-- Read-only and additive; nothing else about wallets changes (writes still go
-- only through the ledger trigger).
create policy "Global admins view wallets"
  on public.wallets for select
  using (public.current_staff_role() = 'global_admin');
