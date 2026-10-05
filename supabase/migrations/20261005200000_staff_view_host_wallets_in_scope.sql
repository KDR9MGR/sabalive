-- The Agency, Sub Admin and Country Admin panels list their hosts' coins and
-- diamonds (host lists, earnings, dashboards), but wallets could only be read by
-- the owner, Master/Super Admin and Global Admin — so for everyone else those
-- figures silently came back as 0. Let a staff member read the wallet of a HOST
-- in an agency they manage (manages_agency() is the same scope rule that already
-- governs those hosts). Nobody gains access to non-host users' wallets.
drop policy if exists "Staff view wallets of hosts in their scope" on public.wallets;
create policy "Staff view wallets of hosts in their scope"
  on public.wallets for select
  using (exists (
    select 1 from public.host_profiles h
     where h.profile_id = wallets.profile_id
       and public.manages_agency(h.agency_id)
  ));
