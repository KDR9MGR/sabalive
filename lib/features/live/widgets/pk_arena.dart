import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// Gift-total + status pill row shown above the arena. Shared by the host's
/// own screen and the viewer's, so both always read the identical status
/// label for a given `pk_battles` state.
class PkArenaHeader extends StatelessWidget {
  const PkArenaHeader({
    super.key,
    required this.giftTotal,
    required this.statusLabel,
  });
  final int giftTotal;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🎁', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Text(
                  '$giftTotal',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              statusLabel,
              style: const TextStyle(fontSize: 10, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// The split red/blue PK arena backdrop — each side shows a host's avatar,
/// name, and a row of seat icons. Shared by the host's own screen (seats
/// are editable via [onSeatTap]/[onAddSeat]) and the viewer's (omit both
/// for a read-only display — same nullable-callback pattern as `SeatRoom`).
class PkArena extends StatelessWidget {
  const PkArena({
    super.key,
    required this.hostA,
    this.hostB,
    this.waitingLabel = 'Waiting…',
    required this.seatsPerSide,
    this.lockedSeats = const {},
    this.onSeatTap,
    this.onAddSeat,
    this.bottomBar,
    this.occupantsA = const {},
    this.pendingRequestCountA = 0,
    this.onSeatTapA,
  });

  final AppUser hostA;
  final AppUser? hostB;
  final String waitingLabel;
  final int seatsPerSide;
  final Set<String> lockedSeats;
  final void Function(String key)? onSeatTap;
  final VoidCallback? onAddSeat;
  final Widget? bottomBar;

  /// Real occupants of hostA's own seats, keyed by seat number — the only
  /// side this screen can ever manage (approving/seating someone on the
  /// opponent's side is that host's own business, from their own screen).
  final Map<int, AppUser> occupantsA;

  /// Shown as a badge on hostA's empty seats so the host notices there's
  /// someone waiting on approval, even with a full arena of seats.
  final int pendingRequestCountA;

  /// Host: tapping an empty seat with pending requests opens the approval
  /// list; tapping an occupied seat opens kick/mute. Viewer: tapping an
  /// empty seat sends a request; tapping their own seat lets them leave.
  final void Function(int seat)? onSeatTapA;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Row(
          children: [
            Expanded(child: _corner(true)),
            Expanded(child: _corner(false)),
          ],
        ),
        if (bottomBar != null)
          Positioned(left: 12, right: 12, bottom: 8, child: bottomBar!),
      ],
    );
  }

  Widget _corner(bool left) {
    final AppUser? user = left ? hostA : hostB;
    final glow = left ? AppColors.live : AppColors.diamond;
    final wallpaper = user?.pkWallpaper;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: wallpaper != null
              ? AppColors.tints[wallpaper % AppColors.tints.length]
              : left
              ? [const Color(0xFFB1122B), const Color(0xFF3A0A16)]
              : [const Color(0xFF11489B), const Color(0xFF0A1B3A)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: glow, width: 3),
              boxShadow: [
                BoxShadow(color: glow.withValues(alpha: 0.6), blurRadius: 18),
              ],
            ),
            child: user != null
                ? AppAvatar(name: user.name, imageUrl: user.avatarUrl, size: 72)
                : Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    child: const Icon(
                      Icons.person_outline_rounded,
                      color: Colors.white38,
                      size: 32,
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            user?.name ?? (left ? '' : waitingLabel),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 1; i <= seatsPerSide; i++)
                left ? _seatA(i, 'No. $i') : _seat('R$i', 'No. $i'),
              if (onAddSeat != null && seatsPerSide < 4)
                GestureDetector(
                  onTap: onAddSeat,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seatA(int seat, String label) {
    final occupant = occupantsA[seat];
    final showBadge = occupant == null && pendingRequestCountA > 0;
    return GestureDetector(
      onTap: onSeatTapA == null ? null : () => onSeatTapA!(seat),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (occupant != null)
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppColors.primaryGradient,
                  ),
                  child: AppAvatar(
                    name: occupant.name,
                    imageUrl: occupant.avatarUrl,
                    size: 42,
                  ),
                )
              else
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.25),
                    border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.7),
                    ),
                  ),
                  child: const Icon(
                    Icons.event_seat_rounded,
                    color: AppColors.gold,
                    size: 20,
                  ),
                ),
              if (showBadge)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: Colors.white,
                      size: 10,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            occupant?.name ?? label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _seat(String key, String label) {
    final locked = lockedSeats.contains(key);
    return GestureDetector(
      onTap: onSeatTap == null ? null : () => onSeatTap!(key),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.25),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.7)),
            ),
            child: Icon(
              locked ? Icons.lock_rounded : Icons.event_seat_rounded,
              color: AppColors.gold,
              size: 20,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            locked ? 'Locked' : label,
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
