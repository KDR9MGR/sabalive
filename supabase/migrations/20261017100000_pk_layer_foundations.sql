-- PK battle layer, part 1 of 2: additive columns, a config row and a matching queue. NOTHING EXISTING IS CHANGED.
--
-- PK becomes a layer over normal audio / video lives (plan: HANDOFF.md "PK battle layer"). This file only adds
-- what the new functions (next migration) need, so it is safe while old apps are live:
--   * pk_battles: duration_seconds (the server, not the phone, decides how long a battle lasts), kind ('audio' /
--     'video'; NULL = a legacy PK-mode battle), source ('invite' / 'random'; NULL = legacy) and end_reason.
--     Legacy rows keep working untouched: every new column is nullable or has a constant default.
--   * live_streams.pk_ready: set by an app build that HAS the PK layer (and has PK switched on) for the live it is
--     hosting, so a host on an old build is never offered as an opponent (an old build has no UI to answer an invite).
--   * pk_config: one row with the rules (invite lengths, random length, forfeit grace, invite rate limit).
--   * pk_match_queue: hosts currently searching for a random opponent. No client policy: only the SECURITY DEFINER
--     functions of the next migration read or write it.
-- Rollback: supabase/rollbacks/20261017100000_down.sql

set local lock_timeout = '5s';   -- give up instead of queueing behind a long query on a busy table

alter table public.pk_battles
  add column if not exists duration_seconds integer not null default 300
    check (duration_seconds between 30 and 3600),
  add column if not exists kind text check (kind in ('audio', 'video')),
  add column if not exists source text check (source in ('invite', 'random')),
  add column if not exists end_reason text check (end_reason in ('time', 'forfeit', 'cancelled', 'declined'));

comment on column public.pk_battles.duration_seconds is 'How long the battle runs once begun; set at invite time, read by pk_begin_v2 (the client never chooses it).';
comment on column public.pk_battles.kind is 'audio or video: the kind of live both hosts are in. NULL = a legacy PK-mode battle (invite_pk_opponent).';
comment on column public.pk_battles.source is 'invite or random. NULL = a legacy battle. pk_forfeit_sweep only touches battles that have a source.';
comment on column public.pk_battles.end_reason is 'time / forfeit / cancelled / declined. NULL on legacy rows and on rows nobody set it for.';

alter table public.live_streams
  add column if not exists pk_ready boolean not null default false;

comment on column public.live_streams.pk_ready is 'The host''s app has the PK layer switched on for this live (set through pk_set_ready). Opponents must have it.';

-- ------------------------------------------------------------------------------------------------ pk_config
create table if not exists public.pk_config (
  id boolean primary key default true check (id),                 -- exactly one row
  invite_durations integer[] not null default '{300,600,1800,2400}',
  random_duration integer not null default 300 check (random_duration between 30 and 3600),
  -- A host's live is stamped every 30 s (heartbeat) and the existing sweep ends a live after 90 s of silence. A host whose
  -- stamp is older than this during a battle forfeits. 60 s = two missed heartbeats: one late beat never forfeits.
  forfeit_grace_seconds integer not null default 60 check (forfeit_grace_seconds between 45 and 85),
  invites_per_minute integer not null default 6 check (invites_per_minute between 1 and 60),
  -- the app asks again every 5 s while it searches; an entry nobody refreshed for this long is dropped
  random_queue_seconds integer not null default 20 check (random_queue_seconds between 10 and 120),
  updated_at timestamptz not null default now(),
  check (cardinality(invite_durations) between 1 and 8)
);
insert into public.pk_config (id) values (true) on conflict (id) do nothing;

alter table public.pk_config enable row level security;
drop policy if exists "PK rules are readable" on public.pk_config;
create policy "PK rules are readable" on public.pk_config for select using (true);
revoke insert, update, delete on public.pk_config from authenticated, anon;

-- ------------------------------------------------------------------------------------------ pk_match_queue
create table if not exists public.pk_match_queue (
  stream_id uuid primary key references public.live_streams (id) on delete cascade,
  host_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('audio', 'video')),
  entered_at timestamptz not null default now(),
  seen_at timestamptz not null default now()
);
create index if not exists pk_match_queue_kind_idx on public.pk_match_queue (kind, entered_at);

alter table public.pk_match_queue enable row level security;      -- no policy: nobody but the functions touches it
revoke all on public.pk_match_queue from anon, authenticated;
