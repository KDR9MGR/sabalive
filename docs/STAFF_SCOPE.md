# Each admin sees only their own chain (migration 20261102100000)

Global > Country > Sub Admin > Agency > Host. With the switch on, a Global, Country, Sub Admin or Agency account sees only the people under it, in every list, count and
report of the panel. Master and Super Admin see everyone. The app is not affected (app accounts, ghosts and Play builds read exactly what they read before).

## What each level sees (switch on)
| Level | Sees |
|---|---|
| Global Admin | itself; its Country Admins (`staff_roles.global_admin_id`) and their Sub Admins, agencies, agency managers, hosts and applicants; other Global Admins (peers, for the Transfer pages) |
| Country Admin | itself; its Global Admin; its Sub Admins (`country_admin_id`) and their agencies, managers, hosts, applicants; other Country Admins (peers) |
| Sub Admin | itself; its Country Admin; the agencies it owns (`agencies.sub_admin_id`) with their managers, hosts and applicants |
| Agency | itself; its Sub Admin; its own hosts, applicants and co-managers |
| everyone above | people named on a coin transfer that the level can see (so coin history still shows names) |
Hosts with no agency, Country Admins with no Global Admin and Sub Admins with no Country Admin are seen by Master and Super Admin only.
Ordinary users who are not hosts are hidden, except people named on a coin transfer in the chain. A coin sender can still reach any ordinary user by typing the exact app
User ID (`find_user_for_coins`, name and IDs only, never a ghost).

## Turn it on (Super Admin)
1. Read-only check (production), it must be understood before the switch goes on: how many people would be seen by Master / Super Admin only?
```sql
select 'country admins without a global admin' as what, count(*) from public.staff_roles where role = 'country_admin' and global_admin_id is null
union all select 'sub admins without a country admin', count(*) from public.staff_roles where role = 'sub_admin' and country_admin_id is null
union all select 'agencies without a sub admin', count(*) from public.agencies where sub_admin_id is null
union all select 'hosts without an agency', count(*) from public.host_profiles where agency_id is null;
```
   Fix the first row in the panel (Transfer Global / Transfer Sub Admin / Transfer Agency / Transfer Host), or accept that those are Master-only.
2. Panel: Application Config -> Release Settings -> **Limit each admin to their own chain** -> Save release controls. It takes effect on the next page load.
3. Check as a Global, a Country and a Sub Admin that the lists show their own chain.

## Turn it off
The same switch, saved off: everything is back at once, nothing is deleted. To remove the rule from the database, run `supabase/rollbacks/20261102100000_down.sql`.

## Not covered (known)
Action functions that take a user ID (`admin_user_login_info`, `admin_assign_*`, `ban_user_v2`, `admin_update_user_profile`, ...) check the account's *capability*, not the chain. They are
only reachable by a Global / Country / Sub Admin / Agency that a Super Admin has explicitly granted View user profile or Manage users (Access Control), and the panel only offers them
people from the lists above. They are not yet locked to the chain at the API level.

## Tests
`scripts/db/tests/staff_see_only_their_chain_test.sql` and `..._rollback_test.sql` (scratch Postgres, `scripts/db/replay_migrations.sh <file>`),
`scripts/staging/verify_staff_scope.sh` (real grants on staging, rolled back).
