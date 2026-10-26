# Monthly diamond reset

Status (2026-10-26): built and tested; applied to STAGING only and passes `scripts/staging/verify_diamond_reset.sh`. Nothing is on production. Two migrations: `20261026120000_diamond_reset`
(the manual buttons) and `20261026130000_diamond_reset_auto` (the automatic monthly reset). The commit and push of the code were done on the owner's word (see HANDOFF); the database part is NOT applied on production.
Owner's request: "reset diamonds monthly ... manual buttons, two different ones for reward diamonds reset and gifting diamonds reset, and all at once as well", pressed by a Master or Super Admin;
then "add a toggle for auto along with checkbox options" (the automatic monthly reset, below).

## Where
Master panel -> Economy -> **Diamond Reset** (`/admin/diamond-reset`; a Super Admin reaches it through the Master panel). Needs the Master / Super Admin role AND the Run payroll switch
(on for a Master by default; an explicit false blocks). A Global / Country / Sub Admin or an agency can never use it, even with Run payroll, and the page is not on their menu.

## What a reset takes
Choose a FINISHED month (India time, like the Salary reports; the month in progress is refused). The page shows, before anything happens, how many wallets and diamonds each button would take.
Three buttons: **Reset gifting diamonds**, **Reset reward diamonds**, **Reset both** (gifting + reward in one step). Per wallet:
- gifting = the diamonds it received that month as gifts (`gift_received` ledger rows);
- reward = the Lucky Box diamonds it won that month, a pulled-back win left out (the same figure as the Salary report's "Diamonds from rewards");
- never more than the wallet holds, and never diamonds that arrived AFTER the month ended: withdrawals are assumed to use the oldest diamonds first, so the most that can be taken is
  (balance now - positive diamond credits since the month ended). A host who already withdrew the month's diamonds loses little or nothing. The credits an Undo gives back do not count as "new".
- other months, other kinds of credit, and ghost accounts are untouched. If a host's balance covers only part of the month's gifts, only that part is taken; a wallet never goes below 0.
Each (month, kind) can be reset ONCE. "Both" is refused if either was done (use the other button to finish a half-done month). The reset is confirmed by TYPING the month (`2026-09`); the
database checks that too, not only the page.

## How it is recorded
- `diamond_reset_runs` (month, kind, who, when, wallets, diamonds, undone?) is the run log, shown as "Reset history" on the page (Master / Super Admin read it; nobody writes it directly).
- One negative `grant_reversal` ledger row per wallet (an existing kind, so `wallet_ledger_kind_check` is not touched), `reference_table = 'diamond_reset_runs'`, `reference_id = the run`,
  note "Diamond reset 2026-09 (gifting diamonds)". The Salary reports only count `gift_received` rows and Lucky Box `grant` rows, so a reset does NOT change a month's "Diamonds from gifts / rewards";
  it changes the wallet balance ("Available diamonds") only.
- A critical audit-log row per run (`diamonds.reset`) and per undo (`diamonds.reset_undone`).
- **Undo** (history table, row menu): gives the exact diamonds back (`grant` rows, note "... undone") and frees that month and kind for another run. Typed month again.
- **Hosts are notified.** The ledger trigger sends the standard text "N diamonds were reclaimed from your wallet by an admin" (and "You received N diamonds" on an undo). It is not specific to the reset.
  A friendlier text would need a change to `notify_wallet_ledger_entry` (a trigger function on the busiest table): left out on purpose, ask if wanted.

## Automatic monthly reset (migration `20261026130000`)
The page's first card: a **toggle** (OFF by default), two **checkboxes** (Gifting diamonds, Reward diamonds; both ticked by default) and **Run on day** (1-28, default 1). Saved with a button; turning it ON asks once more,
naming the date and what will be taken. The card says when the next run is and what it will reset ("Next automatic run: 1 Nov 2026, 00:05 India time. It will reset October 2026: gifting diamonds and reward diamonds")
and what the last run did.
- A pg_cron job `diamond-reset-auto` calls `run_diamond_reset_auto()` every day at 18:35 UTC = 00:05 India time. The function does nothing unless the switch is on AND today (India time) is the chosen day.
  On that day it resets the PREVIOUS month for each ticked kind: the same rule, ledger rows, audit row, once-per-month slot and Undo as the buttons (both go through `_diamond_reset_run_one`).
  A kind already reset (by hand or earlier) is skipped; a kind that is ticked later is picked up by the next daily call on that day. A month that has not ended is never touched.
- If the job misses the day (database down at 00:05) it does NOT catch up: it simply tries again next month, and the card's "Last automatic run" shows it. Press the manual button for that month.
- Runs of the job have no person (`run_by` null, `auto` true; the history shows "Automatic"); the audit rows are `diamonds.reset_auto` (critical, no actor). One kind failing does not undo the other: the failure
  is written to the audit log (`diamonds.reset_auto_failed`) and to the card's note. Switching it on / off is audited (`diamonds.reset_auto_settings`).
- Because hosts get no warning, choose a day that leaves them time to withdraw (the card says so). Switching it off stops it at once (the job then returns "off").
- Only a Master / Super Admin can change it (`admin_set_diamond_reset_auto`); app users and anon cannot call the job.
- Rollback: `supabase/rollbacks/20261026130000_down.sql` (it also puts the manual button back as `20261026120000` had it; run it BEFORE `20261026120000_down.sql`).
- Tests: `scripts/db/tests/diamond_reset_auto_test.sql`, `diamond_reset_auto_rollback_test.sql`; panel `diamondResetRules.test.js`; staging steps 11-19 of `verify_diamond_reset.sh`.

## Functions of the manual buttons (migration `20261026120000_diamond_reset.sql`; rollback `supabase/rollbacks/20261026120000_down.sql`)
`admin_diamond_reset_preview(month)` (read only), `admin_reset_diamonds(month, 'gift'|'reward'|'both', confirm)`, `admin_undo_diamond_reset(run, confirm)`; internal `_diamond_reset_plan(month, kind)` (the ONE rule
both the preview and the run use) and `_diamond_reset_actor_ok()`. The run locks the affected wallets in a fixed order and takes one advisory lock, so two admins cannot take the same month and
the amounts cannot go stale (`wallets.diamonds` has a check >= 0). Old apps never call any of it. The rollback does NOT give diamonds back (use the panel's Undo before rolling back).

## Checks
`scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_test.sql` and `.../diamond_reset_rollback_test.sql`; panel `npm test` (`diamondResetRules.test.js`);
staging, real roles: `scripts/staging/verify_diamond_reset.sh` (rolled back). The page itself was compiled but NOT clicked through in a browser (it needs a panel login).

## Not decided / for the owner
- The unit is the month in India time, matching the Salary reports. The Salary payslip status is not consulted: nothing stops a reset before salaries are paid; the page tells the person to check.
- What counts: gift diamonds (`gift_received`) and Lucky Box rewards only. Other diamond credits (a refund of a rejected withdrawal, a manual grant) are never reset.
- Production: backup, dry run, then `scripts/prod/promote_step.sh 20261026120000 --apply` and `... 20261026130000 --apply` (one at a time) only on the owner's word; the panel page deploys with the panel push and shows "needs the database update" until then. Leave the automatic switch OFF until the manual buttons have been tried.
