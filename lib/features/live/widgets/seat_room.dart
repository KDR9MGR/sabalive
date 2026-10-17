import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import '../../../state/remote_config_controller.dart';
import 'emote_overlay.dart';
import 'seat_speaking.dart';
import 'speaking_waves.dart';
import 'wave_colors.dart';
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
    this.size = 56,
    this.slot,
    this.emotes,
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

  /// The square the seat's picture (and frame) is centred in, when the layout wants every seat of a row to take the
  /// same room so their names line up (the audio room's grid). A frame is drawn INSIDE it, so it can never spill over
  /// the next seat or label. Null = just as big as the seat needs.
  final double? slot;

  /// The emotes people are sending right now: one sent by this seat's holder plays over their picture circle.
  final EmoteController? emotes;
  final VoidCallback? onTap;
  final bool showLabel;

  /// How much bigger the host's own seat is drawn than a guest's, so the host stands out in the room.
  static const double hostExtra = 10;

  /// How far (each side) the host's frame may reach past its slot: the artwork is see-through at its edge, and the host
  /// is meant to stand out. Small enough that it stays inside the gap above a seat's name.
  static const double hostFrameOverhang = 4;

  /// The size of the box a seat's avatar takes, frame included: [plain] without a frame, [plain] x
  /// [AppAvatar.frameScale] with one, but never more than the [slot] it sits in (the host may reach
  /// [hostFrameOverhang] past it).
  static double footprintOf({required double plain, required bool framed, double? slot, bool isHost = false}) {
    if (!framed) return plain;
    final wanted = plain * AppAvatar.frameScale;
    if (slot == null) return wanted;
    final cap = slot + (isHost ? hostFrameOverhang * 2 : 0);
    return wanted > cap ? cap : wanted;
  }

  @override
  Widget build(BuildContext context) {
    // the host's seat is a little bigger than the others
    final plain = isHost && occupant != null ? size + hostExtra : size;
    final frame = occupant?.frameUrl;
    final framed = occupant != null && AppAvatar.showsFrame(plain * AppAvatar.frameScale, frame);
    final footprint = footprintOf(plain: plain, framed: framed, slot: slot, isHost: isHost);
    // what the layout reserves for the seat's picture: the slot when there is one
    final reserve = slot ?? footprint;
    // the frame fills the footprint and the picture sits inside it; badges sit on the picture's edge
    final picture = framed ? footprint / AppAvatar.frameScale : plain;
    final inset = (footprint - picture) / 2;
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
          SizedBox(
            width: reserve,
            height: reserve,
            // the host's frame may reach a little past the slot
            child: OverflowBox(
              maxWidth: footprint > reserve ? footprint : reserve,
              maxHeight: footprint > reserve ? footprint : reserve,
              child: SizedBox(
                width: footprint,
                height: footprint,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    if (occupant case final occupant?)
                      // the ring of waves around the avatar is the "this person is talking" cue
                      SpeakingWaves(
                        // feature_flags.speaking_waves can switch the ring off from the panel
                        active: speaking && RemoteConfigController.instance.flag('speaking_waves'),
                        diameter: footprint,
                        // around the frame, in the host's green or a colour of their own; shorter bars with a
                        // frame, so the ring does not reach into the next seat
                        amplitude: framed ? 0.1 : 0.2,
                        // the artwork stops short of its box (83-96% of it): start the bars inside the box so they touch the frame
                        gap: framed ? -0.07 : 0.03,
                        color: waveColorFor(occupant.id, isHost: isHost),
                        child: framed
                            ? AppAvatar(
                                name: occupant.name,
                                imageUrl: occupant.avatarUrl,
                                frameUrl: occupant.frameUrl,
                                size: footprint,
                              )
                            : Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: AppColors.primaryGradient,
                                ),
                                child: AppAvatar(name: occupant.name, imageUrl: occupant.avatarUrl, size: footprint - 4),
                              ),
                      )
                    else
                      Container(
                        width: plain,
                        height: plain,
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
                            size: plain * 0.38),
                      ),
                    if (occupant != null && emotes != null)
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.all(inset),
                          child: ListenableBuilder(
                            listenable: emotes!,
                            builder: (context, _) {
                              final e = emotes!.of(occupant!.id);
                              if (e == null) return const SizedBox.shrink();
                              return EmoteOverlay(key: ValueKey(e.id), emote: e, hold: emotes!.hold);
                            },
                          ),
                        ),
                      ),
                    if (occupant != null && muted)
                      Positioned(
                        right: inset - 2,
                        bottom: inset - 2,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.mic_off_rounded, color: Colors.white, size: 11),
                        ),
                      ),
                    if (occupant != null && isHost)
                      Positioned(
                        left: inset - 2,
                        top: inset - 2,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle),
                          child: const Icon(Icons.star_rounded, color: Colors.white, size: 11),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (showLabel) ...[
            const SizedBox(height: 4),
            SeatLabel(
              name: occupant?.name ?? (locked ? 'Locked' : 'Seat $seat'),
              diamonds: occupant == null ? null : diamonds,
              width: reserve,
              bright: occupant != null,
            ),
          ],
        ],
      ),
    );
  }
}

/// The audio room's seat counts: 4 seats to a row, from one row (4) to four rows (16).
const int kMinAudioSeats = 4;
const int kMaxAudioSeats = 16;
const int kSeatStep = 4;
const int kSeatsPerRow = 4;

