import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../services/agora_service.dart';
import '../../state/auth_controller.dart';
import '../../state/live_streams_controller.dart';
import '../../theme/app_colors.dart';
import 'live_broadcast_screen.dart';
import 'pk_battle_screen.dart';

class GoLiveSetupScreen extends StatefulWidget {
  const GoLiveSetupScreen({super.key});

  @override
  State<GoLiveSetupScreen> createState() => _GoLiveSetupScreenState();
}

class _GoLiveSetupScreenState extends State<GoLiveSetupScreen> {
  final _title = TextEditingController(text: 'Chill Sunday Vibes');
  String _category = 'Chatting';
  String _audience = 'Everyone';
  bool _starting = false;
  LiveMode _mode = LiveMode.video;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickCategory() async {
    final choice = await _sheet('Category', Mock.categories.map((c) => c.label).toList());
    if (choice != null) setState(() => _category = choice);
  }

  Future<void> _pickAudience() async {
    final choice = await _sheet('Audience', ['Everyone', 'Followers only', 'Private (invite)']);
    if (choice != null) setState(() => _audience = choice);
  }

  Future<String?> _sheet(String title, List<String> options) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
            const SizedBox(height: 8),
            ...options.map((o) => ListTile(
                  title: Text(o),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, o),
                )),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final liveStreams = context.read<LiveStreamsController>();
    setState(() => _starting = true);
    try {
      final granted = await AgoraService.instance.requestBroadcastPermissions();
      if (!granted) {
        throw Exception('Camera and microphone access are required to go live');
      }

      final title = _title.text.trim().isEmpty ? 'Live now' : _title.text.trim();
      final stream = await liveStreams.createStream(
        title: title,
        category: _category,
        mode: _mode,
      );
      final token = await AgoraService.instance.fetchToken(
        channelName: stream.id,
        asBroadcaster: true,
      );

      if (!mounted) return;
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => switch (_mode) {
            LiveMode.pk => PkBattleScreen(stream: stream, token: token),
            LiveMode.audio =>
              LiveBroadcastScreen(stream: stream, token: token, audioOnly: true),
            LiveMode.video =>
              LiveBroadcastScreen(stream: stream, token: token),
          },
        ),
      );
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
                    Text('Go Live',
                        style: Theme.of(context).textTheme.headlineSmall),
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
                    AppAvatar(name: me.name, size: 104, ring: true),
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: const BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.photo_camera_rounded,
                          size: 16, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SegmentedTabs(
                  tabs: const ['Video', 'Audio', 'PK'],
                  index: _mode.index,
                  onChanged: (i) =>
                      setState(() => _mode = LiveMode.values[i]),
                ),
                const SizedBox(height: 20),
                _label('Stream Title'),
                TextField(
                  controller: _title,
                  maxLength: 100,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'What\'s your stream about?',
                  ),
                ),
                const SizedBox(height: 8),
                _row(Icons.grid_view_rounded, 'Category', _category,
                    _pickCategory),
                _row(Icons.groups_rounded, 'Audience', _audience, _pickAudience),
                _row(Icons.tune_rounded, 'More Settings', 'Beauty, mic, guests',
                    () {}),
                const Spacer(),
                GradientButton(
                  label: switch (_mode) {
                    LiveMode.pk => 'Start PK Battle',
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
                const SizedBox(height: 12),
                OutlinePillButton(
                  label: 'Schedule for later',
                  icon: Icons.schedule_rounded,
                  onPressed: () => Navigator.pop(context),
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
          child: Text(t,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12.5)),
        ),
      );

  Widget _row(IconData icon, String title, String value, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 20, color: AppColors.primaryBright),
                const SizedBox(width: 12),
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13.5)),
                const Spacer(),
                Flexible(
                  child: Text(value,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12.5)),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
