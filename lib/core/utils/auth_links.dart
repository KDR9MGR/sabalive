import '../../config/supabase_config.dart';

/// True for the link the browser is sent back to after a web sign-in (Apple, Facebook):
/// `com.sabalive.in://login-callback/?code=...`. It is `SupabaseConfig.authRedirectUrl`
/// plus whatever Supabase appends, so only the scheme and host are compared.
bool isAuthCallbackUri(Uri uri) {
  final expected = Uri.parse(SupabaseConfig.authRedirectUrl);
  return uri.scheme == expected.scheme && uri.host == expected.host;
}
