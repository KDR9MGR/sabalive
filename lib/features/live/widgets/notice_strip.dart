import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';

import '../../../core/i18n/text.dart' show tr;
import '../../../core/media/disk_cached_image.dart';
import '../../../core/utils/formatters.dart' show withThousands;
import '../../../data/notice_feed.dart';
import '../../../core/widgets/remote_media.dart';

/// What a notification strip announces.
enum NoticeKind { gift, gameWin }

/// One announcement for the strip: WHO (the sender / winner and, for a gift, the receiver), WHAT (the gift or coin picture) and an optional badge ("x5", "+1,320").
///
/// A gift reads: sender avatar and name, the gift in the middle, receiver avatar and name. A game win has no receiver: the winner on the left, a coin in the middle,
/// the game's name (or nothing) on the right.
class NoticeStripItem {
  const NoticeStripItem({
    required this.kind,
    required this.senderName,
    this.senderAvatarUrl,
    this.receiverName,
    this.receiverAvatarUrl,
    this.showReceiverAvatar = false,
    this.iconEmoji = '🎁',
    this.iconUrl,
    this.count = 1,
    this.badge,
  });

  /// The strip for what the server announced: a big gift (sender, gift with "xN", receiver or Everyone) or a big game win (winner, a coin with "+5,000", the game).
  factory NoticeStripItem.fromFeed(FeedNotice n) {
    if (n is GiftNotice) {
      return NoticeStripItem(
        kind: NoticeKind.gift,
        senderName: n.senderName,
        senderAvatarUrl: n.senderAvatarUrl,
        receiverName: n.toAll ? tr('Everyone') : n.receiverName,
        receiverAvatarUrl: n.toAll ? null : n.receiverAvatarUrl,
        showReceiverAvatar: !n.toAll && n.receiverName != null,
        iconEmoji: n.giftEmoji,
        iconUrl: n.giftIconUrl,
        count: n.quantity,
      );
    }
    final w = n as GameWinNotice;
    return NoticeStripItem(
      kind: NoticeKind.gameWin,
      senderName: w.winnerName,
      senderAvatarUrl: w.winnerAvatarUrl,
      receiverName: w.gameName,
      receiverAvatarUrl: w.gameImageUrl,
      showReceiverAvatar: w.gameImageUrl != null,
      iconEmoji: '🪙',
      badge: '+${withThousands(w.coins)}',
    );
  }

  final NoticeKind kind;
  final String senderName;
  final String? senderAvatarUrl;

  /// The right-hand name: the gift's receiver ("Everyone" for a gift to all), the game for a win, or null for nothing.
  final String? receiverName;
  final String? receiverAvatarUrl;

  /// Draw the right-hand avatar slot (a person receives it). False hides the slot (to everyone, a game win).
  final bool showReceiverAvatar;

  /// The picture in the middle: the panel's artwork when it is a picture the strip can draw as a still, otherwise this emoji.
  final String iconEmoji;
  final String? iconUrl;
  final int count;

  /// Text drawn on the middle picture's corner; defaults to "x" and the count when [count] is above 1.
  final String? badge;

  String? get badgeText => badge ?? (count > 1 ? 'x$count' : null);

  /// Two gifts that read exactly the same (same sender, gift, receiver) are one strip with a bigger count while they wait in the queue.
  bool sameAs(NoticeStripItem o) =>
      kind == o.kind && senderName == o.senderName && iconEmoji == o.iconEmoji && iconUrl == o.iconUrl && receiverName == o.receiverName && badge == null && o.badge == null;

  NoticeStripItem withCount(int c) => NoticeStripItem(
        kind: kind,
        senderName: senderName,
        senderAvatarUrl: senderAvatarUrl,
        receiverName: receiverName,
        receiverAvatarUrl: receiverAvatarUrl,
        showReceiverAvatar: showReceiverAvatar,
        iconEmoji: iconEmoji,
        iconUrl: iconUrl,
        count: c,
        badge: badge,
      );
}

