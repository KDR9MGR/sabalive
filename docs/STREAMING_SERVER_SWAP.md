# Streaming server swap (replacing or adding to Agora): assessment and plan

Status (2026-11-04): **a question only. Nothing is decided, built or changed.** The owner said another service is asking to add its SDK "right away" and asked whether that is reliable.
The vendor and the reason for switching are **not known yet** (first thing to ask, see "Open questions"). This file is where to pick the work up.

## Short answer given to the owner
It can be done reliably, but **not "right away"**. Swapping the real-time audio / video layer of a live app is one of the riskier changes there is. A vendor pushing for an immediate
add is itself a warning sign: a good vendor accepts a staged trial. Do not give any vendor repo access, production access, or any key (Agora certificate, `service_role`, SUD / Tulasi secrets).

## What the app has today (surveyed 2026-11-04, read-only)
- Package: `agora_rtc_engine ^6.6.4` (pubspec). Agora is mentioned in about 25 files under `lib/`: `services/agora_service.dart` (295 lines), `pk_channel_switcher.dart`, `local_music_service.dart`,
  `agora_errors.dart`, `state/active_live_session_controller.dart`, `state/pk_battle_controller.dart`, `data/calls_repository.dart`, `data/pk_battles_repository.dart`, `config/agora_config.dart`,
  and the screens `watch_live`, `watch_audio_room`, `live_broadcast`, `go_live_setup`, `pk_battle`, `watch_pk_battle`, `calls/call_screen`, plus `seat_speaking`, `speaking_waves`, `pk_video_uids`, `seat_snapshot`.
- Engine features the app calls (about 20 different ones; a replacement SDK must cover each or the feature is lost or rebuilt):
  `joinChannel` / `leaveChannel`, `registerEventHandler`, `setClientRole` (host / audience), `muteLocalAudioStream`, `muteLocalVideoStream`, `enableLocalAudio`, `enableVideo`, `enableLocalVideo`, `startPreview`,
  `switchCamera`, `setEnableSpeakerphone`, `enableAudioVolumeIndication` (drives the speaking waves), `startAudioMixing` / `stopAudioMixing` / `adjustAudioMixingVolume` (local music),
  `setVideoEncoderConfiguration`, `setDualStreamMode` + `setRemoteVideoStreamType` (low / high quality streams), `setBeautyEffectOptions` + `enableExtension` (beauty filter), `setAudioProfile`,
  `updateChannelMediaOptions` (used when moving between channels), plus the "funny voice" feature.
- Server side: Edge Function `supabase/functions/agora-token` mints the token. It decides who may speak (`seat_access.ts`), who may publish in a PK battle (`battle_access.ts`), lets ghost / Super Admin watch invisibly,
  logs who was given a speaking token (`agora_token_log`), and also enforces bans (`live_access_denied_reason`). Every token uses uid 0 and the SDK assigns the real uid. A new vendor means all of this is rebuilt for its token scheme.
- Data that depends on Agora: `live_stream_seats.agora_uid` (Agora uids are UNSIGNED 32-bit: stored as bigint) maps a seat to the speaking-waves ring. Channel name = `live_streams.id`; PK uses `pk-<battleId>`
  (`PkChannelSwitcher`: everyone in both rooms moves to the shared channel and back).
- Size and cost facts: the arm64 download is about 75 MB; the Agora SDK is 12.4 MB plus about 17 MB of Agora extensions (see `docs/OPTIMIZATION_AND_SUPABASE_2026-10-23.md`, item A3: trimming unused extensions is a separate, untested idea).
  Agora quota history: the free 10,000 minutes ran out on 2026-10-03 / 04 and the account was topped up to 25,000; HD video lives were roughly two thirds of the billed minutes. Cost per viewer-minute for video is therefore the likeliest reason to look at another vendor.

## Why "add it right away" is not reliable
1. **Old app versions stay in pockets for months** (root CLAUDE.md). They keep using Agora. People on two different media providers cannot see or hear each other, so a swap is NOT a replacement: the new provider must run
   **next to** Agora, chosen per live room, and the Agora project, token function and secrets must stay. Only a minimum-version gate (set only after the new build is live on Play at 100%) could retire the old path.
