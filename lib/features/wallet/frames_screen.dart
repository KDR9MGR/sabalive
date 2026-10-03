import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/remote_media.dart';
import '../../data/frames_repository.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

/// Profile frames: the animated ring around your picture that shows on your
/// profile and in every live. Pick one you own, claim a free or level-unlocked
/// one, or buy one with coins. The catalog is managed from the admin panel.
class FramesScreen extends StatefulWidget {
  const FramesScreen({super.key, this.repo});
  final FramesRepository? repo;

  @override
  State<FramesScreen> createState() => _FramesScreenState();
}

class _FramesScreenState extends State<FramesScreen> {
  late final FramesRepository _repo = widget.repo ?? FramesRepository();
  List<ProfileFrame>? _frames;
  String? _error;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final frames = await _repo.load();
      if (mounted) {
        setState(() {
          _frames = frames;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _frames == null) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _act(ProfileFrame f, FrameAction action) async {
    if (_busy.contains(f.id)) return;
    setState(() => _busy.add(f.id));
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthController>();
    try {
      switch (action.kind) {
        case FrameActionKind.remove:
          await _repo.setEquipped(f.id, false);
        case FrameActionKind.equip:
          await _repo.setEquipped(f.id, true);
        case FrameActionKind.claim || FrameActionKind.buy:
          await _repo.claim(f.id);
          // having just got it, wear it
          await _repo.setEquipped(f.id, true);
          messenger.showSnackBar(SnackBar(content: Text('${f.name} is yours')));
        case FrameActionKind.locked:
          break;
      }
      await _load();
      await auth.reloadProfile();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy.remove(f.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final frames = _frames;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile Frames')),
      body: _error != null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: AppColors.textMuted)),
            )
          : frames == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                if (user != null) _preview(user.name, user.avatarUrl, user.frameUrl),
                const SizedBox(height: 18),
                if (frames.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(
                      child: Text(
                        'No frames yet',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: frames.length,
                    itemBuilder: (_, i) => _card(frames[i], user?.level ?? 1),
                  ),
              ],
            ),
    );
  }

  Widget _preview(String name, String? avatar, String? frame) {
    return Column(
      children: [
        const SizedBox(height: 20),
        SizedBox(
          height: 140,
          child: Center(
            child: AppAvatar(name: name, imageUrl: avatar, frameUrl: frame, size: 96),
          ),
        ),
        Text(
          frame == null ? 'No frame on' : 'Your frame',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ],
    );
  }

  Widget _card(ProfileFrame f, int level) {
    final action = frameActionFor(f, level: level);
    final busy = _busy.contains(f.id);
    return Container(
      key: ValueKey('frame-${f.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: f.equipped ? AppColors.primaryBright : AppColors.stroke,
          width: f.equipped ? 1.6 : 1,
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SizedBox.square(
                dimension: 84,
                child: f.iconUrl == null
                    ? Center(child: Text(f.emoji, style: const TextStyle(fontSize: 44)))
                    : RemoteMedia(
                        f.iconUrl!,
                        fit: BoxFit.contain,
                        fallback: Center(
                          child: Text(f.emoji, style: const TextStyle(fontSize: 44)),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          action.enabled
              ? (action.kind == FrameActionKind.remove
                    ? OutlinedButton(
                        onPressed: busy ? null : () => _act(f, action),
                        child: Text(busy ? '…' : action.label),
                      )
                    : GradientButton(
                        label: action.label,
                        height: 34,
                        loading: busy,
                        onPressed: () => _act(f, action),
                      ))
              : Container(
                  height: 34,
                  alignment: Alignment.center,
                  child: Text(
                    action.label,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
        ],
      ),
    );
  }
}
