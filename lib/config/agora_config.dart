/// Agora project connection details for SABALIVE.
///
/// The App ID identifies the project only and is safe to ship in the client
/// — it's meaningless without a token. The App Certificate is never
/// referenced here; it stays server-side as a Supabase Edge Function secret
/// (see supabase/functions/agora-token) and is used only to mint short-lived
/// RTC tokens on demand.
class AgoraConfig {
  AgoraConfig._();

  /// The live project's App ID. Every normal build uses it.
  static const String productionAppId = '700928684d8741f2804fbb10d4304b2e';

  /// Production unless the build is started with `--dart-define=AGORA_APP_ID=...` (a staging build that
  /// uses its OWN Agora project, so testing never spends production's minutes). The server's token must be
  /// minted for the same App ID, so staging's `agora-token` function needs that project's secrets.
  static const String appId = String.fromEnvironment('AGORA_APP_ID', defaultValue: productionAppId);
}
