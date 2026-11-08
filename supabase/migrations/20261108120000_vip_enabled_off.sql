-- Turns the VIP switch OFF again (owner, 2026-11-08: "make vip coming soon"): app_config.feature_flags.vip_enabled = false.
-- Off means "VIP is coming soon" in the app and purchase_vip_product refuses. Same switch as the panel's Release Settings -> "VIP products"; the other flags are kept.
update public.app_config
   set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"vip_enabled": false}'::jsonb
 where id;
