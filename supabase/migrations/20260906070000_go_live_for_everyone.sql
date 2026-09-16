-- The consumer app treats "Go Live" as a basic feature available to any
-- signed-in user, not something gated behind a pre-approved host status —
-- host_applications/agencies are a separate, optional path for
-- agency-affiliated creators (used by the admin panel), not a prerequisite
-- for the basic flow. Relax the insert policy accordingly, and instead grant
-- is_host + a host_profiles row automatically the first time someone starts
-- a stream, so the two models (simple go-live vs. agency host) stay in sync
-- without blocking either one.

drop policy "Hosts start their own stream" on public.live_streams;

create policy "Signed-in users start their own stream"
  on public.live_streams for insert
  with check (host_id = auth.uid());

create function public.handle_first_stream()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles set is_host = true where id = new.host_id and not is_host;
  insert into public.host_profiles (profile_id) values (new.host_id)
    on conflict (profile_id) do nothing;
  return new;
end;
$$;

create trigger live_streams_first_stream
  after insert on public.live_streams
  for each row execute function public.handle_first_stream();

revoke execute on function public.handle_first_stream() from public;
