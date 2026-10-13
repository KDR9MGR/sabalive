import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/errors.dart';
import '../../../core/utils/viewer_picker_sheet.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../data/profile_cache.dart';
import '../../../state/room_moderation.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The most room admins a host can have.
const int kMaxRoomAdmins = 5;

/// The host's "Room admins" setting for an audio or video live: who the admins are, add one from the people in the room, or
/// take one off. Admins can kick, ban, ban text, and manage seats in every live this host runs.
Future<void> showRoomAdminsSheet(
  BuildContext context, {
  required RoomModeration moderation,
  required String streamId,
  ProfileCache? profiles,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => RoomAdminsSheet(moderation: moderation, streamId: streamId, profiles: profiles),
  );
}

class RoomAdminsSheet extends StatefulWidget {
  const RoomAdminsSheet({super.key, required this.moderation, required this.streamId, this.profiles});

  final RoomModeration moderation;
  final String streamId;
  final ProfileCache? profiles;

  @override
  State<RoomAdminsSheet> createState() => _RoomAdminsSheetState();
}

class _RoomAdminsSheetState extends State<RoomAdminsSheet> {
  final Map<String, AppUser> _people = {};
  String? _error;
  bool _busy = false;

  ProfileCache get _cache => widget.profiles ?? ProfileCache.instance;

  @override
  void initState() {
    super.initState();
    widget.moderation.addListener(_onChange);
    _fetchMissing();
  }

  @override
  void dispose() {
    widget.moderation.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _fetchMissing();
  }

  Future<void> _fetchMissing() async {
    for (final id in widget.moderation.admins) {
      if (_people.containsKey(id)) continue;
      final row = await _cache.get(id);
      if (row != null && mounted) setState(() => _people[id] = AppUser.fromRow(row));
    }
  }

  Future<void> _add() async {
    final picked = await pickViewer(
      context,
      streamId: widget.streamId,
      hostId: widget.moderation.hostId,
      title: 'Add a room admin',
      subtitle: 'Admins can kick, ban, ban text and manage seats in all your lives.',
      actionIcon: Icons.shield_rounded,
      actionColor: AppColors.gold,
    );
    if (picked == null || !mounted) return;
    await _run(() => widget.moderation.setAdmin(picked.id, true), seed: picked);
  }

  Future<void> _run(Future<void> Function() action, {AppUser? seed}) async {
    setState(() {
      _busy = true;
      _error = null;
      if (seed != null) _people[seed.id] = seed;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.moderation.admins.toList();
    final full = ids.length >= kMaxRoomAdmins;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Room admins', style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            const Text(
              'Admins can kick, ban, ban text and manage seats in all your lives. They cannot end your live or add admins.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            if (ids.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Text('No room admins yet.', style: TextStyle(color: AppColors.textMuted)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in ids)
                      ListTile(
                        key: ValueKey('admin-$id'),
                        leading: AppAvatar(
                          name: _people[id]?.name ?? '?',
                          imageUrl: _people[id]?.avatarUrl,
                          frameUrl: _people[id]?.frameUrl,
                          size: 40,
                        ),
                        title: Text(
                          _people[id]?.name ?? '…',
                          style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        trailing: TextButton(
                          onPressed: _busy ? null : () => _run(() => widget.moderation.setAdmin(id, false)),
                          child: const Text('Remove'),
                        ),
                      ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger, fontSize: 12.5)),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_busy || full) ? null : _add,
                icon: const Icon(Icons.shield_rounded, size: 18),
                label: Text(full ? 'You have 5 admins' : 'Add an admin'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
