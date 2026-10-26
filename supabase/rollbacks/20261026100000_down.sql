-- Down script for supabase/migrations/20261026100000_country_admin_global_link.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes the trigger, both functions and staff_roles.global_admin_id (the links are lost: the Global Admin columns of the Salary exports go back to empty and
-- the Transfer Global page back to "Unassigned"; they can be rebuilt from the audit log by re-running the migration's back-fill). Nothing else reads the column.
begin;
set local lock_timeout = '5s';

drop trigger if exists audit_logs_link_country_admin on public.audit_logs;
drop function if exists public.link_new_country_admin_to_global();
drop function if exists public.transfer_country_admin(uuid, uuid);
alter table public.staff_roles drop column if exists global_admin_id;

commit;
