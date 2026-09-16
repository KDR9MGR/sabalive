/// Supabase project connection details for SABALIVE.
///
/// The anon/publishable key is safe to ship in the client — it identifies the
/// project only, and every table it can touch is gated by Row Level Security
/// policies defined in `supabase/migrations/`. The service-role key is never
/// referenced here; it stays server-side (Edge Function secrets) only.
class SupabaseConfig {
  SupabaseConfig._();

  static const String url = 'https://sfehzhtqtpuobnrvzvzp.supabase.co';
  static const String publishableKey =
      'sb_publishable_vdDsGi-wEgeJm_BpQE7MlA_Z5ZusWOi';

  /// Deep link the OS hands back to this app once a social (Apple/Google/
  /// Facebook) sign-in finishes in the browser. Registered as a custom URL
  /// scheme on both platforms (iOS `CFBundleURLTypes`, Android's
  /// `MainActivity` intent-filter) — must also be added to Supabase
  /// Dashboard → Authentication → URL Configuration → Redirect URLs, or the
  /// provider will reject the redirect.
  static const String authRedirectUrl = 'com.sabalive.in://login-callback/';
}
