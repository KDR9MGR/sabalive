import 'package:flutter/material.dart';

import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// Voice-room stage: host on top, a ring of guest seats below. Shared by the
/// host's own broadcast screen (seats are editable — add/remove/lock) and
/// the viewer's watch screen (read-only — omit onAddSeat/onRemoveSeat).
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
                Wrap(
                  spacing: 18,
                  runSpacing: 18,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var i = 1; i <= seatCount; i++)
                      GestureDetector(
                        onTap: () => onSeatTap(i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (occupants[i] case final occupant?)
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: AppColors.primaryGradient,
                                ),
                                child: AppAvatar(name: occupant.name, size: 54),
                              )
                            else
                              Container(
                                width: 58,
                                height: 58,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.06),
                                  border: Border.all(
                                      color: lockedSeats.contains(i)
                                          ? AppColors.gold.withValues(alpha: 0.7)
                                          : Colors.white.withValues(alpha: 0.18)),
                                ),
                                child: Icon(
                                    lockedSeats.contains(i)
                                        ? Icons.lock_rounded
                                        : Icons.mic_none_rounded,
                                    color: lockedSeats.contains(i)
                                        ? AppColors.gold
                                        : Colors.white38,
                                    size: 22),
                              ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 58,
                              child: Text(occupants[i]?.name ?? 'Seat $i',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 9.5, color: Colors.white38)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _seatBtn(Icons.remove_rounded, 'Remove seat', onRemoveSeat),
                    const SizedBox(width: 12),
                    _seatBtn(Icons.add_rounded, 'Add seat', onAddSeat),
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
