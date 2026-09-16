import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/agora_config.dart';
import '../config/supabase_client.dart';

class AgoraToken {
  AgoraToken({required this.token, required this.appId, required this.channelName, required this.uid});
  final String token;
  final String appId;
  final String channelName;
  final int uid;
}

/// Owns the single shared [RtcEngine] instance for the app. One live screen
/// (broadcast or watch) at a time holds it via [ensureEngine]/[release] —
/// Agora's SDK is not designed to run multiple engines concurrently.
class AgoraService {
  AgoraService._();
  static final AgoraService instance = AgoraService._();

  RtcEngine? _engine;

  Future<RtcEngine> ensureEngine() async {
    final existing = _engine;
    if (existing != null) return existing;
    final engine = createAgoraRtcEngine();
    await engine.initialize(RtcEngineContext(appId: AgoraConfig.appId));
    await engine.enableVideo();
    // Raw SDK defaults are 960x540@15fps and a generic audio profile — too
    // soft for a live-streaming app. Portrait HD at 30fps with an
    // auto-managed bitrate is the standard profile for vertical social
    // live streaming; the chatroom audio scenario suits seats/guests
    // joining and leaving mid-stream.
    await engine.setVideoEncoderConfiguration(const VideoEncoderConfiguration(
      dimensions: VideoDimensions(width: 720, height: 1280),
      frameRate: 30,
      bitrate: 0, // standardBitrate — SDK auto-picks the optimal bitrate
      orientationMode: OrientationMode.orientationModeAdaptive,
    ));
    await engine.setAudioProfile(
      profile: AudioProfileType.audioProfileDefault,
      scenario: AudioScenarioType.audioScenarioChatroom,
    );
    _engine = engine;
    return engine;
  }

  /// Auto-renews the channel token before it expires, so a stream or call
  /// doesn't silently drop after the token's ~1h TTL. Registered as its own
  /// handler (Agora invokes every registered handler), separate from each
  /// screen's own UI event handler.
  void registerAutoTokenRenewal(
    RtcEngine engine, {
    required String channelName,
    required bool asBroadcaster,
  }) {
    engine.registerEventHandler(RtcEngineEventHandler(
      onTokenPrivilegeWillExpire: (connection, token) async {
        try {
          final fresh = await fetchToken(channelName: channelName, asBroadcaster: asBroadcaster);
          await engine.renewToken(fresh.token);
        } catch (_) {
          // Best-effort — if this fails the SDK will surface a connection
          // failure via onConnectionStateChanged when the old token expires.
        }
      },
    ));
  }

  /// Camera + microphone are only needed to broadcast, not to watch.
  Future<bool> requestBroadcastPermissions() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// Mints a short-lived token via the `agora-token` Edge Function. Throws
  /// if the caller isn't signed in or the function rejects the request.
  Future<AgoraToken> fetchToken({required String channelName, required bool asBroadcaster}) async {
    final res = await supabase.functions.invoke('agora-token', body: {
      'channelName': channelName,
      'role': asBroadcaster ? 'publisher' : 'subscriber',
    });
    final data = res.data as Map<String, dynamic>;
    return AgoraToken(
      token: data['token'] as String,
      appId: data['appId'] as String,
      channelName: data['channelName'] as String,
      uid: data['uid'] as int,
    );
  }

  Future<void> release() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      await engine.leaveChannel();
      await engine.release();
    }
  }
}
