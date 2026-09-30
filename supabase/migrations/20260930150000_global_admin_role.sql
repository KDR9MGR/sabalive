-- Hierarchy stage 3, part 1: the Global Admin role (Global > Country > Sub >
-- Agency). On its own because Postgres won't let a new enum value be used in
-- the transaction that adds it; everything that uses it is in
-- 20260930160000_global_admin_scope.sql.
alter type public.staff_role add value if not exists 'global_admin';