/// Plays strips one after another in a lane of their own (like the level join banners): they never wait behind a gift effect and a busy room cannot pile them up.
/// Only the last few waiting are kept; with a few waiting each plays faster. The player calls [finish] when its animation ends; the timer is only a backstop.
class NoticeStripController extends ChangeNotifier {
  NoticeStripController({this.maxQueued = 4, this.hurryAt = 2, this.backstop = const Duration(seconds: 8)});

  final int maxQueued;

  /// With this many waiting, a strip plays at [hurrySpeed].
  final int hurryAt;
  final Duration backstop;
  static const double hurrySpeed = 1.5;

  final Queue<NoticeStripItem> _queue = Queue();
  NoticeStripItem? _current;
  double _speed = 1;
  int _playId = 0;
  Timer? _timer;
  bool _disposed = false;

  NoticeStripItem? get current => _current;
  int get playId => _playId;
  double get speed => _speed;
  int get waiting => _queue.length;

  void add(NoticeStripItem item) {
    if (_disposed) return;
    if (_queue.isNotEmpty && _queue.last.sameAs(item)) {
      final last = _queue.removeLast();
      _queue.add(last.withCount(last.count + item.count));
      return;
    }
    _queue.add(item);
    while (_queue.length > maxQueued) {
      _queue.removeFirst();
    }
    _startNext();
  }

  /// The strip [id] has finished (a late call for an earlier strip is ignored).
  void finish(int id) {
    if (_disposed || id != _playId || _current == null) return;
    _timer?.cancel();
    _current = null;
    _startNext();
    notifyListeners();
  }

