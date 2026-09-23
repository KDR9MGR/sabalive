-- Self-serve feedback with admin triage, mirroring user_reports' exact
-- self-insert / self-read / admin-write RLS shape (file a report as
-- yourself / see what you filed / admins triage).
create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('app_error', 'suggestion', 'earning_info', 'other')),
  contact_method text check (contact_method in ('email', 'phone')),
  contact_value text,
  body text not null,
  status text not null default 'pending' check (status in ('pending', 'in_progress', 'resolved')),
  response text,
  responded_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.feedback enable row level security;

create policy "File feedback as yourself" on public.feedback
  for insert with check (profile_id = auth.uid());

create policy "See feedback you filed" on public.feedback
  for select using (profile_id = auth.uid() or public.is_admin_or_above());

create policy "Admins triage feedback" on public.feedback
  for update using (public.is_admin_or_above());

create index feedback_profile_id_idx on public.feedback(profile_id);

alter publication supabase_realtime add table public.feedback;
