import 'package:flutter/material.dart';

import '../core/utils/formatters.dart';
import '../core/utils/ids.dart';

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
    this.wealthLevel = 1,
    this.charmLevel = 1,
    this.followers = 0,
    this.following = 0,
    this.fans = 0,
    this.isLive = false,
    this.isHost = false,
    this.verified = false,
    this.gender,
    this.dateOfBirth,
    this.avatarUrl,
    this.pkWallpaper,
    String? displayId,
  }) : displayId = displayId ?? shortDisplayId(id);

  factory AppUser.fromRow(Map<String, dynamic> row) => AppUser(
    id: row['id'] as String,
    name: row['name'] as String? ?? 'New Star',
    username: '@${row['username'] as String? ?? 'user'}',
    bio: row['bio'] as String? ?? '',
    location: row['location'] as String? ?? 'India',
    level: row['level'] as int? ?? 1,
    wealthLevel: row['wealth_level'] as int? ?? 1,
    charmLevel: row['charm_level'] as int? ?? 1,
    followers: row['followers_count'] as int? ?? 0,
    following: row['following_count'] as int? ?? 0,
    fans: row['fans_count'] as int? ?? 0,
    isLive: row['is_live'] as bool? ?? false,
    isHost: row['is_host'] as bool? ?? false,
    verified: row['verified'] as bool? ?? false,
    gender: row['gender'] as String?,
    dateOfBirth: row['date_of_birth'] != null
        ? DateTime.tryParse(row['date_of_birth'] as String)
        : null,
    avatarUrl: row['avatar_url'] as String?,
    pkWallpaper: row['pk_wallpaper'] as int?,
    displayId: row['display_id'] != null ? '${row['display_id']}' : null,
  );

  final String id;
  String name;
  String username;
  String bio;
  String location;
  int level;

  /// Wealth (coins spent) and Charm (value received) tracks — the two stars
  /// shown on profiles and next to a name when someone joins a live.
  int wealthLevel;
  int charmLevel;
  int followers;
  int following;
  int fans;
  bool isLive;
  bool isHost;
  bool verified;
  String? gender;
  DateTime? dateOfBirth;
  String? avatarUrl;

  /// Index into AppColors.tints for this user's PK Battle arena background;
  /// null means use the existing default look.
  int? pkWallpaper;

  /// The real, server-generated, stable id shown/copied/searched across the
  /// app in place of username. Falls back to the client-side hash for rows
  /// that didn't come from `profiles` (mock/demo users, ad-hoc AppUsers).
  final String displayId;
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
    this.seatCount = 5,
    this.hostAgoraUid,
  });

  factory LiveStream.fromRow(Map<String, dynamic> row, AppUser host) =>
      LiveStream(
        id: row['id'] as String,
        host: host,
        title: row['title'] as String,
        category: row['category'] as String? ?? 'Chatting',
        viewers: row['viewer_count'] as int? ?? 0,
        likes: row['like_count'] as int? ?? 0,
        gifts: row['gift_coin_total'] as int? ?? 0,
        mode: LiveMode.values.byName(row['mode'] as String? ?? 'video'),
        seatCount: row['seat_count'] as int? ?? 5,
        hostAgoraUid: row['host_agora_uid'] as int?,
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
  int seatCount;
  int? hostAgoraUid;

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
  Bubble(
    this.text,
    this.fromMe, {
    this.kind = BubbleKind.text,
    this.time = '09:41',
    this.senderId = '',
    this.senderName = '',
  });

  factory Bubble.fromRow(Map<String, dynamic> row, String meId) {
    final kind = switch (row['kind'] as String? ?? 'text') {
      'gift' => BubbleKind.gift,
      'sticker' => BubbleKind.sticker,
      _ => BubbleKind.text,
    };
    final created = DateTime.tryParse(
      row['created_at'] as String? ?? '',
    )?.toLocal();
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
  LiveChatLine(
    this.user,
    this.text, {
    this.gift = false,
    this.pinned = false,
    this.system = false,
  });
  final AppUser user;
  final String text;
  final bool gift;
  final bool pinned;

  /// Server-generated notices (`live_chat_messages.kind = 'system'`): the
  /// "joined the live stream" / "left the live stream" lines.
  final bool system;

  /// An entry notice — the one that gets the bold, shiny, level-badged look.
  bool get isJoin => system && text.startsWith('joined');
}

class RankingEntry {
  RankingEntry(this.user, this.score, this.rankChange);
  final AppUser user;
  final int score;
  final int rankChange; // +up / -down / 0
}

/// One row of the Agency leaderboard — sum of gift coins received by all of
/// an agency's hosts. Kept separate from [RankingEntry] since an agency has
/// no [AppUser]/level/profile to link into.
class AgencyRankingEntry {
  AgencyRankingEntry(this.id, this.name, this.score);
  final String id;
  final String name;
  final int score;
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
    final created =
        DateTime.tryParse(row['created_at'] as String) ?? DateTime.now();
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
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][m - 1];

String _time(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final period = d.hour < 12 ? 'AM' : 'PM';
  return '$h:${d.minute.toString().padLeft(2, '0')} $period';
}

String _clock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class CoinPack {
  const CoinPack(
    this.id,
    this.coins,
    this.price, {
    this.bonus = 0,
    this.popular = false,
  });

  factory CoinPack.fromRow(Map<String, dynamic> row, {bool popular = false}) =>
      CoinPack(
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
  AppNotification(
    this.icon,
    this.color,
    this.text,
    this.time, {
    this.unread = true,
    this.id,
  });

  factory AppNotification.fromRow(Map<String, dynamic> row) {
    final kind = row['kind'] as String? ?? 'system';
    final (icon, color) = switch (kind) {
      'follow' => (Icons.person_add_rounded, const Color(0xFF6C4CF1)),
      'gift' => (Icons.card_giftcard_rounded, const Color(0xFFF5A524)),
      'gift_received' => (Icons.card_giftcard_rounded, const Color(0xFFF5A524)),
      'like' => (Icons.favorite_rounded, const Color(0xFFF5279B)),
      'live' => (Icons.podcasts_rounded, const Color(0xFFEF4444)),
      'withdrawal' => (
        Icons.account_balance_wallet_rounded,
        const Color(0xFF22C55E),
      ),
      'system' => (Icons.campaign_rounded, const Color(0xFF3AA0FF)),
      _ => (Icons.notifications_rounded, const Color(0xFF9AA0AE)),
    };
    final created = DateTime.tryParse(
      row['created_at'] as String? ?? '',
    )?.toLocal();
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

enum FeedbackKind { appError, suggestion, earningInfo, other }

enum FeedbackStatus { pending, inProgress, resolved }

class FeedbackItem {
  FeedbackItem({
    required this.id,
    required this.kind,
    required this.body,
    required this.status,
    required this.createdAt,
    this.response,
    this.respondedAt,
  });

  factory FeedbackItem.fromRow(Map<String, dynamic> row) => FeedbackItem(
    id: row['id'] as String,
    kind: switch (row['kind'] as String) {
      'app_error' => FeedbackKind.appError,
      'suggestion' => FeedbackKind.suggestion,
      'earning_info' => FeedbackKind.earningInfo,
      _ => FeedbackKind.other,
    },
    body: row['body'] as String,
    status: switch (row['status'] as String) {
      'in_progress' => FeedbackStatus.inProgress,
      'resolved' => FeedbackStatus.resolved,
      _ => FeedbackStatus.pending,
    },
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
    response: row['response'] as String?,
    respondedAt: row['responded_at'] == null
        ? null
        : DateTime.parse(row['responded_at'] as String).toLocal(),
  );

  final String id;
  final FeedbackKind kind;
  final String body;
  final FeedbackStatus status;
  final DateTime createdAt;
  final String? response;
  final DateTime? respondedAt;
}

/// A directory entry in the offline coin-seller list — purely a contact
/// card. Buying/selling itself happens outside the app (WhatsApp, cash/UPI).
class OfflineSeller {
  OfflineSeller({
    required this.id,
    required this.name,
    required this.whatsappNumber,
    this.note,
  });

  factory OfflineSeller.fromRow(Map<String, dynamic> row) => OfflineSeller(
    id: row['id'] as String,
    name: row['name'] as String,
    whatsappNumber: row['whatsapp_number'] as String,
    note: row['note'] as String?,
  );

  final String id;
  final String name;
  final String whatsappNumber;
  final String? note;
}
