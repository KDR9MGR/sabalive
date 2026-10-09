import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart' hide Text;

import '../../../core/media/effect_file_cache.dart';
import '../../../core/media/effect_sound.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../data/store_repository.dart';
import '../../../core/i18n/text.dart';

enum RoomEffectKind { gift, entry }

/// Effects play at this fraction of the file's own speed unless the panel set one for the gift or
/// entry (Gifts / Store -> "Play speed"). A little slower than the file is easier to see and reads
/// as smoother on a phone.
const double kDefaultEffectSpeed = 0.75;

/// One full-screen effect to play in a room: a gift somebody sent, or the entry
/// effect / vehicle somebody walked in with. A 5x gift, or one gift to everyone,
/// arrives as a single combo rather than five long animations.
class RoomEffect {
  RoomEffect._({
    required this.kind,
    required this.id,
    required this.name,
    required this.emoji,
    required this.senderName,
    this.mediaUrl,
    this.senderId,
    this.count = 1,
    this.fillScreen = false,
    this.level = false,
    this.toAll = false,
    this.speed,
    this.soundUrl,
  });

  factory RoomEffect.gift({
    required Gift gift,
    required String senderName,
    String? senderId,
    int count = 1,
    bool toAll = false,
  }) => RoomEffect._(
    kind: RoomEffectKind.gift,
    id: gift.id,
    name: gift.name,
    emoji: gift.emoji,
    mediaUrl: gift.iconUrl,
    senderName: senderName,
    senderId: senderId,
    count: count,
    fillScreen: gift.effect,
    toAll: toAll,
    speed: gift.playSpeed,
    soundUrl: gift.soundUrl,
  );

  factory RoomEffect.entry({
    required StoreItem item,
    required String senderName,
    String? senderId,
  }) => RoomEffect._(
    kind: RoomEffectKind.entry,
    id: item.id,
    name: item.name,
    emoji: item.emoji,
    mediaUrl: item.assetUrl,
    senderName: senderName,
    senderId: senderId,
    speed: item.playSpeed,
    soundUrl: item.soundUrl,
  );

  /// The level image a user earned (Wealth / Charm level, set in the panel),
  /// played full-screen when they join.
  factory RoomEffect.level({
    required String url,
    required String senderName,
    String? senderId,
  }) => RoomEffect._(
    kind: RoomEffectKind.entry,
    id: 'level:$url',
    name: 'level',
    emoji: '⭐',
    mediaUrl: url,
    senderName: senderName,
    senderId: senderId,
    fillScreen: true,
    level: true,
  );

  final RoomEffectKind kind;
  final String id;
  final String name;
  final String emoji;
  final String? mediaUrl;
  final String senderName;
  final String? senderId;
  int count;

  /// The gift is a full-screen effect (the panel's "Full-screen animation"
  /// switch): its artwork covers the whole screen. Other artwork is shown whole,
  /// as large as fits the screen.
  final bool fillScreen;

  /// A level-image arrival rather than an entry effect / vehicle.
  final bool level;

  /// The gift went to everyone in the room ("Send to All"), not one person.
  final bool toAll;

  /// The panel's play speed for this item (1 = the file's own); null = [kDefaultEffectSpeed].
  final double? speed;

  /// A sound the panel attached; every device plays it together with the effect.
  final String? soundUrl;

  String get caption => switch (kind) {
    RoomEffectKind.gift when toAll && count > 1 => '$senderName sent $name x$count to All',
    RoomEffectKind.gift when toAll => '$senderName sent $name to All',
    RoomEffectKind.gift when count > 1 => '$senderName sent $name x$count',
    RoomEffectKind.gift => '$senderName sent $name',
    RoomEffectKind.entry when level => '$senderName joined',
    RoomEffectKind.entry => '$senderName entered with $name',
  };

  bool _sameAs(RoomEffect o) =>
      kind == o.kind && id == o.id && senderId == o.senderId && toAll == o.toAll;
}

/// Plays room effects one at a time for everyone in a room — sender, host and
/// every viewer — so a gift or an entry is seen on screen, not only as a chat
/// line.
///
/// A room screen feeds it two ways: [enqueue] for a gift this device just sent,
/// and [handleRow] for the live chat rows that arrive over Realtime: a
/// `kind = 'gift'` row when somebody sends a gift (rows from this device's own
/// user are ignored, because [enqueue] already played them), and a join row
/// carrying `entry_item_ids` when somebody walks in with an entry effect.
class RoomEffectController extends ChangeNotifier {
  RoomEffectController({
    this.maxQueued = 6,
    this.maxPlayTime = const Duration(seconds: 15),
    this.margin = const Duration(seconds: 3),
    this.longestEffect = const Duration(seconds: 60),
    this.catchUpAt = 3,
    this.retryDelay = const Duration(milliseconds: 1200),
    void Function(String url)? prefetch,
  }) : _prefetch = prefetch ?? _defaultPrefetch;

