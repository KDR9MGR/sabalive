# SABALIVE 1.0.0 (build 16): release notes, 2026-10-31

> **Build 16 as shipped (2026-11-01) also carries crash and freeze reports and the new leaderboard reset time.** A test APK was numbered 17 for a day (`sabalive-1.0.0+17-release.apk`, same code); the Play bundle is numbered 16 again at the owner's word, so `sabalive-1.0.0+16-release.aab` is the one to upload. Crash reports: Firebase Crashlytics for Android (crashes, native crashes, freezes, and why the last session ended: low memory, freeze, crash), with the person's visible app ID attached. **Before publishing: add "Crash logs" and "User IDs" to the Play Data safety form and the privacy policy.** iPhone sends nothing. Leaderboards: Daily / Weekly / Monthly boards now reset at 00:10 India time (needs database migrations `20261101020000` and `20261101120000`).

Built after `play-15` (`256a242`). This note covers the owner's four panel points, the three app points that followed, and what was already waiting since build 13.

## Play Console "What's new" (paste as it is, under 500 characters)

```
• Gifts and animations now show instantly: they are kept on your phone.
• Games has two tabs, New and Old.
• Backgrounds are now coloured shades of the app's colour instead of black.
• Free Store items say "Free" and can be taken in one tap.
• Play music from your phone in video lives too.
• Leaderboards reset at 00:10 India time.
• Smoother games: the game window fits each game.
• You hear your own gift sounds again, and your level progress stays up to date.
• Many small fixes.
```

## What changed

### In the app (needs build 16)
1. **Gifts and assets load at once.** A gift's animation is now kept decoded in memory (the gift sheet draws every tile at once the second time), the animation files are kept on the phone for 60 days (the package default was 7 days / 100 MB; now 60 days / 250 MB), the gift list itself is kept between runs so the sheet knows its gifts before the network answers, and the first 16 gifts' files are fetched right after sign-in, four at a time, the first 100 when a live opens. The loading "quiet shape" is only seen the very first time a file has never been on the phone. No database change was needed: the gifts table is tiny and its query is already fast; the time was spent downloading and decoding files.
2. **Games: "New" and "Old" tabs.** New = the newer games, Old = the first games. The tabs only appear when both have games. Neither provider's name appears anywhere in the app. Sort and the Coin / Party filter work inside each tab; the last tab used is remembered.
3. **No more black backgrounds.** The panel's Site / Branding has a new **Background tone**: Deep (the old almost-black look), **Rich** (clearly coloured, the default) and Soft (lighter). The tone is chosen so every colour keeps the same brightness (a green is no murkier than a violet) and the light text stays readable; the muted and secondary text colours were lightened a little for it. The default violet keeps its original purples and pink. A phone that has not read the panel yet wears the default brand in the Rich tone, so nothing flashes black first.
4. **Free Store items show "Free"** (and "added to your Bag!" after getting one).
5. **Music in video lives.** Tools -> "Play music" was only in audio rooms; a video live's host has it now, with the same sheet (choose songs from the phone, pause / next / stop, volume, "Only I can hear it"). The song goes out with the host's voice, so it stops when the microphone is muted. If a PK battle moves the live to another channel, the song that was playing starts again from its beginning. No database change.
6. **Leaderboards reset at 00:10 India time** (not midnight): Hosts = diamonds received through gifts, Gifters = coins spent, Agencies = the diamonds of all their hosts; daily every day, weekly every Monday, monthly on the 1st. The Rankings screen says so. The database decides the moment (migrations `20261101020000`, `20261101120000`), so the boards move for every installed version once those are applied.
7. **Crash and freeze reports** (Android): see the note at the top. Nothing is visible in the app.

### In the panel (live when the panel is deployed; the first three also need the database update)
5. **Automatic Host tag.** Tags page, row action "Give to every new host automatically": that tag is given the moment an agency accepts a host (application approved, or first attached to an agency). "Add to hosts that already exist" adds it to the hosts already accepted. Independent hosts and transfers between agencies do not give it.
6. **Frame lock** (Super Admin / Master only): Profile Frame page and Store -> Frames. While locked, no other panel can assign the frame; Master and Super Admin still can.
7. **Free Store items:** an empty price or 0 makes a Store item free, like a Lucky ID. A free item already owned is refused instead of extended.
8. **Room skin:** the user page's Bag card has a direct **Assign room skin** button (Assign item -> Room skin already worked).
9. **Background tone** control in Site / Branding with a live preview (it only appears once the database update is on).

### Already waiting since build 13 (in build 15, still in this build)
SUD games on the native SDK (game window 1080 x 1669), Tulasi game windows that fit each game (Monkey Pro no longer cut off), games Sort by and filter, the sender hears their own gift sound, level pictures and Wealth / Charm XP that stay in step with the panel, tag strip fixes, the invite link page, the game window's close button above the game, and the iOS App Store review fixes.

## Database (production): three additive migrations, in this order
1. `20261028100000_games_sorting` (Sort by: added_at, play log, popularity; the app works without it)
2. `20261031100000_host_tag_frame_lock_free_store` (Host tag, frame lock, free Store items)
3. `20261031110000_brand_tone` (the tone column; defaults to Rich)

Each has a rollback in `supabase/rollbacks/`, and the SQL tests are in `scripts/db/tests/` (`games_sorting_test.sql`, `panel_batch_20261031_test.sql` + `_rollback_test.sql`, `brand_tone_test.sql`). Rehearsed on staging 2026-10-31 (all three applied, columns / triggers / functions / the new price rule checked).

## Order of release
database (done first) -> panel (Vercel deploys from `main`) -> the Play build. An app on Play that is older than build 16 keeps working against the new database (old apps show a free item as "0 coins", the purchase still works) and keeps its old black look; the tone only shows in build 16.

## Force-update
Once build 16 is live on Play at 100%, set Application Config -> Release Settings -> Android minimum (and latest) version code to 16. Not before.
