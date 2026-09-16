-- Backend support for the alpha-testing feature pass:
--   1. dev_purchase_coins  — fake the coin-purchase credit until a real
--      payment gateway is wired (no gateway chosen yet). ALPHA ONLY.
--   2. calls                — 1:1 audio/video call signalling (ring / accept /
--      decline / end), delivered over Realtime.
--   3. start_group_conversation — create a group DM in one server call.

-- ─────────────────────────────────────────────── 1. dev coin purchase
create function public.dev_purchase_coins(p_package_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_pkg public.coin_packages%rowtype;
begin
  if v_me is null then
    raise exception 'not authenticated';
  end if;
  select * into v_pkg from public.coin_packages where id = p_package_id and status = 'active';
  if not found then
    raise exception 'package not found';
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
  values (v_me, 'purchase', 'coins', v_pkg.coins + v_pkg.bonus_coins,
          'Coin purchase (alpha) — ' || v_pkg.name);
end;
$$;

grant execute on function public.dev_purchase_coins(uuid) to authenticated;

-- ─────────────────────────────────────────────── 2. calls
create table public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles (id) on delete cascade,
  callee_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null default 'audio' check (kind in ('audio', 'video')),
  status text not null default 'ringing'
    check (status in ('ringing', 'accepted', 'declined', 'missed', 'ended', 'cancelled')),
  channel text not null,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz,
  check (caller_id <> callee_id)
);

create index calls_callee_idx on public.calls (callee_id, created_at desc);
create index calls_caller_idx on public.calls (caller_id, created_at desc);

alter table public.calls enable row level security;

create policy "Call participants see the call"
  on public.calls for select using (caller_id = auth.uid() or callee_id = auth.uid());
create policy "Caller starts the call"
  on public.calls for insert with check (caller_id = auth.uid());
create policy "Call participants update the call"
  on public.calls for update using (caller_id = auth.uid() or callee_id = auth.uid());

alter publication supabase_realtime add table public.calls;

-- ─────────────────────────────────────────────── 3. group conversations
create function public.start_group_conversation(p_name text, p_member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_conv uuid;
  v_member uuid;
begin
  if v_me is null then
    raise exception 'not authenticated';
  end if;
  if coalesce(array_length(p_member_ids, 1), 0) < 1 then
    raise exception 'a group needs at least one other member';
  end if;

  insert into public.conversations (is_group, name, created_by)
  values (true, nullif(trim(p_name), ''), v_me)
  returning id into v_conv;

  insert into public.conversation_participants (conversation_id, profile_id, role, status)
  values (v_conv, v_me, 'admin', 'accepted');

  foreach v_member in array p_member_ids loop
    if v_member <> v_me then
      insert into public.conversation_participants (conversation_id, profile_id, role, status)
      values (v_conv, v_member, 'member', 'accepted')
      on conflict do nothing;
    end if;
  end loop;

  return v_conv;
end;
$$;

grant execute on function public.start_group_conversation(text, uuid[]) to authenticated;
