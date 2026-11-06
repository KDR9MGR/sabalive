/// Which real-time audio / video server carries a live room (owner, 2026-11-06; docs/STREAMING_SERVER_SWAP.md): [agora] (what every room has used so far) or [livekit] (the hosted
/// LiveKit server, "MS cloud" / LiveCore, through the `livekit-token` function). A room is on ONE provider for its whole life: the host's app writes it on the room
/// (`live_streams.rtc_provider`, sabalive migration 20261106130000) and every viewer's app reads it to know which one to join.
enum RtcProvider {
  agora,
  livekit;

  /// What the database stores.
  String get dbValue => name;

  /// A stored value -> a provider. Anything unknown, missing or empty (every older room and older database) is Agora.
  static RtcProvider fromDb(Object? value) => value == 'livekit' ? livekit : agora;
}

abstract final class RtcConfig {
  /// `--dart-define=RTC_PROVIDER=livekit` makes the lives THIS build starts run on MS cloud. Production builds never set it (and [AppEnvironment.validate] refuses one that does), so a
  /// Play build starts Agora rooms only. The staging scripts (`build_apk.sh`, `run_app.sh`) set it to livekit.
  static const String _wanted = String.fromEnvironment('RTC_PROVIDER', defaultValue: 'agora');

  /// The provider a NEW live made on this build uses.
  static RtcProvider get forNewLives => RtcProvider.fromDb(_wanted);

  /// Used by tests and by the environment guard.
  static RtcProvider parse(String? value) => RtcProvider.fromDb(value);
}
