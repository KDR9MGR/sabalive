import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../config/feature_flags.dart';
import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../services/agora_service.dart';
import '../../state/active_live_session_controller.dart';
import '../../state/auth_controller.dart';
import '../../state/live_streams_controller.dart';
import '../../theme/app_colors.dart';
import 'live_broadcast_screen.dart';
import 'pk_battle_screen.dart';
import '../../core/i18n/text.dart';

class GoLiveSetupScreen extends StatefulWidget {
  const GoLiveSetupScreen({super.key});

  @override
  State<GoLiveSetupScreen> createState() => _GoLiveSetupScreenState();
}

class _GoLiveSetupScreenState extends State<GoLiveSetupScreen> {
  final _title = TextEditingController(text: 'Chill Sunday Vibes');
  static const _category = 'Chatting';
  bool _starting = false;
  LiveMode _mode = LiveMode.video;

  /// The PK tab with the battle layer: an ordinary AUDIO live that opens the PK invite (the old standalone PK screen is the fallback
  /// while `pk_layer` is off).
  bool _pkLayer = false;

  /// Within the PK tab: a VIDEO PK (a video live that opens the invite) instead of an audio one. Only while `pk_video` is on.
  bool _pkVideo = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_mode == LiveMode.pk && !FeatureFlags.pkBattleEnabled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('PK Battles are coming soon')),
      );
      return;
    }
    final navigator = Navigator.of(context);
    final liveStreams = context.read<LiveStreamsController>();
    final session = context.read<ActiveLiveSessionController>();
    setState(() => _starting = true);
    try {
      final granted = await AgoraService.instance.requestBroadcastPermissions();
      if (!granted) {
        throw Exception('Camera and microphone access are required to go live');
      }

      final title = _title.text.trim().isEmpty
          ? 'Live now'
          : _title.text.trim();
      final stream = await liveStreams.createStream(
        title: title,
        category: _category,
        mode: _pkLayer ? (_pkVideo ? LiveMode.video : LiveMode.audio) : _mode,
      );
      final token = await AgoraService.instance.fetchToken(
        channelName: stream.id,
        asBroadcaster: true,
      );

      if (!mounted) return;
      if (_mode == LiveMode.pk && !_pkLayer) {
        // PK has no minimize (it's naturally self-blocking — there's no
        // way to background it and reach another live without ending it
        // first), so it stays a normal pushed route.
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => PkBattleScreen(stream: stream, token: token),
          ),
        );
        return;
      }
      // Video/audio broadcasts register with the global session instead of
      // being pushed — the root overlay in app.dart mounts them above
      // EVERY route, not just whatever's on top of this Navigator right
      // now, which is what lets minimizing keep the whole app (not just
      // MainShell's own tabs) genuinely interactive underneath. Unwind
      // back through this screen and the host-code gate screen beneath it
      // so the user lands on MainShell, with the live view now rendered
      // full-screen on top by that overlay.
      session.start(
        roomId: stream.id,
        hostName: stream.host.name,
        hostAvatarUrl: stream.host.avatarUrl,
        builder: (_) => LiveBroadcastScreen(
          stream: stream,
          token: token,
          audioOnly: _pkLayer ? !_pkVideo : _mode == LiveMode.audio,
          openPk: _pkLayer,
        ),
      );
      navigator.popUntil((route) => route.isFirst);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().user ?? Mock.me;
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      'Go Live',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    AppAvatar(
                      name: me.name,
                      imageUrl: me.avatarUrl,
                      size: 104,
                      ring: true,
                    ),
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.photo_camera_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SegmentedTabs(
                  tabs: const ['Video', 'Audio', 'PK'],
                  index: _mode.index,
                  onChanged: (i) {
                    final mode = LiveMode.values[i];
                    if (mode == LiveMode.pk && !FeatureFlags.pkBattleEnabled) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('PK Battles are coming soon'),
                        ),
                      );
                      return;
                    }
                    setState(() {
                      _mode = mode;
                      _pkLayer = mode == LiveMode.pk && FeatureFlags.pkLayerEnabled;
                      _pkVideo = false;
                    });
                  },
                ),
                if (_pkLayer) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ChoiceChip(
                        key: const ValueKey('go-live-pk-audio'),
                        label: const Text('Audio PK'),
                        selected: !_pkVideo,
                        onSelected: (_) => setState(() => _pkVideo = false),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        key: const ValueKey('go-live-pk-video'),
                        label: Text(FeatureFlags.pkVideoEnabled ? 'Video PK' : 'Video PK (soon)'),
                        selected: _pkVideo,
                        onSelected: FeatureFlags.pkVideoEnabled ? (_) => setState(() => _pkVideo = true) : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _pkVideo
                        ? 'Video PK: you go live on camera, then invite a host you follow or find a random opponent. Both cameras show side by side.'
                        : 'Audio PK: you go live in a voice room, then invite a host you follow or find a random opponent.',
                    key: const ValueKey('go-live-pk-note'),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 20),
                _label('Stream Title'),
                TextField(
                  controller: _title,
                  maxLength: 100,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('What\'s your stream about?'),
                  ),
                ),
                const Spacer(),
                GradientButton(
                  label: switch (_mode) {
                    LiveMode.pk => _pkLayer ? (_pkVideo ? 'Start Video PK' : 'Start Audio PK') : 'Start PK Battle',
                    LiveMode.audio => 'Start Audio Room',
                    LiveMode.video => 'Start Live',
                  },
                  icon: switch (_mode) {
                    LiveMode.pk => Icons.bolt_rounded,
                    LiveMode.audio => Icons.mic_rounded,
                    LiveMode.video => Icons.podcasts_rounded,
                  },
                  loading: _starting,
                  onPressed: _start,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        t,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
      ),
    ),
  );
}
