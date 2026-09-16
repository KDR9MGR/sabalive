-- Alpha: one shared demo host code so testers can unlock Go Live without an
-- agency issuing them one. Remove before production.
insert into public.host_codes (code, label, max_uses, expires_at)
values ('SABADEMO', 'Alpha demo code', 50, now() + interval '30 days')
on conflict (code) do nothing;
