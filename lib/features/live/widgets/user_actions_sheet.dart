import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/errors.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../data/social_repository.dart';
import '../../../router/app_nav.dart';
import '../../../state/room_moderation.dart';
import '../../../theme/app_colors.dart';
import '../../profile/user_safety_menu.dart';
import '../../../core/i18n/text.dart';

/// What can be done to one person in a live room, from a tap on their chat line, their name in the viewer list or
/// their seat: look at their profile and report them (anyone), and, for the host and the host's room admins, kick,
/// ban from this live, turn their chat off, and (host only, audio and video lives) make them a room admin.
///
///  - Kick: out of the room now; they can come back in.
///  - Ban: out of the room now, and not back in for the rest of this live.
///  - Ban text: they stay and listen, but cannot chat until the live ends or it is lifted.
///
/// [seat] is set when the person is on a seat: a moderator can then also mute their microphone or take them off the
/// seat. [allowAdmins] is true on the host's own screens (audio and video), where the host picks room admins.
Future<void> showUserActionsSheet(
  BuildContext context, {
  required AppUser user,
  required String streamId,
  required RoomModeration moderation,
  int? seat,
  bool seatMuted = false,
  bool allowAdmins = false,
  SocialRepository? social,
}) async {
  final isMe = user.id == moderation.myId;
  final canModerate = moderation.canModerate(user.id);
  // an older server has no kick / text ban / room admins yet: leave those out rather than fail on every tap
  final serverOk = moderation.serverHasModeration;
  final canAdmin = serverOk && allowAdmins && moderation.iAmHost && !isMe && user.id != moderation.hostId;

  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            // bigger when there is a frame, so the picture stays near 41 (a frame needs a box of at least kFrameMinSize)
            AppAvatar(
              name: user.name,
              imageUrl: user.avatarUrl,
              frameUrl: user.frameUrl,
              size: AppAvatar.showsFrame(72, user.frameUrl) ? 72 : 54,
            ),
            const SizedBox(height: 8),
            Text(user.name, style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 15)),
            if (moderation.isAdmin(user.id))
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('Room admin', style: TextStyle(fontSize: 11.5, color: AppColors.gold)),
              ),
            const SizedBox(height: 6),
            _tile(sheet, 'profile', Icons.person_outline_rounded, 'View profile'),
            if (!isMe) _tile(sheet, 'report', Icons.flag_outlined, 'Report'),
            if (canModerate) ...[
              const Divider(height: 14),
              if (seat != null) ...[
                _tile(sheet, 'seat-mute', seatMuted ? Icons.mic_rounded : Icons.mic_off_rounded,
                    seatMuted ? 'Unmute microphone' : 'Mute microphone'),
                _tile(sheet, 'seat-remove', Icons.event_seat_outlined, 'Remove from seat'),
              ],
              if (serverOk) _tile(sheet, 'kick', Icons.logout_rounded, 'Kick from live', color: AppColors.danger),
              _tile(sheet, 'ban', Icons.block_rounded, 'Ban from this live', color: AppColors.danger),
              if (serverOk)
                moderation.isChatOff(user.id)
                    ? _tile(sheet, 'text-on', Icons.chat_bubble_outline_rounded, 'Allow text')
                    : _tile(sheet, 'text-off', Icons.comments_disabled_outlined, 'Ban text'),
            ],
            if (canAdmin) ...[
              const Divider(height: 14),
              moderation.isAdmin(user.id)
                  ? _tile(sheet, 'admin-off', Icons.shield_outlined, 'Remove room admin')
                  : _tile(sheet, 'admin-on', Icons.shield_rounded, 'Make room admin', color: AppColors.gold),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  Future<void> run(Future<void> Function() action, String done) async {
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  switch (choice) {
    case 'profile':
      AppNav.userProfile(context, user);
    case 'report':
      await reportUser(context, user, social ?? SocialRepository(), note: 'Reported from a live: $streamId');
    case 'kick':
      if (await _confirm(context, 'Kick ${user.name}?', 'They leave the live now, and can come back in.', 'Kick')) {
        await run(() => moderation.kick(user.id), '${user.name} was kicked');
      }
    case 'ban':
      if (await _confirm(context, 'Ban ${user.name}?', "They leave the live now and can't come back to it.", 'Ban')) {
        await run(() => moderation.ban(user.id), '${user.name} was banned from this live');
      }
    case 'text-off':
      await run(() => moderation.setChatOff(user.id, true), "${user.name}'s chat is off");
    case 'text-on':
      await run(() => moderation.setChatOff(user.id, false), "${user.name} can chat again");
    case 'seat-mute':
      await run(() => moderation.repo.muteSeat(streamId, seat!, !seatMuted), seatMuted ? 'Microphone on' : 'Microphone muted');
    case 'seat-remove':
      await run(() => moderation.repo.removeFromSeat(streamId, seat!), '${user.name} was taken off the seat');
    case 'admin-on':
      await run(() => moderation.setAdmin(user.id, true), '${user.name} is now a room admin');
    case 'admin-off':
      await run(() => moderation.setAdmin(user.id, false), '${user.name} is no longer a room admin');
  }
}

Widget _tile(BuildContext sheet, String value, IconData icon, String label, {Color? color}) {
  return ListTile(
    dense: true,
    leading: Icon(icon, color: color),
    title: Text(label, style: TextStyle(color: color)),
    onTap: () => Navigator.pop(sheet, value),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: Text(action, style: const TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  return ok ?? false;
}
