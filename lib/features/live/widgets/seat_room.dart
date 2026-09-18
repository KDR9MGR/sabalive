import 'package:flutter/material.dart';

import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// One seat circle — empty/locked/occupied/muted — shared by the full
/// [SeatRoom] backdrop (audio rooms) and the slim [CompactSeatStrip]
/// (video-mode overlay), so both always render a seat identically.
class SeatCircle extends StatelessWidget {
  const SeatCircle({
    super.key,
    required this.seat,
    this.occupant,
    this.locked = false,
    this.muted = false,
    this.size = 58,
    this.onTap,
    this.showLabel = true,
  });

  final int seat;
  final AppUser? occupant;
  final bool locked;
  final bool muted;
  final double size;
  final VoidCallback? onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (occupant case final occupant?)
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppColors.primaryGradient,
                  ),
                  child: AppAvatar(name: occupant.name, size: size - 4),
                )
              else
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.06),
                    border: Border.all(
                        color: locked
                            ? AppColors.gold.withValues(alpha: 0.7)
                            : Colors.white.withValues(alpha: 0.18)),
                  ),
                  child: Icon(
                      locked ? Icons.lock_rounded : Icons.mic_none_rounded,
                      color: locked ? AppColors.gold : Colors.white38,
                      size: size * 0.38),
                ),
              if (occupant != null && muted)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                        color: AppColors.danger, shape: BoxShape.circle),
                    child: const Icon(Icons.mic_off_rounded,
                        color: Colors.white, size: 11),
                  ),
                ),
            ],
          ),
          if (showLabel) ...[
            const SizedBox(height: 4),
            SizedBox(
              width: size,
              child: Text(occupant?.name ?? (locked ? 'Locked' : 'Seat $seat'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.5, color: Colors.white38)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Voice-room stage: host on top, a 5-per-row grid of guest seats below.
/// Shared by the host's own broadcast screen (seats are editable —
/// add/remove/lock) and the viewer's watch screen (read-only — omit
/// onAddSeat/onRemoveSeat).
class SeatRoom extends StatelessWidget {
  const SeatRoom({
    super.key,
    required this.host,
    this.error,
    required this.seatCount,
    required this.lockedSeats,
    required this.onSeatTap,
    this.onAddSeat,
    this.onRemoveSeat,
    this.occupants = const {},
    this.mutedSeats = const {},
  });
  final AppUser host;
  final String? error;
  final int seatCount;
  final Set<int> lockedSeats;
  final void Function(int seat) onSeatTap;
  final VoidCallback? onAddSeat;
  final VoidCallback? onRemoveSeat;
  /// Who's actually sitting where, keyed by seat number (1-based). Empty by
  /// default so callers that don't track occupancy render exactly as before.
  final Map<int, AppUser> occupants;
  /// Seat numbers whose occupant has muted themselves.
  final Set<int> mutedSeats;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1140), Color(0xFF0B0716)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 90, 20, 0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.5),
                        blurRadius: 26),
                  ],
                ),
                child: AppAvatar(name: host.name, size: 88),
              ),
              const SizedBox(height: 8),
              Text(host.name,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.white)),
              const Text('Host',
                  style: TextStyle(fontSize: 10, color: Colors.white60)),
              const SizedBox(height: 24),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)),
                )
              else ...[
                GridView.count(
                  crossAxisCount: 5,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 4,
                  childAspectRatio: 0.72,
                  children: [
                    for (var i = 1; i <= seatCount; i++)
                      SeatCircle(
                        seat: i,
                        occupant: occupants[i],
                        locked: lockedSeats.contains(i),
                        muted: mutedSeats.contains(i),
                        onTap: () => onSeatTap(i),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _seatBtn(Icons.remove_rounded, 'Remove 5', onRemoveSeat),
                    const SizedBox(width: 12),
                    _seatBtn(Icons.add_rounded, 'Add 5', onAddSeat),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _seatBtn(IconData icon, String label, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(fontSize: 11.5, color: Colors.white)),
          ]),
        ),
      ),
    );
  }
}

/// Slim horizontal row of seat circles only — no host header, no backdrop —
/// for overlaying along the bottom of a video live stream without blocking
/// the camera feed. Same nullable-onSeatTap read-only convention as
/// [SeatRoom]; video mode has no host-adjustable seat count, so there's no
/// add/remove affordance here at all.
class CompactSeatStrip extends StatelessWidget {
  const CompactSeatStrip({
    super.key,
    required this.seatCount,
    required this.occupants,
    this.lockedSeats = const {},
    this.mutedSeats = const {},
    this.onSeatTap,
  });

  final int seatCount;
  final Map<int, AppUser> occupants;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final void Function(int seat)? onSeatTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: seatCount,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final seat = i + 1;
          return SeatCircle(
            seat: seat,
            occupant: occupants[seat],
            locked: lockedSeats.contains(seat),
            muted: mutedSeats.contains(seat),
            size: 46,
            showLabel: false,
            onTap: onSeatTap == null ? null : () => onSeatTap!(seat),
          );
        },
      ),
    );
  }
}
