-- Root cause of "seat request never showed up on the host's screen":
-- pk_seat_requests was never added to the supabase_realtime publication
-- (same class of gap already hit twice before this session for
-- live_chat_messages and dm_messages) — the RPC itself worked fine and the
-- row was created, but Postgres never emitted a change event for it, so
-- the host's onPostgresChanges subscription had nothing to react to unless
-- they happened to reopen the screen after the request was made.
alter publication supabase_realtime add table public.pk_seat_requests;