  void _startNext() {
    if (_current != null || _queue.isEmpty) return;
    _speed = _queue.length >= hurryAt ? hurrySpeed : 1;
    _current = _queue.removeFirst();
    _playId++;
    final id = _playId;
    _timer?.cancel();
    _timer = Timer(backstop, () => finish(id));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

typedef NoticeImageLoader = Future<ui.Image?> Function(String url);

/// The bundled strips and how their five replaceable parts are filled. There are two files with the SAME layout (750 x 300, 30 fps, 85 frames, the same five slots), the owner's "full venue"
/// art: `gift_strip.svga` for a big gift (`full_venue_one.svga`, 2026-11-07) and `game_win_strip.svga` for a big game win (`full_venue_tow.svga`, 2026-11-05).
///
/// The file slides in from the right, holds about a second and a half, and slides out to the left on its own; the slots it names are `avator` (left avatar), `name1`
/// (left name), `gift` (middle picture), `avator2` (right avatar) and `name2` (right name).
abstract final class NoticeArt {
  static const asset = 'assets/notice/gift_strip.svga';
  static const gameWinAsset = 'assets/notice/game_win_strip.svga';

  /// The file a strip of this kind plays.
  static String assetFor(NoticeKind kind) => kind == NoticeKind.gameWin ? gameWinAsset : asset;
  static const double width = 750;
  static const double height = 300;
  static const leftAvatar = 'avator';
  static const rightAvatar = 'avator2';
  static const leftName = 'name1';
  static const rightName = 'name2';
  static const middle = 'gift';

  /// Local size of the name slots (the file scales them by 0.64): text is laid out and clipped to this.
  static const double leftNameWidth = 160;
  static const double rightNameWidth = 120;
  static const double nameHeight = 40;
  static const double middleSize = 100;

  static final Map<NoticeKind, Future<MovieEntity>> _movies = {};

  /// The decoded file for strips of [kind], read once per run and kept (a shared movie: `autorelease` off, never disposed).
  static Future<MovieEntity> movie({NoticeKind kind = NoticeKind.gift, SvgaLoader? loader}) {
    return _movies[kind] ??= (loader ?? _decodeAsset)(assetFor(kind)).then((m) {
      m.autorelease = false;
      return m;
    }, onError: (Object e) {
      _movies.remove(kind); // try again next time
      throw e;
    });
  }

  /// Reads both files a little apart (each is a few hundred KB to inflate on the UI thread), while the screen is calm; called a few seconds after a room or Home opens so the first strip does not stutter.
  static Future<void> prewarm() async {
    for (final kind in NoticeKind.values) {
      try {
        await movie(kind: kind);
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  static Future<MovieEntity> _decodeAsset(String path) => SVGAParser.shared.decodeFromAssets(path);

  @visibleForTesting
  static void forget() => _movies.clear();

  /// Puts the people, names and the picture of [item] into the movie's slots. Returns the pictures made for it: give them back to [undress] when the strip ends.
  /// A picture that cannot be fetched is replaced by a plain one (a coloured disc with the first letter, or the emoji), so the strip never waits on the network
  /// for more than [patience] and never shows a grey placeholder.
  static Future<List<ui.Image>> dress(
    MovieEntity movie,
    NoticeStripItem item, {
    NoticeImageLoader? loadImage,
    Duration patience = const Duration(seconds: 3),
  }) async {
    final load = loadImage ?? _loadFromNetwork;
    final made = <ui.Image>[];
    final d = movie.dynamicItem..reset();

    Future<ui.Image?> fetch(String? url) async {
      if (url == null || url.isEmpty) return null;
      try {
        return await load(url).timeout(patience);
      } catch (_) {
        return null;
      }
    }

    final (left, right, icon) = await (
      fetch(item.senderAvatarUrl),
      item.showReceiverAvatar ? fetch(item.receiverAvatarUrl) : Future<ui.Image?>.value(null),
      _stillOf(item.iconUrl) ? fetch(item.iconUrl) : Future<ui.Image?>.value(null),
    ).wait;

    Future<ui.Image> keep(Future<ui.Image> f) async {
      final i = await f;
      made.add(i);
      return i;
    }

    d.setImage(await keep(roundAvatar(left, item.senderName)), leftAvatar);
    if (item.showReceiverAvatar) {
      d.setImage(await keep(roundAvatar(right, item.receiverName ?? '?')), rightAvatar);
    } else {
      d.setHidden(true, rightAvatar);
    }
    d.setImage(await keep(icon == null ? emojiImage(item.iconEmoji) : fitSquare(icon)), middle);
    d.setText(nameText(item.senderName, maxWidth: leftNameWidth), leftName);
    final receiver = item.receiverName;
    if (receiver == null || receiver.trim().isEmpty) {
      d.setHidden(true, rightName);
    } else {
      d.setText(nameText(receiver, maxWidth: rightNameWidth), rightName);
    }
    final badge = item.badgeText;
    if (badge != null) {
      final p = badgePainter(badge);
      d.setDynamicDrawer((canvas, frame) => p.paint(canvas, Offset(middleSize - p.width - 2, middleSize - p.height - 2)), middle);
    }
    return made;
  }

  /// Takes the person / picture parts out of the movie again (it is shared) and frees what [dress] made.
  static void undress(MovieEntity movie, List<ui.Image> made) {
    movie.dynamicItem.reset();
    for (final i in made) {
      i.dispose();
    }
  }

  static bool _stillOf(String? url) {
    if (url == null || url.isEmpty) return false;
    final k = mediaKindFor(url);
    return k == MediaKind.image || k == MediaKind.animatedImage;
  }

  static Future<ui.Image?> _loadFromNetwork(String url) {
    final c = Completer<ui.Image?>();
    final stream = DiskCachedNetworkImage(url).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        // the stream owns its image: keep a copy of our own
        if (!c.isCompleted) c.complete(info.image.clone());
        stream.removeListener(l);
      },
      onError: (e, _) {
        if (!c.isCompleted) c.complete(null);
        stream.removeListener(l);
      },
    );
    stream.addListener(l);
    return c.future;
  }

  // ---- pictures and text made for the slots (public so tests can look at them)

  /// A round picture [px] wide: [src] cropped to a circle (cover), or a coloured disc with the first letter of [name] when there is none.
  static Future<ui.Image> roundAvatar(ui.Image? src, String name, {int px = 128}) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final size = px.toDouble();
    final circle = Rect.fromLTWH(0, 0, size, size);
    canvas.clipPath(Path()..addOval(circle));
    if (src != null) {
      final s = src.width < src.height ? src.width.toDouble() : src.height.toDouble();
      final from = Rect.fromLTWH((src.width - s) / 2, (src.height - s) / 2, s, s);
      canvas.drawImageRect(src, from, circle, Paint()..filterQuality = FilterQuality.medium..isAntiAlias = true);
    } else {
      canvas.drawRect(circle, Paint()..color = _discColor(name));
      final letter = name.trim().isEmpty ? '?' : String.fromCharCodes(name.trim().runes.take(1)).toUpperCase();
      final tp = TextPainter(
        text: TextSpan(text: letter, style: TextStyle(fontSize: size * 0.5, fontWeight: FontWeight.w800, color: Colors.white)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));
    }
    // a thin light ring, so a dark picture still reads as a circle on the strip
    canvas.drawCircle(circle.center, size / 2 - 1.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = const Color(0x66FFFFFF));
    return rec.endRecording().toImage(px, px);
  }

  static Color _discColor(String name) {
    const palette = [Color(0xFF7C3AED), Color(0xFFE11D74), Color(0xFF0EA5E9), Color(0xFF16A34A), Color(0xFFF59E0B), Color(0xFFEF4444)];
    var h = 0;
    for (final r in name.runes) {
      h = (h * 31 + r) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  /// [emoji] centred on a transparent square.
  static Future<ui.Image> emojiImage(String emoji, {int px = 128}) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final tp = TextPainter(text: TextSpan(text: emoji, style: TextStyle(fontSize: px * 0.72, height: 1)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset((px - tp.width) / 2, (px - tp.height) / 2));
    return rec.endRecording().toImage(px, px);
  }

  /// [src] scaled to fit a square, centred (a gift picture is not always square).
  static Future<ui.Image> fitSquare(ui.Image src, {int px = 128}) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final s = px / (src.width > src.height ? src.width : src.height);
    final w = src.width * s, h = src.height * s;
    canvas.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()), Rect.fromLTWH((px - w) / 2, (px - h) / 2, w, h),
        Paint()..filterQuality = FilterQuality.medium..isAntiAlias = true);
    return rec.endRecording().toImage(px, px);
  }

  /// A name as the file's text slot wants it: one line, white with a dark edge, ending in an ellipsis when it is longer than the slot.
  static TextPainter nameText(String name, {required double maxWidth}) {
    return TextPainter(
      text: TextSpan(
        text: name,
        style: const TextStyle(
          fontFamily: 'Poppins',
          fontSize: 25,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3), Shadow(color: Color(0x99000000), offset: Offset(0, 1), blurRadius: 1)],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }

  /// The small "x5" / "+1,320" drawn on the corner of the middle picture: gold with a dark outline.
  static TextPainter badgePainter(String text) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 34,
          fontWeight: FontWeight.w900,
          color: const Color(0xFFFFE066),
          shadows: [for (final o in const [Offset(-2, 0), Offset(2, 0), Offset(0, -2), Offset(0, 2)]) Shadow(color: const Color(0xFF5A1A00), offset: o)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

/// Draws the strip [controller] is playing, over the top of the room, taking no touches.
class NoticeStripLayer extends StatelessWidget {
  const NoticeStripLayer({super.key, required this.controller, this.centreBelowSafeTop = kNoticeStripCentre, this.loader});

  final NoticeStripController controller;

  /// How far below the safe area's top the MIDDLE of the strip sits (owner, 2026-11-07: "at the height of the CP seats", the same on Home and in every room). The canvas is
  /// taller than the strip and the strip is in the middle of it, so the canvas starts [canvasHeight] / 2 above this line.
  final double centreBelowSafeTop;

  @visibleForTesting
  final NoticeImageLoader? loader;

  /// The height of the animation canvas on a screen [screenWidth] wide (the canvas is drawn [kNoticeCanvasScale] times the screen's width, see [NoticeStripPlayer]).
  static double canvasHeight(double screenWidth) => screenWidth * kNoticeCanvasScale * NoticeArt.height / NoticeArt.width;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final item = controller.current;
        if (item == null) return const SizedBox.shrink();
        final id = controller.playId;
        final top = MediaQuery.paddingOf(context).top + centreBelowSafeTop - canvasHeight(MediaQuery.sizeOf(context).width) / 2;
        return IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: top < 0 ? 0 : top),
              child: NoticeStripPlayer(
                key: ValueKey(id),
                item: item,
                speed: controller.speed,
                loader: loader,
                onFinished: () => controller.finish(id),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How far below the safe area's top the middle of a notification strip sits: the height of the couple (CP) seats in an audio room (the owner's screenshot, 2026-11-07),
/// used for every strip on Home and in every room so they all appear at one height.
const double kNoticeStripCentre = 137;

/// The canvas is drawn this many times the screen's width: the strip fills about 73% of the file's width, so the see-through sides reach past the screen and the strip
/// spans nearly the whole screen, as in the reference video.
const double kNoticeCanvasScale = 1.31;

/// Plays one strip: dresses the file with [item], plays it once at [speed] and calls [onFinished] (also when the file or a picture cannot be used, so the lane never stalls).
class NoticeStripPlayer extends StatefulWidget {
  const NoticeStripPlayer({super.key, required this.item, required this.onFinished, this.speed = 1, this.loader});

  final NoticeStripItem item;
  final double speed;
  final VoidCallback onFinished;
  final NoticeImageLoader? loader;

  @override
  State<NoticeStripPlayer> createState() => _NoticeStripPlayerState();
}

class _NoticeStripPlayerState extends State<NoticeStripPlayer> with SingleTickerProviderStateMixin {
  // created in initState, not lazily: a lazy controller would first be built inside dispose() when the file never loaded
  late final SVGAAnimationController _ctl;
  MovieEntity? _movie;
  List<ui.Image> _made = const [];
  bool _ready = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctl = SVGAAnimationController(vsync: this);
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final movie = await NoticeArt.movie(kind: widget.item.kind);
      final made = await NoticeArt.dress(movie, widget.item, loadImage: widget.loader);
      if (!mounted) {
        NoticeArt.undress(movie, made);
        return;
      }
      _movie = movie;
      _made = made;
      _ctl.videoItem = movie;
      final own = _ctl.duration;
      if (own != null && own > Duration.zero && widget.speed != 1 && widget.speed > 0) {
        _ctl.duration = Duration(microseconds: (own.inMicroseconds / widget.speed).round());
      }
      setState(() => _ready = true);
      await _ctl.forward();
    } catch (_) {
      // the file or the network failed: say we are done, the next one may play
    }
    _finish();
  }

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    widget.onFinished();
  }

  @override
  void dispose() {
    _ctl.dispose();
    final movie = _movie;
    if (movie != null) NoticeArt.undress(movie, _made);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    // The canvas is wider than the screen (see kNoticeCanvasScale) and has the strip in its middle. It gets a box of its OWN height: an OverflowBox with no height of its own took
    // the whole space it was given, so the canvas sat in the middle of the room, over the seats, instead of at the top (owner's screenshot, 2026-11-07).
    final screen = MediaQuery.sizeOf(context).width;
    final w = screen * kNoticeCanvasScale;
    final h = NoticeStripLayer.canvasHeight(screen);
    return SizedBox(
      width: screen,
      height: h,
      child: OverflowBox(
        maxWidth: w,
        minWidth: w,
        maxHeight: h,
        minHeight: h,
        child: SizedBox(width: w, height: h, child: SVGAImage(_ctl, fit: BoxFit.fill)),
      ),
    );
  }
}
