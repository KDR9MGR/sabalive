import 'dart:async';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart';

import 'agora_service.dart';

typedef AgoraChannelSwitch =
    Future<void> Function(RtcEngine engine, {required String newChannelName, required bool asBroadcaster, required bool publishCamera});

/// Moves a live's audio to a PK battle's shared Agora channel while the battle runs, and back to the live's own channel when it ends.
///
/// Agora has no lighter way to change channel than leave + rejoin, and everybody in both rooms does it (the hosts, the seat guests, the
/// audience), so the screens call [sync] with what the [PkBattleController] says and this class makes sure each phone ends up in the
/// right channel exactly once, even if the answers arrive quickly one after another.
class PkChannelSwitcher {
  PkChannelSwitcher({
    required this.engine,
    required this.ownChannel,
    required this.broadcaster,
    this.publishCamera,
    this.stagger = false,
    this.onError,
    AgoraChannelSwitch? switcher,
  }) : _switch = switcher ?? _viaAgoraService;

  /// The engine of this screen (null until it has joined).
  final RtcEngine? Function() engine;

  /// The live's own channel (the stream id).
  final String ownChannel;

  /// Does this phone publish audio? The host and (in an audio live) a guest on a seat do; a plain listener does not. The argument is
  /// true for the battle's channel, false for the live's own: in a VIDEO battle the guests only listen.
  final bool Function(bool inBattle) broadcaster;

  /// Does this phone publish its camera? Only a video live's host (in both channels). Null = never.
  final bool Function(bool inBattle)? publishCamera;

  /// Listeners spread their switch over about 1.5 s, so a room of hundreds does not ask for a token in the same second.
  final bool stagger;
  final void Function(Object error)? onError;
  final AgoraChannelSwitch _switch;
  final math.Random _random = math.Random();

  late String _target = ownChannel;
  Future<void> _last = Future<void>.value();

  /// The channel this phone is in, null until its first join has succeeded. A switch is never started before that: the first join
  /// is still on its way and would land in the old channel after it (a viewer who opens a room in the middle of a battle).
  String? _at;

  /// Is this phone in a battle's shared channel right now (not the live's own)?
  bool get inSharedChannel => _at != null && _at != ownChannel;

  /// The phone is in the right channel but its role changed (a viewer was just seated, or left a seat, during a battle): join the same
  /// channel again with the role [broadcaster] says now. Outside a battle there is nothing to do: the screen changes the role itself.
  Future<void> reapply() {
    _last = _last.then((_) async {
      final e = engine();
      final at = _at;
      if (e == null || at == null || at == ownChannel) return;
      try {
        await _switch(e, newChannelName: at, asBroadcaster: broadcaster(true), publishCamera: publishCamera?.call(true) ?? false);
      } catch (error) {
        onError?.call(error);
      }
    });
    return _last;
  }

  /// Call from the screen's `onJoinChannelSuccess` with the channel that was joined (the first join, and every later one).
  void markJoined(String channel) {
    _at = channel;
    if (_target != channel) _last = _last.then((_) => _go(_target)); // the battle was already on when we got in
  }

  static Future<void> _viaAgoraService(RtcEngine engine,
          {required String newChannelName, required bool asBroadcaster, required bool publishCamera}) =>
      AgoraService.instance.switchChannel(engine, newChannelName: newChannelName, asBroadcaster: asBroadcaster, publishCamera: publishCamera);

  /// [sharedChannel] = the battle's channel while it is live, null otherwise (back to the live's own channel).
  Future<void> sync(String? sharedChannel) {
    final target = sharedChannel ?? ownChannel;
    if (_target == target) return _last;
    _target = target;
    // one switch after the other: a quick "joined, then over" must not run two leave + rejoin at once
    _last = _last.then((_) => _go(target));
    return _last;
  }

  Future<void> _go(String target) async {
    final e = engine();
    // not joined yet (markJoined will come back), already there, or a newer answer already replaced this one
    if (e == null || _at == null || _at == target || _target != target) return;
    if (stagger) {
      await Future<void>.delayed(Duration(milliseconds: _random.nextInt(1500)));
      if (_target != target) return;
    }
    try {
      final inBattle = target != ownChannel;
      await _switch(
        e,
        newChannelName: target,
        asBroadcaster: broadcaster(inBattle),
        publishCamera: publishCamera?.call(inBattle) ?? false,
      );
      _at = target;
    } catch (error) {
      onError?.call(error);
    }
  }
}