  /// More than this waiting and the oldest is dropped — a busy room would
  /// otherwise fall minutes behind.
  final int maxQueued;

  /// How long a file gets to load and report that it started, before the effect is given up on
  /// (it used to be a flat 8 s for the whole effect, which also cut slowed effects short). Once the
  /// file says how long it runs, the guard becomes that length plus [margin] (see [reportDuration]).
  final Duration maxPlayTime;

  /// Slack after the expected length, for a player that reports its end a moment late.
  final Duration margin;

  /// No single effect is given longer than this, whatever its file claims.
  final Duration longestEffect;

  /// With this many effects already waiting, the next one plays at the file's own speed or faster
  /// instead of slowed, so a busy room catches up rather than falling minutes behind.
  final int catchUpAt;

  /// Pause before the one retry of an item lookup that failed.
  final Duration retryDelay;

  final void Function(String url) _prefetch;

  static void _defaultPrefetch(String url) {
    final kind = mediaKindFor(url);
    if (kind == MediaKind.video || _isSound(url)) EffectFileCache.instance.prefetch(url);
  }

  static bool _isSound(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return const ['.mp3', '.m4a', '.aac', '.wav', '.ogg'].any(path.endsWith);
  }

  final Queue<RoomEffect> _queue = Queue();
  final Set<int> _seenRows = {};
  final Set<int> _seenEntryRows = {};
  RoomEffect? _current;
  double _currentSpeed = kDefaultEffectSpeed;
  int _playId = 0;
  Timer? _guard;
  bool _disposed = false;
  bool _ownEntryPlayed = false;

  RoomEffect? get current => _current;

  /// The speed the effect that is playing now runs at (see [catchUpAt]).
  double get currentSpeed => _currentSpeed;

  /// Changes for every effect that starts, so the overlay restarts cleanly even
  /// when the same gift plays twice in a row.
  int get playId => _playId;

  void enqueue(RoomEffect effect) {
    if (_disposed) return;
    if (_queue.isNotEmpty && _queue.last._sameAs(effect)) {
      _queue.last.count += effect.count;
      return;
    }
    // start fetching the files now: by the time its turn comes (a gift behind another) they are stored
    final media = effect.mediaUrl;
    if (media != null) _prefetch(media);
    final sound = effect.soundUrl;
    if (sound != null) _prefetch(sound);
    _queue.add(effect);
    while (_queue.length > maxQueued) {
      _queue.removeFirst();
    }
    _startNext();
  }

  /// Handles one live_chat_messages Realtime row. Returns whether it started or
  /// queued an effect.
  bool onChatRow(
    Map<String, dynamic> row, {
    required String? meId,
    required String senderName,
    required Gift? Function(String giftId) giftById,
  }) {
    if (row['kind'] != 'gift') return false;
    final giftId = row['gift_id'];
    if (giftId is! String) return false;
    final senderId = row['sender_id'] as String?;
    if (senderId != null && senderId == meId) return false;
    final rowId = row['id'];
    if (rowId is int && !_seenRows.add(rowId)) return false;
    final gift = giftById(giftId);
    if (gift == null) return false;
    enqueue(
      RoomEffect.gift(
        gift: gift,
        senderName: senderName,
        senderId: senderId,
        toAll: row['to_all'] == true,
      ),
    );
    return true;
  }

  /// Plays this user's own entry effect / vehicle at once, from what they have equipped, without waiting
  /// for their join row to come back over Realtime (it can arrive before the room is listening, and
  /// Realtime never replays). The join row for the same entry is then ignored for the items.
  void playOwnEntry(List<StoreItem> items, {String senderName = 'You', String? senderId}) {
    if (_disposed || items.isEmpty) return;
    _ownEntryPlayed = true;
    for (final item in items) {
      enqueue(RoomEffect.entry(item: item, senderName: senderName, senderId: senderId));
    }
  }

  Future<List<StoreItem>> _loadWithRetry(
    Future<List<StoreItem>> Function(List<String> ids) loadItems,
    List<String> ids,
  ) async {
    try {
      return await loadItems(ids);
    } catch (_) {
      // a blip (the network was just coming up): one more try before the entry is missed
      await Future<void>.delayed(retryDelay);
      return await loadItems(ids);
    }
  }