2. **Breadth of features** (list above): beauty filter, dual stream, audio mixing, volume indication and channel switching may not exist or may behave differently in another SDK.
3. **A second media engine in the same app**: more native libraries (download size), possible audio-session / WebRTC conflicts, start-up crash risk, battery and heat (the app is already tuned for heat; see CLAUDE.md "Live room internals"),
   and a third party with microphone and camera access in our process.
4. **Store paperwork**: Google Play's Data safety form and Apple's privacy manifest must declare what the SDK collects. A mistake there can get the app pulled.
5. **Quality in India is unproven**: latency, packet loss on 4G, regional servers, audience size per room. Only a side-by-side test on real phones answers that.

## How to make it reliable (proposed order; none of it started)
1. **Paper check first** (no code): vendor feature checklist against the list above; Flutter plugin health (maintained by the vendor? last release, Android 16 / targetSdk 36 and 16 KB page-size support, iOS support);
   price per minute for audio and for video, billing of viewers vs hosts; servers in India; SLA and uptime history; how tokens / auth work; what the SDK collects; references from a similar live-streaming app.
2. **Staging only**: build behind a switch that is OFF by default (a release control / feature flag like `pk_battles`), on the staging Supabase project (`gsloixbaktefwgxzjtps`), one real phone first. Start with the simplest case, an **audio room**;
   leave video, PK and 1:1 calls for later.
3. **Per-room provider** (proposal, not built): an additive column such as `live_streams.rtc_provider text default 'agora'` and a capability marker for new builds, the same idea as `live_streams.pk_ready` (old builds are never shown a room they cannot join).
   New builds choose the provider when a live starts; everyone joins with the provider the room uses. Additive only (root CLAUDE.md "Only add while old apps are live").
4. **Side-by-side measurement on the same phones and network**: join success rate, time to first picture / sound, freezes, audio drops, battery and heat, crash-free rate, bytes per minute.
5. **Small cohort in production**: own test accounts first, then a small share; Agora stays as the instant fallback (flip the switch, no release needed).
6. **Parity work** only after the above looks good: server rules (seat / battle tokens, bans, ghost watch), speaking indicator, music, beauty, PK channel switching, calls.
7. **Judge cost properly** with your own numbers, not the vendor's: price per viewer-minute for video lives against what Agora billed in October.

Rough size (to be confirmed by the paper check): an audio-room proof of concept in days; parity with video, PK, calls and the server rules in weeks.

## Open questions (ask the owner first)
- **Which service** is it, and who at the vendor is asking? Link to its Flutter SDK and pricing page.
- **Why switch**: cost, quality in India, a feature Agora lacks, or a commercial deal? The answer sets what "success" means for the trial.
- What exactly was promised: free credit, revenue share, a time limit on the offer?
- Does the owner want to replace Agora completely, or use the new service for part of the traffic (for example audio rooms only)?
- Timing: not in the same release as other risky changes; the version code is not bumped unless the owner asks (root CLAUDE.md).

## Guardrails (from the project rules)
- Nothing against production without the owner's explicit go in that conversation (migrations, functions deploy, a release). Rehearse on staging first.
- No vendor keys in chat, repo or commits; the Agora certificate and `service_role` stay in Edge Function secrets; the panel only ever holds the anon key.
- Only additive database changes while old apps are live; the 60-connection limit means no new polling per client.
- Release bundles are built with `scripts/release/build_play_bundle.sh`; no version bump or build unless asked.
- Keep `HANDOFF.md` (not in git) updated after each step.

## Candidate named by the owner (2026-11-04): LiveCore, a hosted LiveKit
- Docs: https://livecore.cloud/docs/getting-started. It "runs the open-source LiveKit server for you": same LiveKit client SDKs (Flutter, JS, Swift, Kotlin, React Native, Unity) and server SDKs for minting tokens (Node, Go, Python ...); an app changes only the host URL and key / secret.
  NOT LiveKit's own cloud (`livekit.cloud`). Operator per its page: MS Group Ltd, Dhaka, Bangladesh. Billing: two meters, participant minutes and data out (daily totals final 12 h after the day ends, UTC).
