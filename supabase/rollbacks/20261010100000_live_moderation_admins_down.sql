-- Down script for supabase/migrations/20261010100000_live_moderation_admins.sql
-- Applied BY HAND only. Puts the moderation functions back to "host only" (their earlier bodies), removes room
-- admins, kicks and text bans, and restores the 5..25 / multiples-of-5 seat counts (lives with 4, 8, 12, 16 or other
-- counts are set to the nearest lower multiple of 5 first, minimum 5, so the old check holds).
begin;
set local lock_timeout = '5s';

drop trigger if exists live_chat_mute_check on public.live_chat_messages;
drop function if exists public.assert_chat_not_muted();

create or replace function public.block_viewer(p_stream_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()) then
    raise exception 'Only the host can do this';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You can''t remove yourself';
  end if;
  insert into public.live_stream_viewer_bans (live_stream_id, user_id, banned_by)
  values (p_stream_id, p_user_id, auth.uid())
  on conflict (live_stream_id, user_id) do nothing;
  update public.live_stream_viewers set left_at = now()
   where live_stream_id = p_stream_id and viewer_id = p_user_id and left_at is null;
  delete from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = p_user_id;
end;
$$;

create or replace function public.kick_seat_occupant(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()) then
    raise exception 'Only the host can do this';
  end if;
  delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = p_seat;
end;
$$;

create or replace function public.ban_seat_occupant(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_occupant uuid;
begin
  if not exists (select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()) then
    raise exception 'Only the host can do this';
  end if;
  select occupant_id into v_occupant from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = p_seat;
  if v_occupant is null then
    raise exception 'No one is on that seat';
  end if;
  delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = p_seat;
  insert into public.live_stream_seat_bans (live_stream_id, banned_id, banned_by)
  values (p_stream_id, v_occupant, auth.uid())
  on conflict (live_stream_id, banned_id) do nothing;
end;
$$;

create or replace function public.host_set_seat_mute(p_stream_id uuid, p_seat integer, p_muted boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()) then
    raise exception 'Only the host can do this';
  end if;
  update public.live_stream_seats set is_muted = p_muted where live_stream_id = p_stream_id and seat_number = p_seat;
  if not found then
    raise exception 'No one is on that seat';
  end if;
end;
$$;

create or replace function public.set_seat_lock(p_stream_id uuid, p_seat integer, p_locked boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_locked then
    update public.live_streams set locked_seats = (select array_agg(distinct x) from unnest(locked_seats || p_seat) as x)
    where id = p_stream_id and host_id = auth.uid();
  else
    update public.live_streams set locked_seats = array_remove(locked_seats, p_seat)
    where id = p_stream_id and host_id = auth.uid();
  end if;
end;
$$;

update public.live_streams set seat_count = greatest(5, (seat_count / 5) * 5) where seat_count % 5 <> 0 or seat_count < 5;
alter table public.live_streams drop constraint if exists live_streams_seat_count_check;
alter table public.live_streams add constraint live_streams_seat_count_check check (seat_count between 5 and 25);
create or replace function public.set_seat_count(p_stream_id uuid, p_count integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_count < 5 or p_count > 25 or p_count % 5 <> 0 then
    raise exception 'Seat count must be a multiple of 5 between 5 and 25';
  end if;
  update public.live_streams set seat_count = p_count where id = p_stream_id and host_id = auth.uid();
end;
$$;

-- tables first: their policies call is_room_moderator(), so that function cannot be dropped while they exist
drop table if exists public.live_chat_mutes;
drop table if exists public.live_stream_kicks;
drop table if exists public.live_room_admins;
drop function if exists public.mute_chat(uuid, uuid, boolean);
drop function if exists public.kick_viewer(uuid, uuid);
drop function if exists public.set_room_admin(uuid, boolean);
drop function if exists public._assert_can_moderate(uuid, uuid);
drop function if exists public.is_room_moderator(uuid, uuid);
commit;
