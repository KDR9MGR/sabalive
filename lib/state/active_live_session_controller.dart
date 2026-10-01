import 'package:flutter/material.dart';

/// The single global slot for "a live session the user can minimize and
/// keep active while using the rest of the app." Only video/audio
/// broadcast/watch screens use this — PK has no minimize and stays a
/// normal pushed route, so it never touches this controller at all (it's
/// naturally self-blocking: you can't reach another live from inside it
/// without first ending it, since it has no way to background itself).
///
/// The screen widget itself (LiveBroadcastScreen, WatchLiveScreen,
/// WatchAudioRoomScreen) is unchanged internally — this only changes WHERE
/// it's mounted (a root-level overlay via MaterialApp.builder, see
/// app.dart, instead of a pushed Navigator route) and who owns the
/// minimized/full-screen flag.
class ActiveLiveSessionController extends ChangeNotifier {
  String? _roomId;
  bool _minimized = false;
  WidgetBuilder? _builder;
  String _hostName = '';
  String? _hostAvatarUrl;

  bool get isActive => _roomId != null;
  bool get isMinimized => _minimized;
  String? get roomId => _roomId;
  String get hostName => _hostName;
  String? get hostAvatarUrl => _hostAvatarUrl;

  /// False when a DIFFERENT room is already active — callers should show
  /// the "already watching a live" dialog instead of proceeding. True when
  /// no session is active, or the requested room IS the active one
  /// (callers should [restore] in that case rather than starting fresh).
  bool canStart(String requestedRoomId) =>
      !isActive || _roomId == requestedRoomId;

  void start({
    required String roomId,
    required WidgetBuilder builder,
    required String hostName,
    String? hostAvatarUrl,
  }) {
    _roomId = roomId;
    _builder = builder;
    _minimized = false;
    _hostName = hostName;
    _hostAvatarUrl = hostAvatarUrl;
    notifyListeners();
  }

  void minimize() {
    if (!isActive || _minimized) return;
    _minimized = true;
    notifyListeners();
  }

  void restore() {
    if (!isActive || !_minimized) return;
    _minimized = false;
    notifyListeners();
  }

  /// Called once the screen itself has fully torn down (its own dispose()
  /// already ran the real cleanup — Agora release, unsubscribes,
  /// leave_live_stream). This just clears the slot so a new session can
  /// start and the root overlay stops building this widget.
  void end() {
    if (!isActive) return;
    _roomId = null;
    _builder = null;
    _minimized = false;
    notifyListeners();
  }

  Widget buildActive(BuildContext context) => _builder!(context);
}
