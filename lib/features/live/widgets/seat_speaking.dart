import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;

import '../../../data/models.dart';
import '../../../core/i18n/text.dart';

/// Works out which seats are talking right now. Agora reports volume per Agora uid
/// (uid 0 is this device); a seat's holder publishes their uid on the seat row and
/// the host's is on the stream row, so a uid maps back to a seat.
class SeatSpeaking {
  final Map<int, int> _seatByUid = {};
  int? _hostUid;

  /// Agora uids are unsigned 32-bit numbers. Depending on the layer that reports them they
  /// can arrive as a negative number for the large ones, so every uid is compared in its
  /// unsigned form and a match can never be missed because of the sign.
  static int _u(int uid) => uid & 0xFFFFFFFF;

  /// The host's Agora uid (live_streams.host_agora_uid), when known.
  int? get hostUid => _hostUid;
  set hostUid(int? uid) => _hostUid = uid == null ? null : _u(uid);

  /// Remember (or, with a null [uid], forget) which Agora uid sits in [seat].
  void bindSeat(int seat, int? uid) {
    _seatByUid.removeWhere((_, s) => s == seat);
    if (uid != null) _seatByUid[_u(uid)] = seat;
  }

  void unbindSeat(int seat) => bindSeat(seat, null);

  /// The seats whose holder is talking, from one volume report.
  Set<int> seatsFor(
    List<AudioVolumeInfo> speakers, {
    required Map<int, AppUser> occupants,
    required String hostId,
    required int? mySeat,
    required bool meMuted,
    int threshold = 25,
  }) {
    int? hostSeat() {
      for (final e in occupants.entries) {
        if (e.value.id == hostId) return e.key;
      }
      return null;
    }

    final out = <int>{};
    for (final s in speakers) {
      if ((s.volume ?? 0) < threshold) continue;
      final uid = s.uid ?? 0;
      int? seat;
      if (uid == 0) {
        seat = meMuted ? null : mySeat;
      } else {
        final u = _u(uid);
        seat = _seatByUid[u] ?? (u == _hostUid ? hostSeat() : null);
      }
      if (seat != null) out.add(seat);
    }
    return out;
  }

  /// Whether the host is talking right now, from one volume report. In a video live the
  /// host is on screen rather than in a seat, so this is how their voice is shown.
  /// [iAmHost] is true on the host's own screen, where their voice is Agora's uid 0.
  bool hostTalking(
    List<AudioVolumeInfo> speakers, {
    required bool iAmHost,
    required bool meMuted,
    int threshold = 25,
  }) {
    for (final s in speakers) {
      if ((s.volume ?? 0) < threshold) continue;
      final uid = s.uid ?? 0;
      if (uid == 0) {
        if (iAmHost && !meMuted) return true;
      } else if (_hostUid != null && _u(uid) == _hostUid) {
        return true;
      }
    }
    return false;
  }

  static bool same(Set<int> a, Set<int> b) => setEquals(a, b);
}

/// One line of text that scrolls sideways, slowly, when it is too long for [width]
/// (a long seat name); a short one just sits centred.
class MarqueeText extends StatefulWidget {
  const MarqueeText(this.text, {super.key, required this.width, required this.style});

  final String text;
  final double width;
  final TextStyle style;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  double _overflow = 0;
  String? _measuredText;

  /// How many slow passes it makes each time it starts, then it rests (no timers,
  /// and no nonstop animation on every seat — kinder to the battery).
  static const _passes = 4;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Measured while building (pure); the animation itself is started after the frame,
  /// never from inside a build.
  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final overflow = tp.width - widget.width;
    if (overflow == _overflow && widget.text == _measuredText) return;
    _overflow = overflow;
    _measuredText = widget.text;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restart(overflow));
  }

  void _restart(double overflow) {
    if (!mounted || overflow != _overflow) return;
    if (overflow <= 0) {
      _c.stop();
      _c.value = 0;
      return;
    }
    // ~22 px a second, with a pause at each end of every pass
    _c.duration = Duration(milliseconds: (overflow / 22 * 1000).round() + 2400);
    _c.repeat(count: _passes);
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    if (_overflow <= 0) {
      return SizedBox(
        width: widget.width,
        child: Text(widget.text, maxLines: 1, textAlign: TextAlign.center, style: widget.style),
      );
    }
    return ClipRect(
      child: SizedBox(
        width: widget.width,
        height: (widget.style.fontSize ?? 10) * 1.5,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = ((_c.value - 0.2) / 0.6).clamp(0.0, 1.0);
            return OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              child: Transform.translate(
                offset: Offset(-_overflow * t, 0),
                child: Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
              ),
            );
          },
        ),
      ),
    );
  }
}
