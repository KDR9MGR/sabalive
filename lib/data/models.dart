import 'package:flutter/material.dart';

import '../core/utils/formatters.dart';

/// Plain data models for the SABALIVE prototype. Real rows come from Supabase
/// via the `*.fromRow` factories; [mock_data.dart] still backs demo content.

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.username,
    this.bio = '',
    this.location = 'India',
    this.level = 1,
    this.followers = 0,
    this.following = 0,
    this.fans = 0,
    this.isLive = false,
    this.isHost = false,
    this.verified = false,
  });

  factory AppUser.fromRow(Map<String, dynamic> row) => AppUser(
        id: row['id'] as String,
        name: row['name'] as String? ?? 'New Star',
        username: '@${row['username'] as String? ?? 'user'}',
        bio: row['bio'] as String? ?? '',
        location: row['location'] as String? ?? 'India',
        level: row['level'] as int? ?? 1,
        followers: row['followers_count'] as int? ?? 0,
        following: row['following_count'] as int? ?? 0,
        fans: row['fans_count'] as int? ?? 0,
        isLive: row['is_live'] as bool? ?? false,
        isHost: row['is_host'] as bool? ?? false,
        verified: row['verified'] as bool? ?? false,
      );

  final String id;
  String name;
  String username;
  String bio;
  String location;
  int level;
  int followers;
  int following;
  int fans;
  bool isLive;
  bool isHost;
  bool verified;
}

class Category {
  const Category(this.label, this.icon, {this.streams = 0});
  final String label;
  final IconData icon;
  final int streams;
}

/// How a host is broadcasting.
enum LiveMode { video, audio, pk }

class LiveStream {
  LiveStream({
    required this.id,
    required this.host,
    required this.title,
    required this.category,
    required this.viewers,
    this.likes = 0,
    this.gifts = 0,
    this.tags = const [],
    this.mode = LiveMode.video,
  });

  factory LiveStream.fromRow(Map<String, dynamic> row, AppUser host) => LiveStream(
        id: row['id'] as String,
        host: host,
        title: row['title'] as String,
        category: row['category'] as String? ?? 'Chatting',
        viewers: row['viewer_count'] as int? ?? 0,
        likes: row['like_count'] as int? ?? 0,
        gifts: row['gift_coin_total'] as int? ?? 0,
        mode: LiveMode.values.byName(row['mode'] as String? ?? 'video'),
      );

  final String id;
  final AppUser host;
  final String title;
  final String category;
  int viewers;
  int likes;
  int gifts;
  final List<String> tags;
  final LiveMode mode;

  bool get pk => mode == LiveMode.pk;
}

class Gift {
  const Gift(this.id, this.name, this.emoji, this.price, {this.effect = false});

  factory Gift.fromRow(Map<String, dynamic> row) => Gift(
        row['id'] as String,
        row['name'] as String,
        row['emoji'] as String,
        row['price_coins'] as int,
        effect: row['has_effect'] as bool? ?? false,
      );

  final String id;
  final String name;
  final String emoji;
  final int price;
  final bool effect;
}

class ChatMessagePreview {
  ChatMessagePreview({
    required this.user,
    required this.lastMessage,
    required this.time,
    this.unread = 0,
    this.online = false,
    this.sentByMe = false,
  });

  final AppUser user;
  final String lastMessage;
  final String time;
  final int unread;
  final bool online;
  final bool sentByMe;
}

/// One row in the Messages inbox, hydrated from `conversation_participants`
/// + `conversations` + the latest `dm_messages` row.
class ConversationSummary {
  ConversationSummary({
    required this.conversationId,
    required this.other,
    required this.lastMessage,
    required this.lastAt,
    required this.unread,
    required this.pending,
    required this.lastFromMe,
  });

  final String conversationId;
  final AppUser other;
  final String lastMessage;
  final DateTime? lastAt;
  final bool unread;
  final bool pending;
  final bool lastFromMe;
}

enum BubbleKind { text, gift, sticker }

class Bubble {
  Bubble(this.text, this.fromMe,
      {this.kind = BubbleKind.text,
      this.time = '09:41',
      this.senderId = '',
      this.senderName = ''});

