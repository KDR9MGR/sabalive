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
///   IAP — not chosen yet). Buy Coins currently credits coins via a
///   `dev_purchase_coins` dev RPC regardless of the method shown, so the
///   UPI/Card/Net Banking/Wallet picker is fake and stays hidden until a
///   gateway is wired behind it.
///
/// ⚠️ Still on the pre-production checklist — wire the real thing behind it
/// before shipping to real users.
class FeatureFlags {
  FeatureFlags._();

  static const bool socialLoginEnabled = true;
  static const bool paymentMethodsEnabled = false;
}
