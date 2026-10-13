-- Down script for supabase/migrations/20261013140000_tulasi_game_curation.sql
-- Applied BY HAND only. Puts the previous game_sync_list / start_game_session bodies back and removes the hide switch (the hidden flags are lost).
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_set_games_hidden(bigint[], boolean);

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

  delete from public.game_sessions where profile_id = v_me and expires_at < now();
  delete from public.game_sessions
   where profile_id = v_me
     and token_hash not in (select token_hash from public.game_sessions where profile_id = v_me order by created_at desc limit 4);

  v_token := replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + make_interval(hours => v_cfg.session_hours);
  insert into public.game_sessions (token_hash, profile_id, game_id, expires_at)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_me, p_game_id, v_expires);

  return jsonb_build_object('token', v_token, 'uid', v_uid, 'expires_at', v_expires);
end;
$$;
revoke execute on function public.start_game_session(text) from public, anon;
grant execute on function public.start_game_session(text) to authenticated;

alter table public.merchant_games drop column if exists hidden;
commit;