- NOT stated on the page: free-trial limits or expiry, regions (India / Mumbai?), prices, SLA, limitations. Ask the vendor before any plan: India region, SLA and uptime history, price per participant-minute and per GB, max participants per room, support hours, data handling.
- The owner posted a trial host plus an API key and secret IN CHAT. Treat that key / secret as exposed: they are NOT recorded anywhere (not here, not in the repo). Use them only for a staging test; the owner sets them himself as Edge Function secrets on the STAGING project
  (`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `supabase secrets set` with the staging link folder), regenerates the secret before anything beyond a trial, and production gets its own. The app only ever receives the URL and a short-lived token from a new function (for example `livekit-token`, additive, next to `agora-token`).
- Likely gaps against what the app uses today (verify in the paper check, none confirmed): no built-in audio mixing for the host's music, no built-in voice changer ("funny voice"), no built-in beauty filter. LiveKit does have simulcast (the dual-stream idea), active-speaker events (speaking waves),
  subscribe-only participants through token permissions (viewers), and per-room tokens (seat / battle rules could be expressed as token grants). A PK battle would be a room switch (leave + join), like `PkChannelSwitcher` does today.
- Answer given to the owner: does it affect the live app? NOT while it is planning / staging work or an additive build with the switch OFF; a hard swap WOULD (old builds only speak Agora). So: side by side, per room, behind a switch.

## Step 1 (owner said "lets go with this for staging", 2026-11-05): paper check + staging groundwork. NOTHING in the app, production or Agora changed.
Paper check of LiveCore (public pages only; none of this was confirmed with the vendor):
- **Region**: one, Mumbai, India (good for our users). A dedicated "Peak" cluster can be placed elsewhere (price not listed).
- **Price**: Starter $50/month = 200,000 participant minutes + 0.4 TB out; Launch $300 = 1.5M min + 3 TB; Growth $500 = 3M min + 6 TB; Scale $1,000 = 8M min + 16 TB; overage at most +20% per unit. Rooms, API calls and data in are free.
  A participant minute counts the HOST AND EVERY VIEWER (like Agora's per-user minutes). Compare with October's Agora invoice before believing it is cheaper: a viewer-minute in video is the big number.
- **No free trial is described on the pages**; there is no self-serve sign-up (sales form / WhatsApp / email; they say a tenant is usually set up the same day). The owner has a trial host: its limits and end date are unknown, ask.
- **Not stated**: SLA or uptime, max participants per room, tenant quotas (shown in their Account page), data handling, who the company's other customers are. Automatic failover of a media node is claimed.
- **Not available yet**: recording (egress) and stream pulling (ingress). We do not use them today.
- **Flutter SDK**: `livekit_client` 2.13.2 on pub.dev (verified publisher livekit.io, Apache-2.0; Android, iOS, web, desktop; iOS 12.1+). The pub page does not say whether Android 16 KB page-size builds are covered: check the changelog and the `flutter_webrtc` native library before shipping (Play requires it for targetSdk 35+).
- **Feature gaps against what the app uses** (docs read): no audio-mixing call for the host's music in the LiveKit docs (a custom audio source is documented only for server SDKs, Python), no voice effects, no beauty filter. Speaking detection (`ActiveSpeakersChanged`), subscribe-only viewers, hidden participants (our ghost watch) and per-room grants exist.
  So: AUDIO rooms without host music are the natural first target; video lives (beauty filter) and the music feature would stay on Agora.
- Token format: a plain HS256 JWT (`iss` = key, `sub` = identity, `video` grant). LiveCore adds a tenant prefix to room names itself.

What was built (all additive, none of it reachable from the app or from production):
- `supabase/functions/livekit-token/` : `index.ts` (same checks as `agora-token`: signed-in user, `live_access_denied_reason` bans, only the host or a seat that really gives the mic may publish via `seat_access.ts`,
  guest token 600 s, PK arena via `battle_access.ts`, ghost = view-only AND `hidden`), `livekit_jwt.ts` (hand-signed HS256, no vendor package), `grants.ts`, 8 tests (`scripts/test_functions.sh` picks them up).
  The identity is the Supabase user id, so "who is talking" maps straight to a seat's occupant and no `agora_uid`-style table is needed.
  It imports the two rule files from `../agora-token/` (read only: `agora-token` itself is not changed).
- DEPLOYED TO STAGING ONLY (`gsloixbaktefwgxzjtps`, 2026-11-05): answers 500 "LiveKit credentials are not configured on the server" until the three secrets are set, which is the correct state.
- `scripts/staging/livekit_setup.sh --deploy | --secrets | --check`: refuses the production project; `--secrets` reads `~/sabalive-secrets/livekit-staging.env` (mode 600, three lines `LIVEKIT_URL=wss://...`, `LIVEKIT_API_KEY=...`, `LIVEKIT_API_SECRET=...`, made by the OWNER) and never prints a value.
- `scripts/livekit_probe/` : `mint_token.mjs` (token from the same env file, 30 minutes) and `index.html` (browser page: connect, microphone, who is speaking, connection quality, round trip, jitter, packet loss) to judge the vendor from the owner's own network before any app work.

NEXT, in this order (each waits for the previous result):
1. Owner creates `~/sabalive-secrets/livekit-staging.env` (the key and secret he pasted in chat count as exposed: ask LiveCore to rotate them first, then use the new pair) and runs `scripts/staging/livekit_setup.sh --secrets`.
2. Probe on a laptop (two tabs), then ask a friend on a phone browser/4G: voice quality, delay, jitter, loss. If it is poor, stop here: nothing in the app was touched.
3. Only if it is good: a staging-only app build with `livekit_client` behind a Release control that is OFF by default, audio room first (an additive `live_streams.rtc_provider` column, a provider picked per room). The APK size and a 16 KB page-size check come before any production build.

## Status update 2026-11-06 (step 1 on staging: server side DONE, nothing in the app)
- The owner put `~/sabalive-secrets/livekit-staging.env` in place (mode 600; the names in it are `LIVECORE_URL` / `LIVECORE_API_KEY` / `LIVECORE_API_SECRET`: `scripts/staging/livekit_setup.sh` and `scripts/livekit_probe/mint_token.mjs` accept those as well as `LIVEKIT_*`).
- `scripts/staging/livekit_setup.sh --secrets` set the three values on STAGING (never production). `--check` now answers `HTTP 401 You must be signed in to request a streaming token` (it said `500 credentials are not configured` before): the `livekit-token` function is alive and has its secrets.
- The server accepts a token signed with that key and secret and refuses a wrong one: `GET <host>/rtc/validate?access_token=...` returns 200 `success` (and 401 `bad_signature` for a wrong token), about 14-23 ms from India once warm (first call 117 ms). The host is `<name>.livecore.cloud`.
- NOT done: the full media probe (a browser with a microphone joins a room and audio / video flows: `scripts/livekit_probe/index.html` + `mint_token.mjs`), the Flutter client (`livekit_client` is NOT in pubspec: the app is 100% Agora), the per-room switch, any production step. The key and secret were pasted in chat once earlier: the owner was told to ask LiveCore to rotate them.

## Status update 2026-11-06 (later): the app can run lives on MS cloud (STAGING build only)
Owner: "bring the app also on MS cloud, as going point app to staging and once done give me apk". Built as a PARALLEL path next to Agora, chosen per room (`live_streams.rtc_provider`, migration `20261106130000`), exactly the shape this plan recommended: Agora code stays, old apps keep working, a production build cannot start MS cloud lives.
What exists and what does not is written in `CLAUDE.md` ("MS cloud (hosted LiveKit server) next to Agora"). In short: audio rooms and video lives work through `lib/services/livekit_session.dart`; PK, music, beauty, funny voice, calls and the panel's Live Monitor stay Agora-only. Nothing was tried on a real phone by the assistant: the first device test decides whether audio level / echo (Android audio mode), the seat role-change reconnect and long-session token refresh need work.
Found while checking: the LiveCore server wants `canPublishSources` as numbers (see CLAUDE.md); `livekit-token` was fixed and redeployed to staging.

