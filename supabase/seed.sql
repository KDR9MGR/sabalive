-- Reference/catalog data. Safe to re-run against a fresh database; not safe
-- to re-run against one that already has these rows (no upsert guards, kept
-- simple since this only runs once per environment).

insert into public.gifts (name, emoji, price_coins, category, has_effect, sort_order) values
  ('Rose', '🌹', 10, 'basic', false, 1),
  ('Heart', '💖', 20, 'basic', false, 2),
  ('Fire', '🔥', 50, 'basic', false, 3),
  ('Diamond', '💎', 100, 'luxury', false, 4),
  ('Crown', '👑', 200, 'luxury', false, 5),
  ('Car', '🚗', 500, 'vehicle', true, 6),
  ('Rocket', '🚀', 1000, 'special', true, 7),
  ('Yacht', '🛥️', 2000, 'vehicle', true, 8),
  ('Unicorn', '🦄', 3000, 'special', true, 9),
  ('Castle', '🏰', 5000, 'luxury', true, 10),
  ('Galaxy', '🌌', 8000, 'special', true, 11),
  ('Phoenix', '🦅', 12000, 'special', true, 12);

insert into public.coin_packages (name, coins, bonus_coins, price_inr, platform, sort_order) values
  ('Starter', 100, 0, 99, 'all', 1),
  ('Popular', 550, 50, 499, 'all', 2),
  ('Value', 1180, 180, 999, 'all', 3),
  ('Pro', 2500, 500, 1999, 'all', 4),
  ('Elite', 6000, 1500, 4499, 'all', 5),
  ('Whale', 12000, 3500, 8999, 'all', 6);

insert into public.badges (name, emoji, criteria, sort_order) values
  ('Newcomer', '🌱', 'Join the platform', 1),
  ('Rising Star', '⭐', '1,000 followers', 2),
  ('Top Gifter', '🎁', '50,000 coins gifted', 3),
  ('Streak Master', '🔥', '30-day live streak', 4),
  ('Verified', '✔️', 'KYC + review', 5),
  ('Legend', '👑', 'Top 100 all-time', 6),
  ('Event Winner', '🏆', 'Win any event', 7),
  ('Party Host', '🎉', 'Host 20 parties', 8);

insert into public.frames (name, emoji, unlock_type, unlock_value, price_coins, sort_order) values
  ('Golden Ring', '💫', 'free', 0, 0, 1),
  ('Neon Pulse', '🌀', 'level', 10, 0, 2),
  ('Sakura', '🌸', 'level', 25, 0, 3),
  ('Galaxy', '🌌', 'vip', 0, 0, 4),
  ('Flame', '🔥', 'coins', 0, 500, 5),
  ('Diamond Edge', '💎', 'coins', 0, 1000, 6),
  ('Royal Crown', '👑', 'vip', 0, 0, 7),
  ('Aurora', '🌈', 'event', 0, 0, 8);

insert into public.leaderboard_frames (name, emoji, scope, period) values
  ('Weekly Top 1', '🥇', 'global', 'weekly'),
  ('Weekly Top 3', '🥈', 'global', 'weekly'),
  ('Monthly Champion', '🏆', 'global', 'monthly'),
  ('Agency Cup', '💠', 'agency', 'monthly');

insert into public.legal_pages (title, slug, body, status) values
  ('Terms of Service', 'terms', 'Terms of Service — content pending.', 'draft'),
  ('Privacy Policy', 'privacy', 'Privacy Policy — content pending.', 'draft'),
  ('Community Guidelines', 'community', 'Community Guidelines — content pending.', 'draft'),
  ('Refund Policy', 'refund', 'Refund Policy — content pending.', 'draft'),
  ('Host Agreement', 'host-agreement', 'Host Agreement — content pending.', 'draft'),
  ('Agency Agreement', 'agency-agreement', 'Agency Agreement — content pending.', 'draft');
