import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// What kind of live a card shows: an AUDIO room, a VIDEO live, or a PK battle.
enum LiveKind { audio, video, pk }

/// The kind of [stream]: PK when it is an old PK-mode live or an ordinary live that is in a battle right now (the label says what is happening on screen),
/// else Audio or Video by its mode.
LiveKind liveKindOf(LiveStream stream) {
  if (stream.pk || stream.inBattle) return LiveKind.pk;
  return stream.mode == LiveMode.audio ? LiveKind.audio : LiveKind.video;
}

/// The label in the corner of a live card: a coloured pill with an icon and "Audio", "Video" or "PK" (purple mic, pink camera, gold bolt), so people see at a
/// glance what they are about to join. [dense] is the smaller one for list rows.
class LiveTypeLabel extends StatelessWidget {
  const LiveTypeLabel({super.key, required this.kind, this.dense = false});

  final LiveKind kind;
  final bool dense;

  static const _audio = LinearGradient(colors: [Color(0xFFB45CFF), Color(0xFF7B3FF2)]);
  static const _video = LinearGradient(colors: [Color(0xFFFF5DA8), Color(0xFFE8338F)]);

  @override
  Widget build(BuildContext context) {
    final (gradient, icon, label, ink) = switch (kind) {
      LiveKind.audio => (_audio, Icons.mic_rounded, 'Audio', Colors.white),
      LiveKind.video => (_video, Icons.videocam_rounded, 'Video', Colors.white),
      LiveKind.pk => (AppColors.goldGradient, Icons.bolt_rounded, 'PK', const Color(0xFF3A1A5E)),
    };
    final bubble = dense ? 13.0 : 16.0;
    return Container(
      key: ValueKey('live-type-${kind.name}'),
      padding: EdgeInsets.fromLTRB(dense ? 3 : 4, dense ? 2 : 3, dense ? 8 : 10, dense ? 2 : 3),
      decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: bubble,
            height: bubble,
            decoration: BoxDecoration(color: ink.withValues(alpha: 0.22), shape: BoxShape.circle),
            child: Icon(icon, size: bubble - 4, color: ink),
          ),
          SizedBox(width: dense ? 3 : 4),
          Text(label, style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: dense ? 9.5 : 11, height: 1.2, color: ink)),
        ],
      ),
    );
  }
}
