import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../data/store_repository.dart';

enum RoomEffectKind { gift, entry }

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
  });

  factory RoomEffect.gift({
    required Gift gift,
    required String senderName,
    String? senderId,
    int count = 1,
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

  String get caption => switch (kind) {
    RoomEffectKind.gift when count > 1 => '$senderName sent $name x$count',
    RoomEffectKind.gift => '$senderName sent $name',
    RoomEffectKind.entry => '$senderName entered with $name',
  };

  bool _sameAs(RoomEffect o) =>
      kind == o.kind && id == o.id && senderId == o.senderId;
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
    this.maxPlayTime = const Duration(seconds: 8),
  });

  /// More than this waiting and the oldest is dropped — a busy room would
  /// otherwise fall minutes behind.
  final int maxQueued;

  /// Hard stop for one effect, in case a file never reports that it finished.
  final Duration maxPlayTime;

  final Queue<RoomEffect> _queue = Queue();
  final Set<int> _seenRows = {};
  final Set<int> _seenEntryRows = {};
  RoomEffect? _current;
  int _playId = 0;
  Timer? _guard;
  bool _disposed = false;

  RoomEffect? get current => _current;

  /// Changes for every effect that starts, so the overlay restarts cleanly even
  /// when the same gift plays twice in a row.
  int get playId => _playId;

  void enqueue(RoomEffect effect) {
    if (_disposed) return;
    if (_queue.isNotEmpty && _queue.last._sameAs(effect)) {
      _queue.last.count += effect.count;
      return;
    }
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
      RoomEffect.gift(gift: gift, senderName: senderName, senderId: senderId),
    );
    return true;
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
    if (ids is! List || ids.isEmpty) return false;
    final senderId = row['sender_id'] as String?;
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
      items = await loadItems([for (final id in ids) id as String]);
    } catch (_) {
      return false;
    }
    if (_disposed) return false;
    for (final item in items) {
      enqueue(
        RoomEffect.entry(item: item, senderName: senderName, senderId: senderId),
      );
    }
    return items.isNotEmpty;
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
    _current = _queue.removeFirst();
    _playId++;
    final id = _playId;
    _guard?.cancel();
    _guard = Timer(maxPlayTime, () => finish(id));
    notifyListeners();
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
    required this.onFinished,
  });

  final RoomEffect effect;
  final VoidCallback onFinished;

  @override
  State<_RoomEffectView> createState() => _RoomEffectViewState();
}

class _RoomEffectViewState extends State<_RoomEffectView> {
  // The uploaded file couldn't be played; show the emoji instead so the effect
  // is still seen.
  bool _artFailed = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.effect;
    final url = e.mediaUrl;
    final art = url == null || _artFailed
        ? Center(
            child: _EmojiBurst(emoji: e.emoji, onFinished: widget.onFinished),
          )
        // The whole screen, not a box in the middle: gifts and entries are
        // meant to be seen. MP4 effects keep their sound.
        : SizedBox.expand(
            child: RemoteMedia(
              url,
              loop: false,
              muted: false,
              fit: e.fillScreen ? BoxFit.cover : BoxFit.contain,
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
  const _EmojiBurst({required this.emoji, required this.onFinished});

  final String emoji;
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
      duration: const Duration(milliseconds: 1600),
    )..forward().whenComplete(() {
        if (mounted) widget.onFinished();
      });
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
