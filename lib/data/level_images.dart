import 'package:flutter/foundation.dart';

import '../core/widgets/remote_media.dart' show MediaKind, mediaKindFor;
import 'level_banner_images.dart';

/// The pictures the panel set per level (Master -> Levels), as the small level chip: where a level has one it replaces the star on the profile, in chat and in
/// the join notice. The picture is the same file the join banner uses; the number is not written on it (it is part of the picture), and a level with no
/// picture keeps the star, exactly: a person at level 5 does NOT borrow level 2's picture.
///
/// Only a STILL picture or a GIF / WebP counts here. An animated file (SVGA, MP4) still plays full-screen when somebody joins, but as a chip it would animate
/// in every chat line, which costs battery, so those levels keep the star.
///
/// Read once and remembered (it shares [LevelBannerImages]' read); everything FAILS OPEN: no server, an old database, or a bad row just means "the star".
class LevelImageStore extends ChangeNotifier {
  LevelImageStore({Future<List<LevelBannerStep>?> Function()? loader}) : _loader = loader ?? (() => LevelBannerImages.instance.steps());

  /// The one the level chips share.
  static final LevelImageStore instance = LevelImageStore();

  final Future<List<LevelBannerStep>?> Function() _loader;
  Map<String, String> _urls = const {};
  bool _loading = false;
  DateTime? _at;

  /// How long a read is trusted before the next chip asks again (the read itself is also remembered by [LevelBannerImages]).
  static const Duration ttl = Duration(minutes: 10);

  static String _key(String track, int level) => '$track:$level';

  /// The picture for exactly this level of [track] ('wealth' or 'charm'), or null (show the star).
  String? urlFor(String track, int level) => _urls[_key(track, level)];

  /// Makes these the pictures (tests, and the read below). Tells listeners only when something changed.
  void usePictures(Map<String, String> next) {
    if (mapEquals(next, _urls)) return;
    _urls = next;
    notifyListeners();
  }

  /// Reads the pictures if they have not been read lately. Never throws and never blocks a chip: until it answers (or if it fails) the stars show.
  Future<void> ensureLoaded() async {
    final at = _at;
    if (_loading || (at != null && DateTime.now().difference(at) < ttl)) return;
    _loading = true;
    try {
      final steps = await _loader();
      if (steps == null) return; // could not be read: keep what we have and ask again next time
      _at = DateTime.now();
      usePictures({
        for (final s in steps)
          if (_isStill(s.url)) _key(s.track, s.level): s.url,
      });
    } catch (_) {
      // keep the stars
    } finally {
      _loading = false;
    }
  }

  static bool _isStill(String url) {
    final kind = mediaKindFor(url);
    return kind == MediaKind.image || kind == MediaKind.animatedImage;
  }

  /// For tests: forget everything read.
  void reset() {
    _urls = const {};
    _at = null;
    _loading = false;
  }
}
