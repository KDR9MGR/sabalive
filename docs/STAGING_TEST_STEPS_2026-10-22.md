# Staging test steps: the profile patch (2026-10-22)

Everything here runs on **staging** (fake accounts and fake data). Nothing touches production or real users.
The APK has an orange **STAGING** strip on every screen. If you do not see it, you are on the wrong build.

What is being tested: the "Complete your profile" screen, Fans, badges and tags on the profile, the Tags page in the panel, and level pictures instead of stars.

## 0. Set up (5 minutes)

**Install the APK** (`~/sabalive-releases/sabalive-staging-1.0.0+12.apk`).
It has the same package name as the Play app, so on the phone you test with, **uninstall the Play SABALIVE first** (your account stays on the server; you sign in again after you put the Play version back).
With the phone on USB and USB debugging on:

```bash
adb install -r ~/sabalive-releases/sabalive-staging-1.0.0+12.apk
```

**Accounts** (all `@staging.sabalive.test`). The shared password is `STAGING_TEST_PASSWORD` in `~/sabalive-secrets/staging.env` (type it yourself):

| Account | Use it for |
|---|---|
| `user10@staging.sabalive.test` | has **no date of birth**: shows the new "Complete your profile" screen |
| `user1@staging.sabalive.test` | has **two badges** (Verified, Legend); you will give it tags |
| `user2@staging.sabalive.test` | the second person for Fans |
| `master@staging.sabalive.test` | panel (Master) |
| `superadmin@staging.sabalive.test` | panel (Super Admin) |

**Run the panel against staging** (on your Mac):

```bash
cd "/Users/abdulrazak/Documents/sabalive monorepo/sabaliveadmin" && npm run dev:staging
```

Open http://localhost:5173/ and sign in as `master@staging.sabalive.test`. You should see the orange STAGING strip at the top.

## 1. Complete your profile (after login)

1. In the app sign in as **user10**. Expected: instead of Home you see **"Complete your profile"** with Date of Birth and Country.
2. The **Continue** button is greyed out. Tap it anyway: nothing happens.
3. Tap Date of Birth. Expected: a calendar that **cannot go past 13 years ago** (you cannot pick a younger date). Pick a date, OK.
4. Tap Country, type `ind`. Expected: India and Indonesia only. Type `qqqq`: "No country found". Pick India.
5. Tap **Continue**. Expected: you land on Home.
6. Close the app completely and open it again. Expected: the screen does **not** come back.
7. Sign out, sign in as **user1** (has a date of birth). Expected: straight to Home, no extra screen.
8. Optional: on the first screen, **Sign Out** is the only other way out (there is no skip or back).
9. Optional: switch the app language (Hindi, Arabic) before step 1: the screen text is translated.

To test it again, tell me and I clear user10's date of birth again.

## 2. Fans (people who follow each other)

1. Sign in as **user1**. Open Profile: Followers / Following / **Fans** show their counts. Note them.
2. Search `Staging User 2`, open the profile, tap **Follow**.
3. Open user1's own profile. Expected: Following +1. **Fans is still 0** (a one-way follow is not a fan).
4. Sign out, sign in as **user2**, search `Staging User 1`, tap **Follow** (follow back).
5. Open user2's own profile. Expected: **Fans = 1**. Tap **Fans**: the list shows Staging User 1.
6. Sign back in as user1. Expected: **Fans = 1**, and the list shows Staging User 2. Followers / Following lists still work as before.
7. As user1, unfollow user2. Expected: Fans back to **0** on both sides.
8. Empty list: with Fans = 0, tap Fans. Expected: "No fans yet. Fans are people you follow who follow you back."

## 3. Badges on the profile

1. In the app, open **Staging User 1's** profile (from your own account or user1's own). Expected: two chips under the name, **✔️ Verified** and **👑 Legend**, shown as outlined chips with the badge name.
2. Tap a badge. Expected: the Badges page opens.
3. In the panel: **Platform > Badge Management**, Edit "Verified", upload a **PNG, WebP or GIF** picture (a wide banner is best), Save.
4. Reopen user1's profile in the app. Expected: the Verified badge is now **the picture itself** (about 26 px tall, no text beside it). Badges are drawn **before** tags.
5. Upload an **SVGA or MP4** instead. Expected: the profile shows the plain emoji chip (animations are not played here, to save battery).

## 4. Tags (panel + profile)

In the panel: **Platform > Tags** (Master menu). Expected: the Tags page. Make these three:

1. **Add Tag**, name `Official`, emoji `✔️`, look **Coloured pill**, pick a colour. Watch the live preview. Save.
2. **Add Tag**, name `Viscount`, look **Picture with the name inside it**. Upload a banner PNG/WebP (wide and short, transparent). Save.
3. **Add Tag**, name `Sahi BDM`, look **Background picture, the app writes the name on it**. Upload a plain background. Optionally set a text colour. Save.
4. Try to save a Picture tag **without a picture**: Expected: "Upload a picture for this look…".

Give them to a person (same page, **Give tags to a user**):

5. Search `Staging User 1`, tick the three tags, **Save tags**. Expected: "Tags saved for Staging User 1".
6. In the app open user1's profile (own or from another account). Expected, under the name: the two badges first, then the three tags, each in its look: a coloured pill, the banner picture, and the plate with the name written on it.
7. Panel: set `Official` to **Inactive** and save. Reopen the profile: the Official tag is **gone** from the profile. In the panel it is still listed (dimmed).
8. Panel: **Delete** `Viscount`. Expected: a confirmation naming how many users have it; after deleting, it disappears from the profile.
9. Try to give an Inactive tag to a user who does not have it: it is not offered (only tags they already hold stay tickable).
10. Limit: a user can hold at most **10** tags.

Permission check (optional): sign in to the panel as **superadmin**: Tags is at **User Management > Tags** and works. The Tags switch for other staff accounts is under Access Control ("Tags (give profile tags)"); staging has no lower-role staff account, so that part is covered by the database tests.

## 5. Level pictures instead of stars

The rule: the picture the panel holds for a level replaces the star **for people at exactly that level**; a level without a picture keeps its star; an animated file (SVGA, MP4) keeps the star.

1. Staging users are at Wealth / Charm levels 1 to 4. Wealth level 1 already has an **SVGA**. In the app, open a profile: the level chips are **stars with numbers** (the SVGA is not used as a chip). That is correct.
2. In the panel: **Platform > Levels > Charm**, Edit level **1**, upload a **PNG, WebP or GIF that already shows the number 1**, Save.
3. In the app, open any profile of someone at Charm level 1 (close and reopen the app once so it reads the new picture; it re-reads every 10 minutes). Expected: the charm star is replaced by your picture. The wealth chip is unchanged. People at Charm level 2 to 4 still show a star (they do **not** borrow level 1's picture).
4. The same chip appears in **live chat** and in the **join notice** (when someone enters a live), if lives work on staging.
5. The first time the picture shows, the star stands in for a moment, then the picture replaces it. Turn on airplane mode, reopen: the star shows (the picture is kept on the phone after the first load, so it can also show offline).
6. Remove the image in the panel to put it back.

## 6. Quick checks that nothing else broke

- Sign in and out; edit profile (the date of birth picker also stops at 13 years); Followers and Following lists; the Store tabs.
- The Followers/Following counts still change by one when you follow someone.

## What this does NOT cover

- Live video (staging has no live video unless Agora is set up).
- Real Play install, real traffic, real people's data.
- How it looks on every phone size: tell me what looks off on your phone and send a screenshot.

When all this is fine, the next step is to apply the same two migrations to production (backup, checks, you run the push), then push the panel, then build the Play bundle.