  /// Handles a join row that carries `entry_item_ids`: plays the joiner's
  /// vehicle / entry effect for the room. Unlike gifts, a user's own entry is
  /// played too (there's no local play to duplicate).
  ///
  /// [history] marks rows read from the chat backlog rather than received live:
  /// only the user's own, very recent entry is played then, so opening a room
  /// doesn't replay everyone's earlier arrivals — but the user's own entry still
  /// shows if its row landed before the screen began listening.
  Future<bool> onEntryRow(
    Map<String, dynamic> row, {
    required String? meId,
    required String senderName,
    required Future<List<StoreItem>> Function(List<String> ids) loadItems,
    bool history = false,
    DateTime? now,
  }) async {
    if (row['kind'] != 'system') return false;
    final ids = row['entry_item_ids'];
    final senderId = row['sender_id'] as String?;
    // my own vehicle / entry effect was already played from what I have equipped (playOwnEntry)
    final alreadyPlayed = _ownEntryPlayed && senderId != null && senderId == meId;
    final hasItems = ids is List && ids.isNotEmpty && !alreadyPlayed;
    final levelImage = (row['level_image_url'] as String?)?.trim();
    final hasLevel = levelImage != null && levelImage.isNotEmpty;
    if (!hasItems && !hasLevel) return false;
    if (history) {
      if (senderId == null || senderId != meId) return false;
      final at = DateTime.tryParse('${row['created_at']}');
      final clock = now ?? DateTime.now();
      if (at == null || clock.difference(at).abs() > const Duration(seconds: 20)) {
        return false;
      }
    }
    final rowId = row['id'];
    if (rowId is int && !_seenEntryRows.add(rowId)) return false;
    final List<StoreItem> items;
    try {
      items = hasItems
          ? await _loadWithRetry(loadItems, [for (final id in ids) id as String])
          : const <StoreItem>[];
    } catch (_) {
      return false;
    }
    if (_disposed) return false;
    // the level image first, then the vehicle / entry effect
    if (hasLevel) {
      enqueue(
        RoomEffect.level(url: levelImage, senderName: senderName, senderId: senderId),
      );
    }
    for (final item in items) {
      enqueue(
        RoomEffect.entry(item: item, senderName: senderName, senderId: senderId),
      );
    }
    return items.isNotEmpty || hasLevel;
  }

  /// Both kinds of row, for a screen's chat subscription: a gift row starts a
  /// gift effect, a join row with entry items starts an entry effect.
  Future<void> handleRow(
    Map<String, dynamic> row, {
    required String? meId,
    required String senderName,
    required Gift? Function(String giftId) giftById,
    required Future<List<StoreItem>> Function(List<String> ids) loadItems,
    bool history = false,
  }) async {
    if (!history) {
      onChatRow(row, meId: meId, senderName: senderName, giftById: giftById);
    }
    await onEntryRow(
      row,
      meId: meId,
      senderName: senderName,
      loadItems: loadItems,
      history: history,
    );
  }

  /// The overlay calls this when the current effect has ended (or failed).
  /// [id] is the [playId] it was started with, so a late callback from a
  /// previous effect can't cut the next one short.
  void finish(int id) {
    if (_disposed || id != _playId || _current == null) return;
    _guard?.cancel();
    _current = null;
    _startNext();
    notifyListeners();
  }

  void _startNext() {
    if (_current != null || _queue.isEmpty) return;
    final next = _queue.removeFirst();
    _current = next;
    final base = next.speed ?? kDefaultEffectSpeed;
    _currentSpeed = _queue.length >= catchUpAt && base < 1 ? 1.0 : base;
    _playId++;
    final id = _playId;
    _guard?.cancel();
    _guard = Timer(maxPlayTime, () => finish(id));
    notifyListeners();
  }

  /// The overlay calls this once its file has started playing and knows how long this pass will take at
  /// the chosen speed. The effect then gets that long plus [margin] to report that it finished, instead of a
  /// fixed few seconds that also had to cover the download.
  void reportDuration(int id, Duration? expected) {
    if (_disposed || id != _playId || _current == null || expected == null) return;
    final capped = expected > longestEffect ? longestEffect : expected;
    _guard?.cancel();
    _guard = Timer(capped + margin, () => finish(id));
  }

  @override
  void dispose() {
    _disposed = true;
    _guard?.cancel();
    super.dispose();
  }
}

