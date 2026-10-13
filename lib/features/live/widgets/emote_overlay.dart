import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/widgets/remote_media.dart';

/// How long an emote stays on someone's picture circle. Slow on purpose: it pops in over about a second, floats
/// gently, and fades out over about a second.
const Duration kEmoteHold = Duration(milliseconds: 5500);

/// One emote showing on someone's picture circle: a plain emoji (`emoji`) or an animated one from the panel (`assetUrl`).
class ActiveEmote {
  const ActiveEmote({required this.id, this.emoji, this.assetUrl});

  /// Changes with every new emote, so the same emote sent twice in a row plays again.
  final int id;
  final String? emoji;
  final String? assetUrl;
}

/// Plain emoji only: one to three emoji (with their joiners, skin tones and flags) and nothing else. Anything with a
/// letter, a number or other text is a normal message. Returns the emoji, or null.
String? emoteTextOf(String body) {
  final t = body.trim();
  if (t.isEmpty || t.length > 32) return null;
  if (!_onlyEmoji.hasMatch(t)) return null;
  // a flag is two regional indicators; a keycap is one emoji; a skin tone / joiner belongs to the emoji before it
  final count = _pictograph.allMatches(t).length +
      _regional.allMatches(t).length ~/ 2 +
      _keycap.allMatches(t).length;
  return count >= 1 && count <= 3 ? t : null;
}

final RegExp _onlyEmoji = RegExp(
  r'^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Regional_Indicator}|[#*0-9]\uFE0F?\u20E3|\u200D|\uFE0F|\s)+$',
  unicode: true,
);
final RegExp _pictograph = RegExp(r'\p{Extended_Pictographic}', unicode: true);
final RegExp _regional = RegExp(r'\p{Regional_Indicator}', unicode: true);
final RegExp _keycap = RegExp(r'[#*0-9]\uFE0F?\u20E3', unicode: true);

/// The emotes on screen right now, one per person, each shown for [hold] and then gone.
///
/// A screen feeds it every live chat row ([handleRow]). A row that is just an emoji, or an animated emote from the
/// panel's catalog, plays on the sender's picture circle (their seat, or the host's name pill) when they have one on
/// screen; the caller then skips the chat line, since the emote already showed. Someone without a circle on screen
/// (a viewer not on a seat) keeps the chat line, which is the only place their emote can show.
class EmoteController extends ChangeNotifier {
  EmoteController({this.hold = kEmoteHold});

  final Duration hold;
  final Map<String, ActiveEmote> _active = {};
  final Map<String, Timer> _timers = {};
  int _n = 0;
  bool _disposed = false;

  /// What [userId] is emoting right now, if anything.
  ActiveEmote? of(String? userId) => userId == null ? null : _active[userId];

  /// Shows an emote on [userId]'s circle (replacing the one already there).
  void show(String userId, {String? emoji, String? assetUrl}) {
    if (_disposed) return;
    if ((emoji == null || emoji.isEmpty) && (assetUrl == null || assetUrl.isEmpty)) return;
    _timers.remove(userId)?.cancel();
    _active[userId] = ActiveEmote(id: ++_n, emoji: emoji, assetUrl: assetUrl);
    _timers[userId] = Timer(hold, () {
      _timers.remove(userId);
      if (_active.remove(userId) != null && !_disposed) notifyListeners();
    });
    notifyListeners();
  }

  /// Looks at one live chat row. Returns true when it was an emote that now plays on the sender's circle, so the
  /// caller should NOT also add it to the chat. [hasCircle] says whether a person has a picture circle on this screen.
  bool handleRow(Map<String, dynamic> row, {required bool Function(String senderId) hasCircle}) {
    final senderId = row['sender_id'] as String?;
    if (senderId == null) return false;
    final kind = row['kind'];
    String? emoji;
    String? asset;
    if (kind == 'sticker') {
      asset = (row['sticker_url'] as String?)?.trim();
      if (asset == null || asset.isEmpty) return false;
    } else if (kind == 'text') {
      emoji = emoteTextOf('${row['body'] ?? ''}');
      if (emoji == null) return false;
    } else {
      return false;
    }
    if (!hasCircle(senderId)) return false;
    show(senderId, emoji: emoji, assetUrl: asset);
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}

/// The emote itself, drawn over a picture circle: pops in, stays, fades out. Fills the box it is given, so put it over
/// the picture (with `Positioned.fill`).
class EmoteOverlay extends StatefulWidget {
  const EmoteOverlay({super.key, required this.emote, this.hold = kEmoteHold});

  final ActiveEmote emote;
  final Duration hold;

  @override
  State<EmoteOverlay> createState() => _EmoteOverlayState();
}

class _EmoteOverlayState extends State<EmoteOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.hold)..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Grows in slowly over the first 18% (about a second), then breathes gently while it holds.
  static double _scale(double t) {
    if (t < 0.18) return Curves.easeOutBack.transform(t / 0.18).clamp(0.0, 1.15);
    return 1 + 0.05 * math.sin((t - 0.18) * math.pi * 6);
  }

  /// Fades in over the first 8% and out over the last 20% (about a second).
  static double _opacity(double t) {
    if (t < 0.08) return t / 0.08;
    if (t > 0.8) return 1 - Curves.easeIn.transform((t - 0.8) / 0.2);
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.emote;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Opacity(
          opacity: _opacity(_c.value).clamp(0.0, 1.0),
          child: Transform.scale(scale: _scale(_c.value), child: child),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final side = box.biggest.shortestSide.isFinite ? box.biggest.shortestSide : 40.0;
            return DecoratedBox(
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x66000000)),
              child: Center(
                child: e.assetUrl != null
                    ? Padding(
                        padding: EdgeInsets.all(side * 0.12),
                        child: RemoteMedia(
                          e.assetUrl!,
                          key: ValueKey(e.id),
                          fit: BoxFit.contain,
                          loop: true,
                          fallback: const SizedBox.shrink(),
                        ),
                      )
                    : Text(e.emoji ?? '', style: TextStyle(fontSize: side * 0.6, height: 1)),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Puts [controller]'s emote for [userId] over [child] (their avatar), `scale` times the avatar's size and centred on
/// it, so a small avatar still gets an emote you can read. Does nothing extra while there is no emote.
class EmoteOnAvatar extends StatelessWidget {
  const EmoteOnAvatar({
    super.key,
    required this.controller,
    required this.userId,
    required this.size,
    required this.child,
    this.scale = 1.6,
  });

  final EmoteController? controller;
  final String? userId;
  final double size;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) return child;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final emote = c.of(userId);
        if (emote == null) return child;
        final big = size * scale;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            child,
            Positioned(
              left: (size - big) / 2,
              top: (size - big) / 2,
              width: big,
              height: big,
              child: EmoteOverlay(key: ValueKey(emote.id), emote: emote, hold: c.hold),
            ),
          ],
        );
      },
    );
  }
}
