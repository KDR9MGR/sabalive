-- CRITICAL SECURITY FIX: is_admin_or_above() and manages_agency() return
-- NULL (not false) for a non-staff user, because current_staff_role() is
-- NULL for them and `NULL IN (...)` is NULL in SQL, not false. Every
-- caller across the schema does `if not is_admin_or_above() then raise
-- exception ... end if` (or the manages_agency equivalent) — and
-- PL/pgSQL's documented behavior is that `IF NULL THEN` is treated as
-- false, so the exception silently never fires. Any authenticated
-- non-staff user could call every one of these "admin-only" functions and
-- the authorization check would do nothing.
--
-- Found 2026-09-30 while testing the new decide_live_request() RPC: a
-- plain host was able to approve their own go-live request. Confirmed via
-- a direct query that is_admin_or_above()/manages_agency() return NULL
-- (not false) for a non-staff auth.uid(). At least 18 call sites across
-- 20260905090200_economy.sql, 20260905090700_status_assignments_transfers.sql,
-- 20260908090000_decide_kyc.sql, 20260908090200_broadcast_notification.sql,
-- 20260909090000_host_codes.sql, 20260909100000_reseller_codes.sql, and
-- 20260909110000_capability_permissions.sql share this exact pattern.
--
-- Fixed at the root instead of patching every call site: wrapping these
-- two functions' own return values in coalesce(..., false) makes them
-- NEVER return NULL, which correctly makes every existing `if not (...)`
-- check downstream raise its exception for a non-staff/non-manager caller,
-- with no changes needed to any of those other files. RLS policies using
-- these functions were never actually at risk the same way — Postgres RLS
-- treats a NULL USING/WITH CHECK expression as "deny", which is already
-- the safe default — this was specifically a PL/pgSQL `IF` pitfall.
create or replace function public.is_admin_or_above()
returns boolean language sql stable
as $$ select coalesce(public.current_staff_role() in ('super_admin', 'admin'), false); $$;

create or replace function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable
as $$
  select coalesce(
    public.is_admin_or_above()
      or (public.current_staff_role() in ('agency_manager', 'sub_admin')
          and public.current_agency_id() = target_agency_id),
    false
  );
$$;
