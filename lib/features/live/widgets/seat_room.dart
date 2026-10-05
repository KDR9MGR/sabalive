import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import 'seat_speaking.dart';
import 'speaking_waves.dart';
import '../../../core/i18n/text.dart';

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
    this.isHost = false,
    this.speaking = false,
    this.diamonds,
    this.size = 58,
    this.onTap,
    this.showLabel = true,
  });

  final int seat;
  final AppUser? occupant;
  final bool locked;
  final bool muted;
  /// True when this seat's occupant is the room's host — audio rooms no
  /// longer give the host a separate avatar above the grid; the host just
  /// sits in one of the numbered seats like anyone else, marked with a
  /// small badge so viewers can still tell who they are.
  final bool isHost;

  /// Their voice is coming through right now — the seat lights up.
  final bool speaking;

  /// Diamonds this seat's holder has earned in this stream today. When set, the label
  /// under the seat swaps between their name and this count every 7 seconds.
  final int? diamonds;
  final double size;
  final VoidCallback? onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Without this, a tap only registers on the small icon glyph inside
      // the circle (its own painted text), not the visibly larger colored
      // circle around it — same class of hit-testing gap already noted for
      // AppThumb: a GestureDetector defers to its child's own hit bounds
      // unless told to claim the whole area itself.
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (occupant case final occupant?)
                // the ring of waves around the avatar is the "this person is talking" cue
                SpeakingWaves(
                  active: speaking,
                  diameter: size,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppColors.primaryGradient,
                    ),
                    child: AppAvatar(name: occupant.name, imageUrl: occupant.avatarUrl, frameUrl: occupant.frameUrl, size: size - 4),
                  ),
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
                      locked ? Icons.lock_rounded : Icons.event_seat_rounded,
                      color: locked ? AppColors.gold : Colors.white54,
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
              if (occupant != null && isHost)
                Positioned(
                  left: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                        color: AppColors.gold, shape: BoxShape.circle),
                    child: const Icon(Icons.star_rounded,
                        color: Colors.white, size: 11),
                  ),
                ),
            ],
          ),
          if (showLabel) ...[
            const SizedBox(height: 4),
            SeatLabel(
              name: occupant?.name ?? (locked ? 'Locked' : 'Seat $seat'),
              diamonds: occupant == null ? null : diamonds,
              width: size,
              bright: occupant != null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Voice-room stage: a 5-per-row grid of numbered seats, one of which the
/// host occupies like anyone else (marked with [SeatCircle]'s host badge)
/// rather than getting a separate avatar above the grid. Shared by the
/// host's own broadcast screen (seats are editable — add/remove/lock) and
/// the viewer's watch screen (read-only — omit onAddSeat/onRemoveSeat).
class SeatRoom extends StatelessWidget {
  const SeatRoom({
    super.key,
    required this.hostId,
    this.error,
    required this.seatCount,
    required this.lockedSeats,
    required this.onSeatTap,
    this.onAddSeat,
    this.onRemoveSeat,
    this.occupants = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.diamonds = const {},
    this.skinUrl,
  });
  final String hostId;
  /// The host's equipped room skin (admin-uploaded SVGA / MP4 / image), drawn
  /// behind the seats. Null shows the default purple gradient.
  final String? skinUrl;
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

  /// Seat numbers whose occupant is talking right now.
  final Set<int> speakingSeats;

  /// Diamonds earned in this stream today, by user id.
  final Map<String, int> diamonds;

  @override
  Widget build(BuildContext context) {
    const gradient = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1B1140), Color(0xFF0B0716)],
      ),
    );
    final skin = skinUrl;
    return DecoratedBox(
      decoration: gradient,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (skin != null) ...[
            RemoteMedia(skin, key: ValueKey(skin), fit: BoxFit.cover),
            // keeps seat names and badges readable over any artwork
            const ColoredBox(color: Color(0x59000000)),
          ],
          _content(context),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 90, 20, 0),
        child: Column(
          children: [
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
                      speaking: speakingSeats.contains(i),
                      diamonds: occupants[i] == null ? null : (diamonds[occupants[i]!.id] ?? 0),
                      isHost: occupants[i]?.id == hostId,
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
    );
  }

  Widget _seatBtn(IconData icon, String label, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
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
    this.speakingSeats = const {},
    this.onSeatTap,
  });

  final int seatCount;
  final Map<int, AppUser> occupants;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;
  final void Function(int seat)? onSeatTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 70,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // room around the seats for the speaking waves, which stand outside the avatar
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: seatCount,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final seat = i + 1;
          return SeatCircle(
            seat: seat,
            occupant: occupants[seat],
            locked: lockedSeats.contains(seat),
            muted: mutedSeats.contains(seat),
            speaking: speakingSeats.contains(seat),
            size: 46,
            showLabel: false,
            onTap: onSeatTap == null ? null : () => onSeatTap!(seat),
          );
        },
      ),
    );
  }
}

/// The text under a seat: the holder's name, or — when [diamonds] is given — the name
/// and the diamonds they have earned in this stream today, swapping every 7 seconds.
class SeatLabel extends StatefulWidget {
  const SeatLabel({
    super.key,
    required this.name,
    required this.width,
    this.diamonds,
    this.bright = true,
  });

  final String name;
  final int? diamonds;
  final double width;
  final bool bright;

  @override
  State<SeatLabel> createState() => _SeatLabelState();
}

class _SeatLabelState extends State<SeatLabel> {
  static const _every = Duration(seconds: 7);
  Timer? _timer;
  bool _showDiamonds = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SeatLabel old) {
    super.didUpdateWidget(old);
    if ((old.diamonds == null) != (widget.diamonds == null)) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    _showDiamonds = false;
    if (widget.diamonds == null) return;
    _timer = Timer.periodic(_every, (_) {
      if (mounted) setState(() => _showDiamonds = !_showDiamonds);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  TextStyle get _style => TextStyle(
        fontSize: 10,
        fontWeight: widget.bright ? FontWeight.w600 : FontWeight.w500,
        color: widget.bright ? Colors.white : Colors.white70,
        shadows: const [Shadow(color: Colors.black87, blurRadius: 3)],
      );

  @override
  Widget build(BuildContext context) {
    final diamonds = widget.diamonds;
    final showing = diamonds != null && _showDiamonds;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: showing
          ? SizedBox(
              key: const ValueKey('diamonds'),
              width: widget.width,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.diamond_rounded, size: 11, color: AppColors.diamond),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      compactCount(diamonds),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _style.copyWith(color: AppColors.diamond),
                    ),
                  ),
                ],
              ),
            )
          : MarqueeText(
              widget.name,
              key: ValueKey('name:${widget.name}'),
              width: widget.width,
              style: _style,
            ),
    );
  }
}
