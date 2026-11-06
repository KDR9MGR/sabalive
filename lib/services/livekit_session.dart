import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart' show AudioVolumeInfo;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../config/supabase_client.dart';

/// A live room on the hosted LiveKit server ("MS cloud" / LiveCore), owner 2026-11-06. One [LiveKitSession] is one phone's connection to one room, from joining until [release].
///
/// WHY IT SPEAKS "AGORA": the three live screens decide who is talking, which seat a voice belongs to and who left by an Agora-style uid (`live_stream_seats.agora_uid`,
/// `live_streams.host_agora_uid`, `SeatSpeaking`). So that this server can sit next to Agora without rewriting any of that, every person on MS cloud gets a stable 32-bit number
/// worked out from their account id ([liveKitUidOf]); every phone works out the same number for the same person, the screens store and read it exactly like an Agora uid, and
/// this class reports volume, joins and leaves in Agora's shapes ([AudioVolumeInfo], uids), with this phone's own voice as uid 0 as Agora does.
///
/// WHAT IT DOES NOT DO (yet): PK battles (they move people between Agora channels), the local music mixer, the beauty filter and the funny voice: those stay Agora-only, and the
/// screens hide them in an MS cloud room. See docs/STREAMING_SERVER_SWAP.md.

/// A stable, non-zero 32-bit number for [identity] (a Supabase user id): FNV-1a over its UTF-8 bytes, lower-cased. Zero is kept free because the volume reports use 0 for "this phone".
int liveKitUidOf(String identity) {
  var hash = 0x811C9DC5;
  for (final b in utf8.encode(identity.trim().toLowerCase())) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash == 0 ? 1 : hash;
}

/// One person LiveKit says is talking: who, whether it is this phone, and how loud (0 to 1).
typedef LiveKitSpeaker = ({String identity, bool isLocal, double level});

/// LiveKit's "active speakers" -> Agora's volume report. LiveKit already decided these people are speaking, so each one is reported comfortably above the screens' thresholds
/// (10 for another person, 25 for this phone); a louder voice just reports higher. An empty list means nobody is talking.
List<AudioVolumeInfo> volumeInfosFor(Iterable<LiveKitSpeaker> speakers) => [
      for (final s in speakers)
        AudioVolumeInfo(
          uid: s.isLocal ? 0 : liveKitUidOf(s.identity),
          volume: math.max(120, (s.level.clamp(0.0, 1.0) * 255).round()),
          vad: 1,
        ),
    ];

/// What a person is told when the connection to an MS cloud room ends for [reason] (a `DisconnectReason` name). Never mentions the vendor.
String liveKitFailureMessage(String? reason) => switch (reason) {
      'duplicateIdentity' => 'You joined this live from another device.',
      'participantRemoved' => 'The host removed you from this live.',
      'roomDeleted' || 'roomClosed' => 'This live has ended.',
      'serverShutdown' || 'migration' => 'The live server is restarting. Please join again in a moment.',
      'joinFailure' || 'connectionTimeout' || 'signalClose' || 'disconnected' => 'Could not connect to the live. Check your internet and try again.',
      _ => 'The connection to the live was lost.',
    };

/// The answer of the `livekit-token` Edge Function.
@immutable
class LiveKitToken {
  const LiveKitToken({required this.token, required this.url, required this.identity});

  final String token;
  final String url;
  final String identity;

  /// Reads the function's JSON; a missing piece is an error, not a half token.
  factory LiveKitToken.fromJson(Object? json) {
    if (json is! Map) throw Exception('The live server gave no token');
    final token = json['token'];
    final url = json['url'];
    final identity = json['identity'];
    if (token is! String || token.isEmpty || url is! String || !url.startsWith('wss://') || identity is! String || identity.isEmpty) {
      throw Exception('The live server gave an unusable token');
    }
    return LiveKitToken(token: token, url: url, identity: identity);
  }
}

typedef LiveKitTokenFetcher = Future<LiveKitToken> Function({required String roomName, required bool publish});

/// Mints a token through the `livekit-token` function (staging: the same checks as `agora-token`: signed in, not banned, and only the host or a seat holder may publish).
Future<LiveKitToken> fetchLiveKitToken({required String roomName, required bool publish}) async {
  final res = await supabase.functions.invoke(
    'livekit-token',
    body: {'channelName': roomName, 'role': publish ? 'publisher' : 'subscriber'},
  );
  return LiveKitToken.fromJson(res.data);
}

/// What a screen wants to hear about, in Agora's terms.
class LiveKitEvents {
  const LiveKitEvents({
    this.onJoined,
    this.onUserJoined,
    this.onUserOffline,
    this.onVolume,
    this.onReconnecting,
    this.onFailed,
    this.onVideoChanged,
  });

  /// Connected; the argument is this phone's own uid.
  final void Function(int localUid)? onJoined;

