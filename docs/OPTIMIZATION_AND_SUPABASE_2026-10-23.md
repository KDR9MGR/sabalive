# How SABALIVE talks to Supabase, what costs what, and the optimisation plan (2026-10-23)

Written from the code, the release bundle and your Supabase usage screenshot. Numbers marked **measured** come from the code or the bundle; numbers marked
**estimate** are reasoning, not production data (I have not run any query on production for this).

## 1. How Supabase works, in plain words

Supabase is one hosted PostgreSQL database with five services in front of it. Think of a restaurant: the database is the kitchen, the services are the waiters.

| Service | What it does | Who uses it here |
|---|---|---|
| **Database (Postgres)** | Holds every table: profiles, lives, chat, wallets, gifts. The rules (who may read or change what) live inside it as *row level security* and as *functions* (`join_live_stream`, `send_gift`, ...). | everything |
| **REST API (PostgREST)** | Turns every table and function into a web address. `supabase.from('profiles').select()` in the app is one HTTPS request; the API runs the SQL as the signed-in user, so the database rules apply. | app and panel, every screen |
| **Auth** | Sign-in. Gives the app a token; every request carries it, and the database knows who is asking. | app and panel |
| **Realtime** | Watches the database's change log. Anyone who *subscribed* to a table gets each change pushed to them over a websocket, no polling. Every row change is sent to **every** subscriber (after a permission check), and each delivery counts as one **Realtime message**. | live chat, seats, wallet, the live list |
| **Storage** | A file store (like S3) behind a CDN. Public files (avatars, gift pictures, effects, frames, banners) are fetched by a plain web address. Bytes served from the CDN cache are **Cached Egress**. | every picture and effect |
| **Edge Functions** | Small server programs for things the app must not do itself (make an Agora token, send a push). Counted as *invocations*. | live join, push |
| **pg_cron** | The database's own timer: cleans stale lives, delivers announcements, pays Lucky Box. | background jobs |

**The app and the panel are the same kind of client.** Both are programs on someone's device with the public key; neither has special powers. The *database*
decides what each signed-in person may do (that is why a Master can do more than a user: their row says so). The panel is a website (React) that asks the same
API; it loads whole tables into the browser and filters there. The app asks for only what a screen needs and listens to Realtime for live data.

**Your plan's limits (Micro compute):** 60 direct database connections, a small shared CPU, and monthly quotas for each meter. The meters in your screenshot:

| Meter | Your use | What it counts | Verdict |
|---|---|---|---|
| **Cached Egress** | 325 / 250 GB (**130%**) | bytes of Storage files served from the CDN: every picture / effect a phone downloads | **over quota**: the biggest money problem |
| **Realtime Messages** | 4.33M / 5M (**87%**) | every row change x every phone listening to it | about to go over |
| Log Ingestion | 13.8 / 20 GB (69%, billed soon) | one log line per API request | grows with the number of requests |
| Egress | 20 / 250 GB (8%) | API / database bytes | fine |
| Edge Functions | 143K / 2M (7%) | invocations | fine |
| Realtime peak connections | 34 / 500 | | fine |
| Micro compute | $7.98 | | the small CPU is shared by everything below |

Everything on this plan is multiplied by **how many requests and messages each phone makes**. So the cheapest fix is almost never "buy more": it is *make each phone ask less*.

## 2. What I found (measured in the code)

