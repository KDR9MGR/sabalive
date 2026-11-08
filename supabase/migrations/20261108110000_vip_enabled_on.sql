-- Turns the VIP switch ON (owner, 2026-11-08: "apply the VIP migration and turn on the switch"): app_config.feature_flags.vip_enabled = true.
-- It is the same switch as the panel's Release Settings -> "VIP products"; the other flags are kept as they are. Builds that do not know the switch ignore it.
-- The release-controls guard writes the usual 'app_release.changed' audit row.
update public.app_config
   set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"vip_enabled": true}'::jsonb
 where id;
