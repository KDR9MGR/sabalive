import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// One announcement for the notification strip, told to every phone: a big game win or a big gift. The server writes a row only for a win of 5,000 coins or more
/// (`game_win_notice_min_coins()`, tables `game_win_notices`) or a gift send that cost 5,000 coins or more (`gift_notice_min_coins()`, table `gift_notices`), and copies the
/// people's and the game's / gift's names and pictures into it, so a phone never needs another read.
abstract class FeedNotice {
  const FeedNotice();
  String get id;
  int get coins;
}

class GameWinNotice extends FeedNotice {
  const GameWinNotice({
    required this.id,
    required this.winnerName,
    required this.coins,
    this.winnerAvatarUrl,
    this.gameName,
    this.gameImageUrl,
  });

  factory GameWinNotice.fromRow(Map<String, dynamic> r) => GameWinNotice(
        id: (r['id'] ?? '').toString(),
        winnerName: _text(r['winner_name']) ?? 'Someone',
        winnerAvatarUrl: _text(r['winner_avatar_url']),
        gameName: _text(r['game_name']),
        gameImageUrl: _text(r['game_image_url']),
        coins: (r['coins'] as num?)?.toInt() ?? 0,
      );

  @override
  final String id;
  final String winnerName;
  final String? winnerAvatarUrl;
  final String? gameName;
  final String? gameImageUrl;
  @override
  final int coins;
}

class GiftNotice extends FeedNotice {
  const GiftNotice({
    required this.id,
    required this.senderName,
    required this.coins,
    this.senderAvatarUrl,
    this.receiverName,
    this.receiverAvatarUrl,
    this.toAll = false,
    this.giftName,
    this.giftEmoji = '🎁',
    this.giftIconUrl,
    this.quantity = 1,
  });

  factory GiftNotice.fromRow(Map<String, dynamic> r) => GiftNotice(
        id: (r['id'] ?? '').toString(),
        senderName: _text(r['sender_name']) ?? 'Someone',
        senderAvatarUrl: _text(r['sender_avatar_url']),
        receiverName: _text(r['receiver_name']),
        receiverAvatarUrl: _text(r['receiver_avatar_url']),
        toAll: r['to_all'] == true,
        giftName: _text(r['gift_name']),
        giftEmoji: _text(r['gift_emoji']) ?? '🎁',
        giftIconUrl: _text(r['gift_icon_url']),
        quantity: ((r['quantity'] as num?)?.toInt() ?? 1).clamp(1, 99),
        coins: (r['coins'] as num?)?.toInt() ?? 0,
      );

  @override
  final String id;
  final String senderName;
  final String? senderAvatarUrl;

  /// The one person who got it; null for a gift to everyone (see [toAll]).
  final String? receiverName;
  final String? receiverAvatarUrl;
  final bool toAll;
  final String? giftName;
  final String giftEmoji;
  final String? giftIconUrl;
  final int quantity;

  /// What the whole send cost: price x quantity x people.
  @override
  final int coins;
}

String? _text(Object? v) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? null : s;
}

/// The platform-wide feed of big gifts and big game wins, as one shared stream: ONE Realtime channel (two table bindings) is opened when the first listener (Home or a live room)
/// arrives and closed when the last one leaves, so a phone holds at most one. Rows are rare (5,000 coins or more), so the bindings carry no filter; each event is a small new row.
/// Everything fails open: a database without the tables, or a dropped channel, just means no strips (nothing breaks over it).
class NoticeFeed {
  NoticeFeed._();
  static final NoticeFeed instance = NoticeFeed._();

  /// A test swaps the source of rows for its own.
  static Stream<FeedNotice> Function()? debugSource;

  late final StreamController<FeedNotice> _out = StreamController<FeedNotice>.broadcast(onListen: _open, onCancel: _close);
  RealtimeChannel? _channel;
  StreamSubscription<FeedNotice>? _debugSub;

  Stream<FeedNotice> get stream => _out.stream;

  void _open() {
    if (_channel != null || _debugSub != null) return;
    try {
      final test = debugSource;
      if (test != null) {
        _debugSub = test().listen(_out.add, onError: (Object _) {});
        return;
      }
      void emit(FeedNotice Function() make) {
        try {
          final n = make();
          if (n.coins > 0 && !_out.isClosed) _out.add(n);
        } catch (_) {}
      }

      _channel = supabase
          .channel('notice-feed')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'game_win_notices',
            callback: (p) => emit(() => GameWinNotice.fromRow(p.newRecord)),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'gift_notices',
            callback: (p) => emit(() => GiftNotice.fromRow(p.newRecord)),
          )
          .subscribe();
    } catch (_) {
      _channel = null;
    }
  }

  void _close() {
    if (_out.hasListener) return;
    _debugSub?.cancel();
    _debugSub = null;
    final c = _channel;
    _channel = null;
    if (c != null) {
      try {
        unawaited(supabase.removeChannel(c));
      } catch (_) {}
    }
  }
}
