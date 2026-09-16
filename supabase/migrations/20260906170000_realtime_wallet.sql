-- WalletController subscribes to wallets/wallet_ledger over Realtime but the
-- tables were never on the publication, so balances only refreshed on app
-- launch. Add them (guarded) so coin purchases, gifts and withdrawals move
-- the balance live.
do $$
begin
  if not exists (select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wallets') then
    execute 'alter publication supabase_realtime add table public.wallets';
  end if;
  if not exists (select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wallet_ledger') then
    execute 'alter publication supabase_realtime add table public.wallet_ledger';
  end if;
end $$;
