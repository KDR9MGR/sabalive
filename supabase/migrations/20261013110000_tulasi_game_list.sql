-- Tulasi games, part 2: the list of games the platform has authorised for us.
--
-- Tulasi pushes the FULL list (updateGameList) whenever authorisations change; the Edge Function re-hosts the pictures (their URLs may
-- change) and calls game_sync_list(). The app shows the enabled ones and opens each at
--   <game_domain or https://gamesp.tulasigame.com/>/<identification>/?merchant=...&gameId=<id>&token=...
-- New table + one service-role function; nothing existing changes. Rollback: supabase/rollbacks/20261013110000_tulasi_game_list_down.sql.
create table if not exists public.merchant_games (
  id bigint primary key,                 -- Tulasi's merchant game configuration id (also the gameId in the game URL)
  merchant_id bigint,
  name text not null,
  identification text,                   -- the path of the game URL, e.g. 'kingdoms'
  image_url text,
  banner_url text,
  image_path text,
  banner_path text,
  description text,
  status integer not null default 1 check (status in (0, 1)),
  game_domain text,
  expiration_date timestamptz,
  sort_order integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.merchant_games enable row level security;
drop policy if exists "Signed-in users see the enabled games" on public.merchant_games;
create policy "Signed-in users see the enabled games" on public.merchant_games for select to authenticated using (status = 1);
drop policy if exists "Staff see every game" on public.merchant_games;
create policy "Staff see every game" on public.merchant_games for select using (public.is_admin_or_above());

-- p_games: the array Tulasi sent, each element optionally carrying imageUrl / bannerUrl (our re-hosted copies).
-- Games missing from the list are switched off (the list is the full set).
create or replace function public.game_sync_list(p_games jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  g jsonb;
  v_ids bigint[] := '{}';
  v_n integer := 0;
begin
  if p_games is null or jsonb_typeof(p_games) <> 'array' then
    raise exception 'the game list must be an array';
  end if;
  for g in select * from jsonb_array_elements(p_games) loop
    if (g ->> 'id') is null or (g ->> 'name') is null then
      continue;
    end if;
    insert into public.merchant_games
      (id, merchant_id, name, identification, image_url, banner_url, image_path, banner_path, description, status, game_domain, expiration_date, sort_order)
    values (
      (g ->> 'id')::bigint, nullif(g ->> 'merchantId', '')::bigint, left(g ->> 'name', 120), left(g ->> 'gameIdentification', 80),
      coalesce(nullif(g ->> 'imageUrl', ''), nullif(g ->> 'image', '')), coalesce(nullif(g ->> 'bannerUrl', ''), nullif(g ->> 'banner', '')),
      left(g ->> 'imagePath', 300), left(g ->> 'bannerPath', 300), left(g ->> 'description', 500),
      case when (g ->> 'status') = '1' then 1 else 0 end, left(g ->> 'gameDomain', 200),
      nullif(g ->> 'expirationDate', '')::timestamptz, v_n
    )
    on conflict (id) do update set
      merchant_id = excluded.merchant_id, name = excluded.name, identification = excluded.identification,
      image_url = excluded.image_url, banner_url = excluded.banner_url, image_path = excluded.image_path, banner_path = excluded.banner_path,
      description = excluded.description, status = excluded.status, game_domain = excluded.game_domain,
      expiration_date = excluded.expiration_date, sort_order = excluded.sort_order, updated_at = now();
    v_ids := v_ids || (g ->> 'id')::bigint;
    v_n := v_n + 1;
  end loop;
  update public.merchant_games set status = 0, updated_at = now() where status = 1 and id <> all (v_ids);
  return v_n;
end;
$$;
revoke execute on function public.game_sync_list(jsonb) from public, anon, authenticated;
grant execute on function public.game_sync_list(jsonb) to service_role;
