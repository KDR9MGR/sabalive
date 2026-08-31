# SABALIVE

Social live-streaming + video/audio chat + virtual-gifting app (Flutter).

This repo currently contains the **core app shell + key flows** built to match the
SABALIVE reference design (dark theme, purple / pink / gold brand accents,
neon glows, Poppins type). UI is wired to an in-memory state layer with fake
services — no real backend, streaming SDK, or payments yet.

## Run

```bash
flutter pub get
flutter run
```

Poppins is bundled under `assets/fonts/`, so the app renders fully offline.
Stream thumbnails and avatars are **procedural gradients** (`AppThumb`,
`AppAvatar`) — no network images — so nothing breaks without connectivity.

## What's implemented

| Area | Screens |
| --- | --- |
| Onboarding | Splash, 3-page onboarding |
| Auth | Login (email/phone/username + social), Sign Up, OTP verify, Forgot Password |
| Discover | Home feed (banner, categories, live grid, trending) |
| Live | Live feed, Watch Live (chat overlay, floating hearts, gift burst), Send-Gift sheet, Go Live setup, Host broadcast |
| Social | Messages list + requests, Chat conversation |
| Rankings | Hosts / Gifters / Rising · Daily / Weekly / Monthly, podium + list |
| Profile | Profile, Edit Profile, Notifications, Settings |
| Economy | Wallet (coins + diamonds + transactions), Buy Coins |

Bottom nav: Home · Live · Messages · Rankings · Profile.

## Structure

```
lib/
  main.dart                 app entry + system chrome
  app.dart                  MaterialApp + providers + auth gate
  theme/                    colors, gradients, ThemeData, text theme
  core/
    utils/                  formatters (compact counts, initials, relative time)
    widgets/                GradientButton, GlowCard, AppAvatar, AppThumb,
                            SabaLogo, OtpInput, AuroraBackground, pills, …
  data/
    models.dart             plain data classes
    mock_data.dart          static sample content
  state/                    ChangeNotifier controllers (Provider)
    auth_controller.dart    fake login / OTP / sign-up / profile
    wallet_controller.dart  in-memory coin + diamond balance, gifts
    session_controller.dart follow set, liked streams, selected tab
  router/app_nav.dart       typed push helpers for detail screens
  features/<area>/          one folder per feature area
```

## Wiring a backend later

- `state/*_controller.dart` — swap the simulated `Future.delayed` bodies for real
  API / SDK calls; the widgets already listen via `context.watch`.
- `AppThumb` / `AppAvatar` — add a network image layer with the gradient as the
  fallback.
- Live streaming / calls — integrate an RTC SDK (Agora, LiveKit, …) behind a
  `StreamRepository`; `WatchLiveScreen` / `LiveBroadcastScreen` render the UI.
- Payments — replace `WalletController.buyCoins` with a real IAP / PSP flow.
