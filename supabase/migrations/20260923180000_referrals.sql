-- Referral / invite-a-friend. profiles.referral_code is generated lazily
-- (my_referral_code()) rather than at signup, so this doesn't touch the
-- existing auth/onboarding flow at all — same reasoning as deferring real
-- deep-link capture: redemption is a manual "enter your friend's code"
-- action from inside the app, not wired into signup itself this pass.
alter table public.profiles add column referral_code text unique;

create table public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_id uuid not null unique references public.profiles(id) on delete cascade,
  reward_coins integer not null,
  created_at timestamptz not null default now()
);

alter table public.referrals enable row level security;

create policy "See referrals you made" on public.referrals
  for select using (referrer_id = auth.uid());

create function public.my_referral_code()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_code text;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  select referral_code into v_code from public.profiles where id = v_me;
  if v_code is not null then
    return v_code;
  end if;
  loop
    v_code := upper(substr(md5(random()::text), 1, 8));
    begin
      update public.profiles set referral_code = v_code where id = v_me;
      return v_code;
    exception when unique_violation then
      -- extremely unlikely collision on an 8-char code — retry with a fresh one
    end;
  end loop;
end;
$$;

-- Reward is a flat welcome-bonus amount, easy to retune later — not tied
-- to any product decision beyond "referrals should pay out something".
create function public.redeem_referral_code(p_code text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_referrer uuid;
  v_reward constant integer := 1000;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  if exists (select 1 from public.referrals where referred_id = v_me) then
    raise exception 'You have already redeemed a referral code';
  end if;

  select id into v_referrer from public.profiles
  where referral_code = upper(trim(p_code));
  if v_referrer is null then
    raise exception 'Invalid referral code';
  end if;
  if v_referrer = v_me then
    raise exception 'You cannot redeem your own code';
  end if;

  insert into public.referrals (referrer_id, referred_id, reward_coins)
  values (v_referrer, v_me, v_reward);
  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
  values (v_referrer, 'grant', 'coins', v_reward, 'Referral reward');
end;
$$;
