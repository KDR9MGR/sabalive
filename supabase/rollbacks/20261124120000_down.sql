-- Undoes 20261124120000_lucky_box_by_month: the two read-only month functions go; the Lucky Box page's old "Reward history" still reads the ledger directly.
set local lock_timeout = '5s';
drop function if exists public.lucky_box_month_rewards(text, bigint);
drop function if exists public.lucky_box_month_people(text);
