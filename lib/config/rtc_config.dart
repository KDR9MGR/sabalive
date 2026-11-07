import '../state/remote_config_controller.dart';

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
  /// `--dart-define=RTC_PROVIDER=livekit` FIXES the provider of the lives this build starts. Only the staging scripts (`build_apk.sh`, `run_app.sh`) set it; a production build must not
  /// ([AppEnvironment.validate] and `build_play_bundle.sh` refuse one that does). Empty = the build does not fix it and the server switch decides.
  static const String _fixed = String.fromEnvironment('RTC_PROVIDER');

  /// The Release control (panel -> Application Config -> Release controls, Super Admin) that sends the lives people START from now on to MS cloud. Off (the default) = Agora.
  static const String serverSwitch = 'rtc_livekit_new_lives';

  /// The provider this build fixes at build time, or null when it does not (every Play build).
  static RtcProvider? get fixedByBuild => _fixed.isEmpty ? null : RtcProvider.fromDb(_fixed);

  /// The decision itself: a provider fixed by the build wins; otherwise the server switch (on = MS cloud, off or unknown = Agora).
  static RtcProvider resolve({required String fixedByBuild, required bool serverSwitchOn}) {
    if (fixedByBuild.isNotEmpty) return RtcProvider.fromDb(fixedByBuild);
    return serverSwitchOn ? RtcProvider.livekit : RtcProvider.agora;
  }

  /// The provider a NEW live made now uses: fixed by the build (staging) or, on a Play build, whatever the server switch says at this moment (Agora until the owner turns it on).
  /// A live is on ONE provider for its whole life, so flipping the switch never moves a live that is already running.
  static RtcProvider get forNewLives => resolve(
        fixedByBuild: _fixed,
        serverSwitchOn: RemoteConfigController.instance.flag(serverSwitch, defaultValue: false),
      );

  /// Used by tests and by the environment guard.
  static RtcProvider parse(String? value) => RtcProvider.fromDb(value);
}
