-- Directory of offline coin sellers (agents who sell coins for real money
-- outside the app — cash/UPI — then get the buyer's coins credited via the
-- existing admin-grant channel). Deliberately NOT the same thing as the
-- existing resell_coins flow (that's a peer-to-peer wallet transfer between
-- two in-app balances); this is just a contact directory: browse sellers,
-- tap one, it opens WhatsApp so the buyer and seller arrange things
-- themselves. No coins move through this table at all.
create table public.offline_coin_sellers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  whatsapp_number text not null,
  note text,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.offline_coin_sellers enable row level security;

create policy "Active offline sellers are public" on public.offline_coin_sellers
  for select using (active);
