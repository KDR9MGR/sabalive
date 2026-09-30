-- Public-facing Agency ID, mirroring profiles.display_id
-- (20260924110000_display_id_gender_dob.sql). Starts at 20000 so it's
-- visually distinct from user display_ids (100000+).
create sequence if not exists public.agencies_display_id_seq start 20000 increment 1;

alter table public.agencies add column display_id bigint;
alter table public.agencies alter column display_id set default nextval('public.agencies_display_id_seq');
update public.agencies set display_id = nextval('public.agencies_display_id_seq') where display_id is null;
alter table public.agencies alter column display_id set not null;
alter table public.agencies add constraint agencies_display_id_key unique (display_id);

-- Agency-scoped staff (agency_manager / sub_admin) can see and decide
-- go-live requests filed by hosts in the one agency they manage, not just
-- platform admins. live_requests has no agency_id column of its own — a
-- request's agency is derived via host_profiles.agency_id, same as every
-- other agency-scoped table in this schema. Additive: the existing
-- "Hosts and staff see relevant requests" / "Admins review requests"
-- policies are untouched; Postgres RLS policies are OR'd together.
create policy "Agency staff see their hosts' live requests"
  on public.live_requests for select
  using (
    exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = live_requests.host_id
        and public.manages_agency(hp.agency_id)
    )
  );

create policy "Agency staff review their hosts' live requests"
  on public.live_requests for update
  using (
    exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = live_requests.host_id
        and public.manages_agency(hp.agency_id)
    )
  );