1. **The live list re-downloaded itself constantly.** `LiveStreamsController` lives for the whole session and listened to *every* change of the `live_streams` table. Every host
   heartbeat (every 30 s per live), every join, leave, like and gift is such a change. On each one it re-read the whole list (a full download with every host's full profile)
   at most every 1.5 s, so on a busy evening **up to 40 full reloads a minute per phone**, even while the user was inside a live or the app was in the background.
   It also made the server send those changes to every phone (Realtime messages) and made every phone parse and rebuild Home (heat, battery).
2. **Viewers re-read the seats every 10 s** (two queries, with profile rows) as a safety net behind Realtime: 12 queries a minute per viewer in every room.
3. **The server rewrites a row on every heartbeat, even if nothing changed.** `heartbeat_seat` (each person on a seat, every ~30 s) and `heartbeat_stream` (each host, every 30 s) do a plain
   UPDATE. Postgres broadcasts an UPDATE even when the values are identical, so each heartbeat is delivered to **everybody watching that room (seats) or listening to the list (lives)**.
   In a room with 8 people on seats and 100 viewers that is about 8 x 2 x 100 = **1,600 messages a minute that carry no information**. (Viewer heartbeats were already fixed in 2026-09; these two were not.)
4. **Avatars were decoded at their upload size.** The picker uploads photos up to 1024 px; the app drew a 26 to 60 px circle from a 4 MB decoded bitmap. A room of avatars filled the image cache,
   so pictures were dropped and downloaded again as you scrolled: more heat, more memory, more bytes. There is also **no disk cache for pictures**: every app start downloads them again.
5. **The download is 75 MB for an arm64 phone** (measured on the +12 bundle). 51 MB of it is native libraries; the **Agora SDK is 12.4 MB** plus about **17 MB of Agora "extensions"**
   (lip sync 5.8, spatial audio 3.2, segmentation 1.4, face capture 1.4, content inspect 1.1, video quality analyser 1.0 ...) of which the app code uses only the clear-vision beauty filter.
   Everything else is small: Flutter 5.3, your code 5.0, pictures 4.4, the splash video 2.3, the PK animations 3.3.
6. **Duplicated code:** the five live screens are 8,700 lines (`live_broadcast` 2,565, `watch_live` 1,866, `watch_audio_room` 1,842, `pk_battle` 1,362, `watch_pk_battle` 1,057). Eighteen methods appear in three or more of
   them (subscribe to seats, seat sync, load chat, join, gifts, quick emoji, reconcile seats ...). Each screen also starts its own heartbeat timer, seat timer and 4 to 6 Realtime channels.
7. **The panel** is one 1.2 MB JavaScript file, has 50 `select('*')` calls, loads whole tables into the browser (`profileOptions` reads up to 1000 profiles for every user picker), and
   three dashboard widgets poll on timers.

## 3. What I changed today (committed, in the next build, no feature removed)

| Change | Effect (estimate) |
|---|---|
| Live list: at most **one reload per 8 s** (the first event after a quiet spell still runs at once) | up to 40 reloads a minute **down to about 7**: about 80% fewer downloads, parses and Home rebuilds on a busy evening |
| Live list **stops listening** while the app is in the background or a live is open full-screen, and reads once, fresh, when you are back | the server stops sending that phone the list's changes for most of its session: **large Realtime saving**, and no work while you are watching a live |
| Viewers re-read seats every **20 s** instead of 10 s (the host keeps 10 s) | half the steady seat queries per viewer |
| Avatars, live-card photos, game pictures, tag and badge pictures **decoded at the size drawn** | about 25x less memory per avatar, far fewer evictions and re-downloads, less heat |

Tests: 908 pass (new ones for the throttle, the listening rules, background / live-room behaviour, and the avatar decode size).

## 4. What I recommend next, in order of value

**A. Needs only the app (safe, I can do on your word):**

| # | What | Why / effect | Risk |
|---|---|---|---|
| A1 | **Keep pictures on the phone** (disk cache for avatars, frames, gift and store pictures, using the cache the app already has for effects) | the main lever on **Cached Egress** (325 GB): a picture is downloaded once per phone, not once per start | low |
| A2 | **Measure, then shrink effect files** (gift MP4 / SVGA, frames): sizes, count of plays, cap and re-encode | effects are the biggest files; likely the other half of Cached Egress | low, needs the numbers (see C1) |
| A3 | **Trim unused Agora extensions** (about 14 MB off the 75 MB download, about 20% smaller) | smaller install, faster updates | needs a **real-phone test** of video live, audio live, PK and the beauty filter |
| A4 | Compress the bundled pictures (4.4 MB) to WebP and re-encode the splash video (2.3 MB) | about 4 MB | low |
| A5 | **Retire the legacy PK screens** (`pk_battle_screen`, `watch_pk_battle_screen`: 2,400 lines, 10 Realtime channels) once the new PK flow is confirmed on phones (your earlier plan, WP7) | less code, fewer channels | low after verification |
| A6 | **One shared live-room session class** for join, heartbeat, chat, seat sync and the channels the five screens each repeat | the real "re-use code" job: about 3,000 fewer lines, one set of timers, one place to fix a bug | medium: touches every live; needs two-phone tests; do after A5 |

**B. Needs a database change (your go, staging first, then production with the usual checklist):**

| # | What | Effect |
|---|---|---|
| B1 | **Stop heartbeats from broadcasting.** Keep each heartbeat's time in a small table that is *not* in Realtime, and have `heartbeat_seat` / `heartbeat_stream` write there (same names, so **old apps benefit too**), with the cleanup jobs reading it | removes the "1,600 empty messages a minute" class: the largest remaining Realtime saving |
| B2 | Look at slow / frequent queries (`pg_stat_statements`) and add indexes or slim selects (the live list selects every column of every host) | lower CPU on the Micro instance |
| B3 | Only then think about a bigger compute size: it costs money and the cause is request volume, not capacity | |

**C. Measurements I need your go for (read-only on production, no user data, sizes and counts only):**

| # | Query | Why |
|---|---|---|
| C1 | Storage: bytes and file count per bucket, the 30 largest files | to see exactly what the 325 GB is made of |
| C2 | `pg_stat_user_tables`: updates per table since the last reset | to prove which table produces the Realtime messages (live_streams, live_stream_seats, chat) |
| C3 | `pg_stat_statements`: the 20 most expensive queries | to see what loads the CPU |

**D. Panel (when you want):** lazy-load pages (the 1.2 MB file becomes about 6 small ones), replace the 1000-row pickers with search, page the big tables on the server and
select only needed columns, make the three dashboard timers pause when the tab is hidden.

## 5. Phone heat and battery: what actually causes it, and where we stand

Heat comes from the CPU / GPU working and the radio staying awake. In this app the sources are: video (Agora decoding), looping animations (avatar frames, speaking waves, SVGA effects),
JSON parsing and screen rebuilds triggered by Realtime bursts, decoding big pictures, and **a timer or request every few seconds, which keeps the mobile radio out of its idle state**.
Already in place from earlier work: frames animate only above 48 px and can be switched off from the panel; the charm star shimmers once in chat; no blur filters; the host clock does not rebuild the screen.
Added today: fewer reloads and no listening when the list is not visible (first and third causes), smaller decoded pictures (fourth). Next: A1 (no repeated downloads) and B1 (no empty broadcasts).

## 6. What is NOT worth doing

- Buying a bigger plan before cutting request volume: the multiplier stays.
- Removing the join notices or chat lines to save messages: they are features, and they are not the waste (heartbeats are).
- Supabase image transformations: the plan allows 100 images, so resizing must happen when the picture is uploaded (the app already caps at 1024 px; 512 px would be plenty and is a one-line change, but existing pictures stay as uploaded).
