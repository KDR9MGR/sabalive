-- Down script for supabase/migrations/20261106120000_vip_products.sql
-- Applied BY HAND only. Removes the VIP products feature: the five functions and the three tables (so every product, benefit and every person's VIP ownership is DELETED).
-- It can NOT undo: coins people already paid for a VIP (those ledger rows stay; refund by hand if needed) and Store items that were given to buyers (they stay in
-- the buyers' Bags until their own end date). An app that already has the VIP screen would show "try again" on it until the migration is applied again.
begin;
set local lock_timeout = '5s';
drop function if exists public.purchase_vip_product(uuid);
drop function if exists public.vip_grant_items(uuid, uuid, timestamptz);
drop function if exists public.admin_delete_vip_product(uuid);
drop function if exists public.admin_save_vip_product(uuid, text, text, text, integer, integer, text, integer, jsonb);
drop table if exists public.user_vip;
drop table if exists public.vip_product_benefits;
drop table if exists public.vip_products;
commit;