/// Draws whatever [controller] is currently playing, centred over the room and
/// ignoring touches so the stream stays usable underneath.
class RoomEffectLayer extends StatelessWidget {
  const RoomEffectLayer({super.key, required this.controller});

  final RoomEffectController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final effect = controller.current;
        if (effect == null) return const SizedBox.shrink();
        final id = controller.playId;
        return IgnorePointer(
          child: _RoomEffectView(
            key: ValueKey(id),
            effect: effect,
            speed: controller.currentSpeed,
            onPlaying: (expected) => controller.reportDuration(id, expected),
            onFinished: () => controller.finish(id),
          ),
        );
      },
    );
  }
}

class _RoomEffectView extends StatefulWidget {
  const _RoomEffectView({
    super.key,
    required this.effect,
    required this.speed,
    required this.onPlaying,
    required this.onFinished,
  });

  final RoomEffect effect;
  final double speed;
  final void Function(Duration? expected) onPlaying;
  final VoidCallback onFinished;

  @override
  State<_RoomEffectView> createState() => _RoomEffectViewState();
}

class _RoomEffectViewState extends State<_RoomEffectView> {
  // The uploaded file couldn't be played; show the emoji instead so the effect
  // is still seen.
  bool _artFailed = false;

  // the sound the panel attached, started together with the picture and stopped with it
  EffectSound? _sound;

  void _startSound() {
    final url = widget.effect.soundUrl;
    if (_sound != null || url == null) return;
    _sound = EffectSounds.start(url);
  }

  // A still picture (PNG / JPG) never reports that it ended, so it is shown for a set time.
  Timer? _stillTimer;

  /// How long a still picture stays up at the file's own speed; slowed with the effect, so the
  /// default 0.75x is the 8 s it has always been.
  static const stillDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    final url = widget.effect.mediaUrl;
    if (url == null) {
      // no picture to wait for: the sound goes with the emoji straight away
      _startSound();
    } else if (mediaKindFor(url) == MediaKind.image) {
      _startSound();
      _stillTimer = Timer(
        Duration(milliseconds: (stillDuration.inMilliseconds / (widget.speed > 0 ? widget.speed : 1)).round()),
        () {
          if (mounted && !_artFailed) widget.onFinished();
        },
      );
    }
  }

  @override
  void dispose() {
    _stillTimer?.cancel();
    unawaited(_sound?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.effect;
    final url = e.mediaUrl;
    final art = url == null || _artFailed
        ? Center(
            child: _EmojiBurst(
              emoji: e.emoji,
              speed: widget.speed,
              onStarted: _startSound,
              onFinished: widget.onFinished,
            ),
          )
        // The whole screen, not a box in the middle: gifts and entries are
        // meant to be seen. MP4 effects keep their sound.
        : SizedBox.expand(
            child: RemoteMedia(
              url,
              loop: false,
              muted: false,
              speed: widget.speed,
              // a separate sound from the panel replaces the video's own soundtrack
              silenceEmbeddedAudio: e.soundUrl != null,
              fit: e.fillScreen ? BoxFit.cover : BoxFit.contain,
              onPlaying: (expected) {
                _startSound();
                widget.onPlaying(expected);
              },
              onError: () {
                if (mounted) setState(() => _artFailed = true);
              },
              onFinished: () {
                if (!_artFailed) widget.onFinished();
              },
            ),
          );
    final label = e.caption;
    return Stack(
      fit: StackFit.expand,
      children: [
        art,
        Positioned(
          left: 24,
          right: 24,
          bottom: 150,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The plain-emoji gift effect: grows and fades, as the sender's own burst
/// always did.
class _EmojiBurst extends StatefulWidget {
  const _EmojiBurst({
    required this.emoji,
    required this.speed,
    required this.onStarted,
    required this.onFinished,
  });

  final String emoji;
  final double speed;
  final VoidCallback onStarted;
  final VoidCallback onFinished;

  @override
  State<_EmojiBurst> createState() => _EmojiBurstState();
}

class _EmojiBurstState extends State<_EmojiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (1600 / (widget.speed > 0 ? widget.speed : 1)).round()),
    )..forward().whenComplete(() {
        if (mounted) widget.onFinished();
      });
    widget.onStarted();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final v = Curves.easeOut.transform(_ctl.value);
        return Opacity(
          opacity: (1 - v).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.6 + v * 1.8,
            child: Text(widget.emoji, style: const TextStyle(fontSize: 90)),
          ),
        );
      },
    );
  }
}
