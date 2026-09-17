-- Every viewer of every stream — video, audio, or PK — has been landing on
-- the same video-only watch screen, because live_streams never recorded
-- which mode a stream was started in (is_pk existed but createStream()
-- never set it). Audio/PK hosts never publish a video track, so their
-- viewers saw a permanently blank canvas instead of a proper room UI.
alter table public.live_streams
  add column mode text not null default 'video' check (mode in ('video', 'audio', 'pk'));

update public.live_streams set mode = 'pk' where is_pk = true;