  /// Somebody else is in the room (also called once for each person already there when this phone connects).
  final void Function(int uid)? onUserJoined;
  final void Function(int uid)? onUserOffline;

  /// Who is talking (an empty list: nobody).
  final void Function(List<AudioVolumeInfo> speakers)? onVolume;
  final void Function(bool reconnecting)? onReconnecting;

  /// The connection ended for good (not because this phone left): a sentence for the person.
  final void Function(String message)? onFailed;

  /// A video picture appeared, went away or changed: rebuild what draws it.
  final VoidCallback? onVideoChanged;
}

class LiveKitSession {
  LiveKitSession._({
    required this.roomName,
    required this.audioOnly,
    required this.events,
    required this.hostIdentity,
    required LiveKitTokenFetcher fetchToken,
  }) : _fetchToken = fetchToken;

  final String roomName;
  final bool audioOnly;
  final LiveKitEvents events;

  /// The room's host (their account id), so [hostVideo] picks the host's picture when several people publish.
  final String? hostIdentity;
  final LiveKitTokenFetcher _fetchToken;

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  bool _publisher = false;
  bool _closed = false;
  bool _frontCamera = true;
  String _identity = '';

  static bool _initialised = false;
  static Future<void>? _releasing;

  /// This phone's own uid (what its voice is called in the volume reports of OTHER phones).
  int get localUid => liveKitUidOf(_identity);
  bool get isPublisher => _publisher;
  bool get connected => _room?.connectionState == lk.ConnectionState.connected;

  /// Connects to [roomName]. A host or seat holder passes [asBroadcaster] (the function refuses anyone who may not publish: that error is thrown as it is).
  static Future<LiveKitSession> start({
    required String roomName,
    required bool asBroadcaster,
    required bool audioOnly,
    String? hostIdentity,
    bool micOn = true,
    bool cameraOn = true,
    LiveKitEvents events = const LiveKitEvents(),
    @visibleForTesting LiveKitTokenFetcher? tokenFetcher,
  }) async {
    final closing = _releasing;
    if (closing != null) await closing; // one connection at a time, like the Agora engine
    await _initialiseOnce();
    final session = LiveKitSession._(
      roomName: roomName,
      audioOnly: audioOnly,
      events: events,
      hostIdentity: hostIdentity?.toLowerCase(),
      fetchToken: tokenFetcher ?? fetchLiveKitToken,
    );
    final token = await session._fetchToken(roomName: roomName, publish: asBroadcaster);
    await session._connect(token, asBroadcaster: asBroadcaster, micOn: micOn, cameraOn: cameraOn);
    return session;
  }

  /// Media volume (not call volume), the same choice the Agora engine makes with its game-streaming scenario: a gift's own sound and music stay on the media slider.
  static Future<void> _initialiseOnce() async {
    if (_initialised) return;
    _initialised = true;
    try {
      // ignore: experimental_member_use
      await lk.LiveKitClient.initialize(initialAudioSessionOptions: const lk.AudioSessionOptions.mediaPlayback());
    } catch (e) {
      debugPrint('LiveKit initialise: $e'); // connecting still works with the defaults
    }
  }