  factory Bubble.fromRow(Map<String, dynamic> row, String meId) {
    final kind = switch (row['kind'] as String? ?? 'text') {
      'gift' => BubbleKind.gift,
      'sticker' => BubbleKind.sticker,
      _ => BubbleKind.text,
    };
    final created = DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal();
    final body = (row['body'] as String?)?.trim() ?? '';
    final prof = row['profiles'];
    return Bubble(
      body.isNotEmpty ? body : (kind == BubbleKind.gift ? 'Sent a gift' : ''),
      row['sender_id'] == meId,
      kind: kind,
      time: created == null ? '' : _clock(created),
      senderId: row['sender_id'] as String? ?? '',
      senderName: prof is Map ? (prof['name'] as String? ?? '') : '',
    );
  }

  final String text;
  final bool fromMe;
  final BubbleKind kind;
  final String time;
  final String senderId;
  final String senderName;
}

class LiveChatLine {
  LiveChatLine(this.user, this.text, {this.gift = false, this.pinned = false});
  final AppUser user;
  final String text;
  final bool gift;
  final bool pinned;
}

class RankingEntry {
  RankingEntry(this.user, this.score, this.rankChange);
  final AppUser user;
  final int score;
  final int rankChange; // +up / -down / 0
}

enum TxType { topUp, giftSent, giftReceived, withdraw, grant }

class WalletTx {
  WalletTx(this.type, this.title, this.amount, this.date);

  factory WalletTx.fromLedgerRow(Map<String, dynamic> row) {
    final type = switch (row['kind'] as String) {
      'purchase' => TxType.topUp,
      'gift_sent' => TxType.giftSent,
      'gift_received' => TxType.giftReceived,
      'withdrawal' => TxType.withdraw,
      _ => TxType.grant,
    };
    final created = DateTime.tryParse(row['created_at'] as String) ?? DateTime.now();
    return WalletTx(
      type,
      row['note'] as String? ?? type.name,
      row['amount'] as int,
      '${created.day} ${_month(created.month)}, ${_time(created)}',
    );
  }

  final TxType type;
  final String title;
  final int amount; // signed, in coins/diamonds
  final String date;
}

String _month(int m) => const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ][m - 1];

String _time(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final period = d.hour < 12 ? 'AM' : 'PM';
  return '$h:${d.minute.toString().padLeft(2, '0')} $period';
}

String _clock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class CoinPack {
  const CoinPack(this.id, this.coins, this.price, {this.bonus = 0, this.popular = false});

  factory CoinPack.fromRow(Map<String, dynamic> row, {bool popular = false}) => CoinPack(
        row['id'] as String,
        row['coins'] as int,
        '₹${(row['price_inr'] as num).toStringAsFixed(0)}',
        bonus: row['bonus_coins'] as int? ?? 0,
        popular: popular,
      );

  final String id;
  final int coins;
  final String price;
  final int bonus;
  final bool popular;
}

class AppNotification {
  AppNotification(this.icon, this.color, this.text, this.time, {this.unread = true, this.id});

  factory AppNotification.fromRow(Map<String, dynamic> row) {
    final kind = row['kind'] as String? ?? 'system';
    final (icon, color) = switch (kind) {
      'follow' => (Icons.person_add_rounded, const Color(0xFF6C4CF1)),
      'gift' => (Icons.card_giftcard_rounded, const Color(0xFFF5A524)),
      'gift_received' => (Icons.card_giftcard_rounded, const Color(0xFFF5A524)),
      'like' => (Icons.favorite_rounded, const Color(0xFFF5279B)),
      'live' => (Icons.podcasts_rounded, const Color(0xFFEF4444)),
      'withdrawal' => (Icons.account_balance_wallet_rounded, const Color(0xFF22C55E)),
      'system' => (Icons.campaign_rounded, const Color(0xFF3AA0FF)),
      _ => (Icons.notifications_rounded, const Color(0xFF9AA0AE)),
    };
    final created = DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal();
    return AppNotification(
      icon,
      color,
      row['body'] as String? ?? '',
      created == null ? '' : relativeTime(created),
      unread: !(row['read'] as bool? ?? false),
      id: row['id'] as String?,
    );
  }

  final String? id;
  final IconData icon;
  final Color color;
  final String text;
  final String time;
  final bool unread;
}