/// The seat count after the host taps Add (more) or Remove (fewer): always a full row of 4, so seats are added and
/// removed four at a time (4, 8, 12, 16) whatever the room started with. A room an older app made with another count
/// (5, 10, 25...) snaps to the next row, and one above 16 can only shrink, to 16 first.
/// Returns [current] when there is nowhere to go.
int nextSeatCount(int current, {required bool more}) {
  if (more) {
    if (current >= kMaxAudioSeats) return current;
    return ((current ~/ kSeatStep) + 1) * kSeatStep;
  }
  if (current <= kMinAudioSeats) return current;
  final down = ((current - 1) ~/ kSeatStep) * kSeatStep;
  return down.clamp(kMinAudioSeats, kMaxAudioSeats);
}

/// The audio room's seats, four to a row. Every seat reserves the same square for its picture and frame (as wide as a
/// cell lets it, leaving a line for the name), so a frame stays inside its own cell and the names line up. Shared by the
/// host's stage ([SeatRoom]) and the viewer's room, so both always lay seats out the same way.
class SeatGrid extends StatelessWidget {
  const SeatGrid({
    super.key,
    required this.seatCount,
    required this.occupants,
    required this.hostId,
    required this.onSeatTap,
    this.lockedSeats = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.diamonds = const {},
    this.emotes,
  });

  final int seatCount;
  final Map<int, AppUser> occupants;
  final String hostId;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;

  /// Diamonds earned in this stream today, by user id.
  final Map<String, int> diamonds;
  final EmoteController? emotes;
  final void Function(int seat) onSeatTap;

  static const double gap = 4;
  static const double aspect = 0.8;

  /// Under a seat's picture: the gap and one line for the name.
  static const double labelRoom = 20;

  /// The square a seat's picture (and frame) gets, for a grid [width] wide.
  static double slotFor(double width) {
    final cell = (width - gap * (kSeatsPerRow - 1)) / kSeatsPerRow;
    return math.min(math.min(cell, 56 * AppAvatar.frameScale), cell / aspect - labelRoom);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final slot = slotFor(box.maxWidth);
      return GridView.count(
        crossAxisCount: kSeatsPerRow,
        shrinkWrap: true,
        // the host's frame and the speaking rings may reach a little past a seat: don't cut them
        clipBehavior: Clip.none,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 18,
        crossAxisSpacing: gap,
        childAspectRatio: aspect,
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
              slot: slot,
              emotes: emotes,
              onTap: () => onSeatTap(i),
            ),
        ],
      );
    });
  }
}

/// Voice-room stage: a 4-per-row grid of numbered seats, one of which the
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
    this.header,
    this.occupants = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.diamonds = const {},
    this.skinUrl,
    this.emotes,
  });
  final String hostId;

  /// Emotes people are sending: one plays over its sender's seat.
  final EmoteController? emotes;
  /// The host's equipped room skin (admin-uploaded SVGA / MP4 / image), drawn
  /// behind the seats. Null shows the default purple gradient.
  final String? skinUrl;
  final String? error;
  final int seatCount;
  final Set<int> lockedSeats;
  final void Function(int seat) onSeatTap;
  final VoidCallback? onAddSeat;
  final VoidCallback? onRemoveSeat;

  /// Drawn above the seats (the PK battle header while a battle is on); null = nothing, the seats start where they always did.
  final Widget? header;
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
    final gradient = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [AppColors.roomTop, AppColors.bg],
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
              ?header,
              SeatGrid(
                seatCount: seatCount,
                occupants: occupants,
                lockedSeats: lockedSeats,
                mutedSeats: mutedSeats,
                speakingSeats: speakingSeats,
                diamonds: diamonds,
                hostId: hostId,
                emotes: emotes,
                onSeatTap: onSeatTap,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _seatBtn(Icons.remove_rounded, 'Remove 4', onRemoveSeat),
                  const SizedBox(width: 12),
                  _seatBtn(Icons.add_rounded, 'Add 4', onAddSeat),
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

/// The guest seats of a VIDEO live, stacked one above the other down the right-hand edge of the screen (over the
/// video, out of the way of the host's face and the chat). Empty seats are small and faint; people on a seat show
/// their avatar, frame and speaking ring. Same nullable-onSeatTap read-only convention as [SeatRoom].
class SeatColumn extends StatelessWidget {
  const SeatColumn({
    super.key,
    required this.seatCount,
    required this.occupants,
    this.lockedSeats = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.hostId,
    this.onSeatTap,
    this.maxHeight = 420,
    this.emotes,
  });

  /// Emotes people are sending: one plays over its sender's seat.
  final EmoteController? emotes;

  final int seatCount;
  final Map<int, AppUser> occupants;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;
  final String? hostId;
  final void Function(int seat)? onSeatTap;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 96),
      child: ListView.separated(
        shrinkWrap: true,
        // frames and speaking rings stand outside a seat
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        itemCount: seatCount,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (_, i) {
          final seat = i + 1;
          final occupant = occupants[seat];
          return Center(
            child: SeatCircle(
              seat: seat,
              occupant: occupant,
              locked: lockedSeats.contains(seat),
              muted: mutedSeats.contains(seat),
              speaking: speakingSeats.contains(seat),
              isHost: occupant != null && occupant.id == hostId,
              size: occupant == null ? 36 : 44,
              // a frame is kept inside the column's width (96 less the padding)
              slot: (occupant?.frameUrl ?? '').isEmpty ? null : 72,
              emotes: emotes,
              showLabel: false,
              onTap: onSeatTap == null ? null : () => onSeatTap!(seat),
            ),
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
