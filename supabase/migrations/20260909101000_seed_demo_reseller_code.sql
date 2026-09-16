-- Alpha: shared demo reseller code so testers can try the coin-selling tool.
-- Remove before production.
insert into public.reseller_codes (code, label, max_uses, expires_at)
values ('RESELL01', 'Alpha demo reseller code', 50, now() + interval '30 days')
on conflict (code) do nothing;

delete from public.reseller_codes where label = 'selftest';
