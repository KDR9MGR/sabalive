-- Named, reusable commission tiers for agencies. agencies.commission_percent
-- stays the per-agency effective rate; a commission_plan is a template an
-- admin can keep on file and apply. Managed only from the sabaliveadmin
-- panel (staff read, admin write); archived rather than deleted.

create table public.commission_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  agency_commission_percent numeric(5, 2) not null default 10.00
    check (agency_commission_percent >= 0 and agency_commission_percent <= 100),
  host_payout_percent numeric(5, 2) not null default 60.00
    check (host_payout_percent >= 0 and host_payout_percent <= 100),
  min_monthly_diamonds integer not null default 0 check (min_monthly_diamonds >= 0),
  status text not null default 'active' check (status in ('active', 'archived')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger commission_plans_set_updated_at
  before update on public.commission_plans
  for each row execute function public.set_updated_at();

alter table public.commission_plans enable row level security;

create policy "Staff read commission plans"
  on public.commission_plans for select using (public.is_staff());
create policy "Admins create commission plans"
  on public.commission_plans for insert with check (public.is_admin_or_above());
create policy "Admins update commission plans"
  on public.commission_plans for update using (public.is_admin_or_above());
-- no delete policy: archive via status = 'archived'