  Future<void> _connect(LiveKitToken token, {required bool asBroadcaster, required bool micOn, required bool cameraOn}) async {
    _identity = token.identity;
    _publisher = asBroadcaster;
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        // 24 fps looks the same on a phone-sized live and keeps the host's phone cooler (the same choice the Agora path makes)
        defaultCameraCaptureOptions: lk.CameraCaptureOptions(maxFrameRate: 24),
      ),
    );
    final listener = room.createListener();
    listener
      ..on<lk.ActiveSpeakersChangedEvent>(_onSpeakers)
      ..on<lk.ParticipantConnectedEvent>((e) => events.onUserJoined?.call(liveKitUidOf(e.participant.identity)))
      ..on<lk.ParticipantDisconnectedEvent>((e) => events.onUserOffline?.call(liveKitUidOf(e.participant.identity)))
      ..on<lk.TrackSubscribedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.TrackUnsubscribedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.TrackMutedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.TrackUnmutedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.LocalTrackPublishedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.LocalTrackUnpublishedEvent>((_) => events.onVideoChanged?.call())
      ..on<lk.RoomReconnectingEvent>((_) => events.onReconnecting?.call(true))
      ..on<lk.RoomReconnectedEvent>((_) => events.onReconnecting?.call(false))
      ..on<lk.RoomDisconnectedEvent>(_onDisconnected);
    _room = room;
    _listener = listener;
    await room.connect(token.url, token.token, connectOptions: const lk.ConnectOptions(autoSubscribe: true));
    if (_closed) return;
    // somebody who was already here does not trigger a "connected" event: tell the screen about each of them now
    for (final p in room.remoteParticipants.values) {
      events.onUserJoined?.call(liveKitUidOf(p.identity));
    }
    events.onJoined?.call(localUid);
    if (asBroadcaster) {
      final me = room.localParticipant;
      if (micOn) await me?.setMicrophoneEnabled(true);
      if (cameraOn && !audioOnly) await me?.setCameraEnabled(true);
    }
    // people expect to hear a live out loud
    unawaited(setSpeaker(true));
    events.onVideoChanged?.call();
  }

  void _onSpeakers(lk.ActiveSpeakersChangedEvent e) {
    events.onVolume?.call(volumeInfosFor([
      for (final p in e.speakers) (identity: p.identity, isLocal: p is lk.LocalParticipant, level: p.audioLevel),
    ]));
  }

  void _onDisconnected(lk.RoomDisconnectedEvent e) {
    if (_closed || _switching) return; // this phone left (or is changing seat): not a failure
    events.onFailed?.call(liveKitFailureMessage(e.reason?.name));
  }

  bool _switching = false;

  /// Starts or stops publishing the microphone (a host's mic button; a seat holder who is muted). No-op for someone who may not publish.
  Future<void> setMicEnabled(bool on) async {
    if (!_publisher) return;
    await _room?.localParticipant?.setMicrophoneEnabled(on);
  }

  Future<void> setCameraEnabled(bool on) async {
    if (!_publisher || audioOnly) return;
    await _room?.localParticipant?.setCameraEnabled(on);
    events.onVideoChanged?.call();
  }

  /// Front <-> back camera of the host.
  Future<void> switchCamera() async {
    final track = _localVideoTrack;
    if (track == null) return;
    final next = !_frontCamera;
    try {
      await track.setCameraPosition(next ? lk.CameraPosition.front : lk.CameraPosition.back);
      _frontCamera = next;
    } catch (e) {
      debugPrint('switchCamera: $e');
    }
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
    } catch (e) {
      debugPrint('setSpeaker: $e');
    }
  }

  /// A viewer who takes a seat may publish; a seat holder who loses it may not. MS cloud decides this by the TOKEN, so the phone gets a new one and reconnects (a blink of a second
  /// or two; Agora has a lighter way, this server does not). Does nothing when the role is already the wanted one.
  Future<void> switchRole({required bool asBroadcaster}) async {
    if (_closed || _publisher == asBroadcaster) return;
    final token = await _fetchToken(roomName: roomName, publish: asBroadcaster);
    _switching = true;
    try {
      await _teardownRoom();
      await _connect(token, asBroadcaster: asBroadcaster, micOn: true, cameraOn: false);
    } finally {
      _switching = false;
    }
  }

  lk.LocalVideoTrack? get _localVideoTrack {
    for (final pub in _room?.localParticipant?.videoTrackPublications ?? const <lk.LocalTrackPublication<lk.LocalVideoTrack>>[]) {
      final t = pub.track;
      if (t != null) return t;
    }
    return null;
  }

  /// This phone's own camera picture (the host's preview), or null.
  lk.VideoTrack? get localVideo {
    for (final pub in _room?.localParticipant?.videoTrackPublications ?? const <lk.LocalTrackPublication<lk.LocalVideoTrack>>[]) {
      if (pub.track != null && !pub.muted) return pub.track;
    }
    return null;
  }

  /// The picture of the host (else of anybody who is publishing video), or null while there is none.
  lk.VideoTrack? get hostVideo {
    final room = _room;
    if (room == null) return null;
    lk.VideoTrack? any;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t == null || !pub.subscribed || pub.muted) continue;
        if (hostIdentity != null && p.identity.toLowerCase() == hostIdentity) return t;
        any ??= t;
      }
    }
    return any;
  }

  /// A draw-ready widget for [track] filling its box (cover), mirrored when it is this phone's front camera.
  Widget video(lk.VideoTrack track, {bool mirror = false}) => lk.VideoTrackRenderer(
        track,
        fit: lk.VideoViewFit.cover,
        mirrorMode: mirror ? lk.VideoViewMirrorMode.mirror : lk.VideoViewMirrorMode.off,
      );

  bool get frontCamera => _frontCamera;

  Future<void> _teardownRoom() async {
    final room = _room;
    final listener = _listener;
    _room = null;
    _listener = null;
    try {
      await listener?.dispose();
    } catch (_) {}
    try {
      await room?.disconnect();
    } catch (_) {}
    try {
      await room?.dispose();
    } catch (_) {}
  }

  /// Leaves the room and frees everything. Safe to call twice. A following [start] waits for this to finish.
  Future<void> release() {
    if (_closed) return _releasing ?? Future<void>.value();
    _closed = true;
    final done = _teardownRoom();
    final tracked = done.then<void>((_) {}, onError: (Object _) {});
    _releasing = tracked;
    tracked.whenComplete(() {
      if (identical(_releasing, tracked)) _releasing = null;
    });
    return done;
  }
}
