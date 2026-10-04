import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/level_star.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// One line of live-room chat. Shared by the host's screen and the video /
/// audio viewer screens so they all look the same.
///
/// A join notice ("Riya joined the live stream", written by the server as a
/// `system` message) gets its own look — bold, with a one-off shine sweeping
/// across the name, in brand colours, with the person's Wealth (gold) and
/// Charm (purple) level stars beside the name — so arrivals stand out from
/// ordinary chat. Give each line a `key: ObjectKey(line)` so the shine plays
/// once per notice rather than being reused by a different line that lands in
/// the same list slot.
class LiveChatLineBubble extends StatelessWidget {
  const LiveChatLineBubble({
    super.key,
    required this.line,
    this.backgroundAlpha = 0.32,
    this.pinnedAlpha = 0.35,
  });

  final LiveChatLine line;
  final double backgroundAlpha;
  final double pinnedAlpha;

  @override
  Widget build(BuildContext context) {
    if (line.isJoin) return _JoinNotice(line: line);
    if (line.isLeave) return _JoinNotice(line: line, verb: 'left');
    if (line.isSticker) {
      return _StickerBubble(line: line, backgroundAlpha: backgroundAlpha);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: line.pinned
            ? AppColors.primary.withValues(alpha: pinnedAlpha)
            : Colors.black.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(14),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'Poppins', fontSize: 11.5),
          children: [
            if (line.pinned)
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.push_pin_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
            TextSpan(
              text: '${line.user.name}  ',
              style: TextStyle(
                color: line.gift ? AppColors.gold : AppColors.primaryBright,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: line.text,
              style: TextStyle(
                color: line.gift ? AppColors.gold : Colors.white,
                fontWeight: line.gift ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A GIF / animated sticker from the emoji catalog: the sender's name, then the
/// picture playing on its own.
class _StickerBubble extends StatelessWidget {
  const _StickerBubble({required this.line, required this.backgroundAlpha});
  final LiveChatLine line;
  final double backgroundAlpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.user.name,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryBright,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox.square(
            dimension: 72,
            child: RemoteMedia(
              line.stickerUrl!,
              fit: BoxFit.contain,
              fallback: Center(
                child: Text(
                  line.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Riya joined" / "Riya left": the same bold, level-badged, glowing notice for
/// both — leaving looks exactly like arriving, only the word differs.
class _JoinNotice extends StatelessWidget {
  const _JoinNotice({required this.line, this.verb = 'joined'});
  final LiveChatLine line;
  final String verb;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primaryBright.withValues(alpha: 0.7),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'Poppins',
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
          ),
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _ShinyName(name: line.user.name),
            ),
            const WidgetSpan(child: SizedBox(width: 6)),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: LevelStars(
                wealth: line.user.wealthLevel,
                charm: line.user.charmLevel,
                size: 16,
                charmShimmer: StarShimmer.once,
              ),
            ),
            TextSpan(
              text: '  ${tr(verb)}',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name in brand colours with a bright band that sweeps across it once.
class _ShinyName extends StatelessWidget {
  const _ShinyName({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1600),
      builder: (_, t, _) {
        final c = t * 1.6 - 0.3;
        double s(double v) => v.clamp(0.0, 1.0);
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(
            colors: const [AppColors.pink, Colors.white, AppColors.pink],
            stops: [s(c - 0.18), s(c), s(c + 0.18)],
          ).createShader(r),
          child: Text(
            name,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }
}
