/// Agora project connection details for SABALIVE.
///
/// The App ID identifies the project only and is safe to ship in the client
/// — it's meaningless without a token. The App Certificate is never
/// referenced here; it stays server-side as a Supabase Edge Function secret
/// (see supabase/functions/agora-token) and is used only to mint short-lived
/// RTC tokens on demand.
class AgoraConfig {
  AgoraConfig._();

  static const String appId = '700928684d8741f2804fbb10d4304b2e';
}
