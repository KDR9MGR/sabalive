-- Tulasi games: curation from OUR panel, and a sync that copes with what the platform really sends.
--
-- The merchant has 44 games and all of them are switched on in Tulasi's dashboard (variants, "Pro" versions, Ludo, Fishing, Rocket Star ...), so
-- what the app shows must be decided on our side too, without waiting for a Sync in Tulasi's dashboard:
--   merchant_games.hidden   OUR override (default false). The platform's push never touches it. A hidden game is not shown in the app and
--                           start_game_session refuses it. Switched from the panel's Games page (admin_set_games_hidden).
-- And game_sync_list now copes with what the Request Tester / the real push send:
--   * a game with no `status` keeps the status it has (a new one starts enabled) instead of being switched off,
--   * expirationDate is Beijing time (UTC+8), as the dashboard shows it, not UTC,
--   * only https picture links are stored (a relative path or another scheme is dropped; the Edge Function resolves relative paths first).
-- One new column, one new function, two functions replaced (same signatures). Rollback: supabase/rollbacks/20261013140000_tulasi_game_curation_down.sql.
alter table public.merchant_games add column if not exists hidden boolean not null default false;

create or replace function public.game_sync_list(p_games jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  g jsonb;
  v_ids bigint[] := '{}';
  v_n integer := 0;
  v_status integer;
  v_image text;
  v_banner text;
begin
  if p_games is null or jsonb_typeof(p_games) <> 'array' then
    raise exception 'the game list must be an array';
  end if;
  for g in select * from jsonb_array_elements(p_games) loop
    if (g ->> 'id') is null or (g ->> 'name') is null then
      continue;
    end if;
    v_status := case when nullif(g ->> 'status', '') is null then null when (g ->> 'status') = '1' then 1 else 0 end;
    v_image := coalesce(nullif(g ->> 'imageUrl', ''), nullif(g ->> 'image', ''));
    v_banner := coalesce(nullif(g ->> 'bannerUrl', ''), nullif(g ->> 'banner', ''));
    if v_image is not null and v_image not like 'https://%' then v_image := null; end if;
    if v_banner is not null and v_banner not like 'https://%' then v_banner := null; end if;
    insert into public.merchant_games
      (id, merchant_id, name, identification, image_url, banner_url, image_path, banner_path, description, status, game_domain, expiration_date, sort_order)
    values (
      (g ->> 'id')::bigint, nullif(g ->> 'merchantId', '')::bigint, left(g ->> 'name', 120), left(g ->> 'gameIdentification', 80),
      v_image, v_banner,
      left(g ->> 'imagePath', 300), left(g ->> 'bannerPath', 300), left(g ->> 'description', 500),
      coalesce(v_status, 1), left(g ->> 'gameDomain', 200),
      case when nullif(g ->> 'expirationDate', '') is null then null else ((g ->> 'expirationDate')::timestamp at time zone 'Asia/Shanghai') end,
      v_n
    )
    on conflict (id) do update set
      merchant_id = excluded.merchant_id, name = excluded.name, identification = excluded.identification,
      image_url = excluded.image_url, banner_url = excluded.banner_url, image_path = excluded.image_path, banner_path = excluded.banner_path,
      description = excluded.description, status = coalesce(v_status, public.merchant_games.status), game_domain = excluded.game_domain,
      expiration_date = excluded.expiration_date, sort_order = excluded.sort_order, updated_at = now();   -- `hidden` is ours: never touched here
    v_ids := v_ids || (g ->> 'id')::bigint;
    v_n := v_n + 1;
  end loop;
  update public.merchant_games set status = 0, updated_at = now() where status = 1 and id <> all (v_ids);
  return v_n;
end;
$$;
revoke execute on function public.game_sync_list(jsonb) from public, anon, authenticated;
grant execute on function public.game_sync_list(jsonb) to service_role;

-- Hide / show games from the panel (Admin and above, the same people who change the limits). Many at once: there are 44 of them.
create or replace function public.admin_set_games_hidden(p_ids bigint[], p_hidden boolean)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_n integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Not allowed';
  end if;
  update public.merchant_games
     set hidden = coalesce(p_hidden, false), updated_at = now()
   where id = any (coalesce(p_ids, '{}')) and hidden is distinct from coalesce(p_hidden, false);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.admin_set_games_hidden(bigint[], boolean) from public, anon;
grant execute on function public.admin_set_games_hidden(bigint[], boolean) to authenticated;

-- A launch of a hidden or switched-off game is refused here too (an old screen, or a tampered app, must not get a token for it).
create or replace function public.start_game_session(p_game_id text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_cfg public.game_config%rowtype;
  v_dob date;
  v_uid bigint;
  v_token text;
  v_expires timestamptz;
begin
  if v_me is null then
    raise exception 'Sign in to play';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account cannot play games';
  end if;
  if not public._games_enabled() then
    raise exception 'Games are not available right now';
  end if;
  if p_game_id is not null and exists (
       select 1 from public.merchant_games g where g.id::text = p_game_id and (g.hidden or g.status = 0)) then
    raise exception 'This game is not available right now';
  end if;
  select * into v_cfg from public.game_config where id;
  select date_of_birth into v_dob from public.profiles where id = v_me;
  if v_dob is null then
    raise exception 'Add your date of birth in your profile to play games';
  end if;
  if date_part('year', age(current_date, v_dob)) < v_cfg.min_age then
    raise exception 'Games are for people aged % or over', v_cfg.min_age;
  end if;

  insert into public.game_players (profile_id) values (v_me) on conflict (profile_id) do nothing;
  select game_uid into v_uid from public.game_players where profile_id = v_me;

  -- housekeeping: this person's expired launches, and all but their newest few
  delete from public.game_sessions where profile_id = v_me and expires_at < now();
  delete from public.game_sessions
   where profile_id = v_me
     and token_hash not in (select token_hash from public.game_sessions where profile_id = v_me order by created_at desc limit 4);

  v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 hex characters from the server's secure random
  v_expires := now() + make_interval(hours => v_cfg.session_hours);
  insert into public.game_sessions (token_hash, profile_id, game_id, expires_at)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_me, p_game_id, v_expires);

  return jsonb_build_object('token', v_token, 'uid', v_uid, 'expires_at', v_expires);
end;
$$;
revoke execute on function public.start_game_session(text) from public, anon;
grant execute on function public.start_game_session(text) to authenticated;
