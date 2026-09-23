-- "Who viewed my profile" — one row per (visitor, visited) pair, upserted
-- on repeat visits so the list shows "most recently seen you", not an
-- ever-growing log of every single view.
create table public.profile_visits (
  visitor_id uuid not null references public.profiles(id) on delete cascade,
  visited_id uuid not null references public.profiles(id) on delete cascade,
  visited_at timestamptz not null default now(),
  primary key (visitor_id, visited_id)
);

alter table public.profile_visits enable row level security;

-- Only the visited profile's own owner can see who's been looking —
-- visitor identity is only exposed to the person they visited, not
-- publicly browsable.
create policy "See your own visitors" on public.profile_visits
  for select using (visited_id = auth.uid());

create index profile_visits_visited_id_idx
  on public.profile_visits(visited_id, visited_at desc);

-- No client-write path — logging a visit needs validation (don't log
-- self-visits, don't let a caller claim to be someone else's visitor).
create function public.log_profile_visit(p_profile_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null or v_me = p_profile_id then
    return;
  end if;
  insert into public.profile_visits (visitor_id, visited_id, visited_at)
  values (v_me, p_profile_id, now())
  on conflict (visitor_id, visited_id) do update set visited_at = now();
end;
$$;
