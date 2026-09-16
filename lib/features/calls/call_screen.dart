import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/app_avatar.dart';
import '../../data/calls_repository.dart';
import '../../services/agora_service.dart';
import '../../theme/app_colors.dart';

/// A 1:1 audio/video call. [outgoing] callers wait on the "ringing" state
/// until the callee's row flips to "accepted"; then both sides join the Agora
/// channel. Any terminal status (declined/ended/cancelled) closes the screen.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.call, required this.outgoing});
  final CallInfo call;
  final bool outgoing;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _repo = CallsRepository();
  final _agora = AgoraService.instance;

  RtcEngine? _engine;
  int? _remoteUid;
  bool _joined = false;
  bool _muted = false;
  bool _videoOn = true;
  bool _speaker = true;
  String _state = 'connecting';

  bool get _isVideo => widget.call.kind == CallKind.video;

  @override
  void initState() {
    super.initState();
    _videoOn = _isVideo;
    _repo.subscribeCall(widget.call.id, _onStatus);
    if (widget.outgoing) {
      setState(() => _state = 'Ringing…');
    } else {
      // incoming call was already accepted by the overlay
      _connect();
    }
  }

  void _onStatus(String status) {
    if (!mounted) return;
    switch (status) {
      case 'accepted':
        if (!_joined) _connect();
        break;
      case 'declined':
        _finish(message: 'Call declined');
        break;
      case 'ended':
      case 'cancelled':
      case 'missed':
        _finish();
        break;
    }
  }

  Future<void> _connect() async {
    setState(() => _state = 'Connecting…');
    try {
      final granted = await _agora.requestBroadcastPermissions();
      if (!granted) {
        _finish(message: 'Microphone/camera permission needed');
        return;
      }
      final engine = await _agora.ensureEngine();
      _engine = engine;
      engine.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (conn, elapsed) {
          if (mounted) setState(() => _joined = true);
        },
        onUserJoined: (conn, uid, elapsed) {
          if (mounted) setState(() => _remoteUid = uid);
        },
        onUserOffline: (conn, uid, reason) {
          _finish();
        },
        onConnectionStateChanged: (conn, state, reason) {
          if (!mounted || !_joined) return;
          setState(() => _state =
              state == ConnectionStateType.connectionStateReconnecting
                  ? 'Reconnecting…'
                  : 'In call');
        },
      ));
      _agora.registerAutoTokenRenewal(engine,
          channelName: widget.call.channel, asBroadcaster: true);

      await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
      if (_isVideo) {
        await engine.enableVideo();
        await engine.startPreview();
      } else {
        await engine.disableVideo();
      }
      await engine.setEnableSpeakerphone(_speaker);

      final token = await _agora.fetchToken(
        channelName: widget.call.channel,
        asBroadcaster: true,
      );
      await engine.joinChannel(
        token: token.token,
        channelId: token.channelName,
        uid: token.uid,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );
      if (mounted) setState(() => _state = 'In call');
    } catch (e) {
      _finish(message: 'Call failed to connect');
    }
  }

  Future<void> _hangUp() async {
    final terminal = widget.outgoing && !_joined ? 'cancelled' : 'ended';
    try {
      await _repo.setStatus(widget.call.id, terminal);
    } catch (_) {}
    _finish();
  }

  bool _finishing = false;
  Future<void> _finish({String? message}) async {
    if (_finishing) return;
    _finishing = true;
    try {
      await _agora.release();
    } catch (_) {}
    if (!mounted) return;
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    if (!_finishing) _agora.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isVideo && _remoteUid != null && _engine != null)
            AgoraVideoView(
              controller: VideoViewController.remote(
                rtcEngine: _engine!,
                canvas: VideoCanvas(uid: _remoteUid),
                connection: RtcConnection(channelId: widget.call.channel),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppAvatar(name: widget.call.otherName, size: 120, ring: true),
                  const SizedBox(height: 18),
                  Text(widget.call.otherName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(_joined ? _state : _state,
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
          if (_isVideo && _engine != null && _videoOn)
            Positioned(
              right: 16,
              top: MediaQuery.of(context).padding.top + 16,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AgoraVideoView(
                  controller: VideoViewController(
                    rtcEngine: _engine!,
                    canvas: const VideoCanvas(uid: 0),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _btn(
                  _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  () async {
                    setState(() => _muted = !_muted);
                    await _engine?.muteLocalAudioStream(_muted);
                  },
                  active: !_muted,
                ),
                if (_isVideo)
                  _btn(
                    _videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                    () async {
                      setState(() => _videoOn = !_videoOn);
                      await _engine?.muteLocalVideoStream(!_videoOn);
                    },
                    active: _videoOn,
                  ),
                if (_isVideo)
                  _btn(Icons.cameraswitch_rounded,
                      () async => _engine?.switchCamera()),
                _btn(
                  _speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                  () async {
                    setState(() => _speaker = !_speaker);
                    await _engine?.setEnableSpeakerphone(_speaker);
                  },
                  active: _speaker,
                ),
                _btn(Icons.call_end_rounded, _hangUp,
                    bg: AppColors.danger, big: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap,
      {bool active = true, Color? bg, bool big = false}) {
    final size = big ? 64.0 : 52.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg ??
                (active
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.08)),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: big ? 28 : 22),
        ),
      ),
    );
  }
}
