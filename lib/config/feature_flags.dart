/// Switches for UI that's deliberately hidden during the alpha because the
/// backend behind it isn't real yet. Flip these to `true` — and remove this
/// comment's checklist item — as each backend piece actually lands:
///
/// - [socialLoginEnabled]: ON. Verified live against Supabase's `/authorize`
///   endpoint on 2026-09-15 — Google is configured (real redirect to
///   Google's consent screen); Apple and Facebook are not
///   (`"Unsupported provider: provider is not enabled"`). `SocialRow`
///   ([auth_scaffold.dart](lib/features/auth/widgets/auth_scaffold.dart))
///   shows only Google + Apple per product decision — Facebook stays out
///   until there's a reason to add it back. Tapping Apple right now opens
///   the browser to that raw Supabase error until its provider is
///   configured in the dashboard (Auth → Providers → Apple) and Apple
///   Developer's Services ID Return URL is set — see
///   `SupabaseConfig.authRedirectUrl`.
/// - [paymentMethodsEnabled]: needs a real payment gateway (Razorpay/Stripe/
///   IAP — not chosen yet). The UPI/Card/Net Banking/Wallet picker is fake
///   and stays hidden until a gateway is wired behind it. Buy Coins' Pay
///   button also checks this flag directly (2026-09-21, per Rey) — it used
///   to call `dev_purchase_coins` (a test RPC that instantly grants coins,
///   no real charge) regardless of this flag, so tapping Pay silently gave
///   free coins. Now shows "coming soon" instead while this is false.
/// - [pkBattleEnabled]: PK Battle mode stays visible throughout the app
///   (Go Live's mode picker, the host tools sheet's Invite/Random PK tiles,
///   the Home/Live-feed PK filter) so people know it's coming, but every
///   place that would actually start or join one shows "coming soon"
///   instead while this is false (2026-09-28, per Rey). Go Live's PK tab
///   checks this directly since it's the one remaining action that used to
///   create a real PK stream; the tools-sheet tiles were already gated this
///   way before this flag existed.
///
/// - [callsEnabled]: voice/video calls between users are hidden everywhere
///   (the two call buttons in a chat, the incoming-call banner, and the
///   realtime listener for incoming calls — it is not even started while
///   this is false). Per product decision (2026-10-01) the app has no calling
///   for now. The calls code is left in place; flip this to bring it back.
///
/// ⚠️ Still on the pre-production checklist — wire the real thing behind it
/// before shipping to real users.
class FeatureFlags {
  FeatureFlags._();

  static const bool socialLoginEnabled = true;
  static const bool paymentMethodsEnabled = false;
  static const bool pkBattleEnabled = false;
  static const bool callsEnabled = false;
}
