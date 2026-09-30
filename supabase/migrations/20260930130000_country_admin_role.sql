-- Hierarchy stage 2, part 1: the Country Admin role. Added on its own because
-- Postgres won't let a new enum value be used in the transaction that adds it;
-- everything that uses it is in 20260930140000_country_admin_scope_and_cascade.sql.
alter type public.staff_role add value if not exists 'country_admin';
