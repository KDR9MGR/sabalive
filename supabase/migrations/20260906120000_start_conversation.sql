-- Starting a DM is a multi-row operation (the conversation plus a participant
-- row for each side) and the client can't do it directly: a plain
-- `insert ... returning` on `conversations` trips that table's own SELECT
-- policy (`is_conversation_participant`) before any participant row exists,
-- which PostgREST surfaces as an RLS violation. Do it server-side instead,
-- reusing an existing 1:1 thread when there is one.

create function public.start_conversation(p_other_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_conv uuid;
begin
  if v_me is null then
    raise exception 'not authenticated';
  end if;
  if p_other_id is null or p_other_id = v_me then
    raise exception 'invalid recipient';
  end if;
  if not exists (select 1 from public.profiles where id = p_other_id) then
    raise exception 'recipient not found';
  end if;

  select c.id into v_conv
  from public.conversations c
  where c.is_group = false
    and exists (
      select 1 from public.conversation_participants p
      where p.conversation_id = c.id and p.profile_id = v_me
    )
    and exists (
      select 1 from public.conversation_participants p
      where p.conversation_id = c.id and p.profile_id = p_other_id
    )
  limit 1;

  if v_conv is not null then
    return v_conv;
  end if;

  insert into public.conversations (is_group, created_by)
  values (false, v_me)
  returning id into v_conv;

  insert into public.conversation_participants (conversation_id, profile_id, role, status)
  values
    (v_conv, v_me, 'member', 'accepted'),
    (v_conv, p_other_id, 'member', 'pending');

  return v_conv;
end;
$$;

grant execute on function public.start_conversation(uuid) to authenticated;
