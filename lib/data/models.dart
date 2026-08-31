import 'package:flutter/material.dart';

/// Plain data models for the SABALIVE prototype. No JSON layer yet — these are
/// hydrated from [mock_data.dart] and mutated in-memory by the controllers.

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
    this.pk = false,
  });

  final String id;
  final AppUser host;
  final String title;
  final String category;
  int viewers;
  int likes;
  int gifts;
  final List<String> tags;
  final bool pk;
}

class Gift {
  const Gift(this.name, this.emoji, this.price, {this.effect = false});
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

enum BubbleKind { text, gift, sticker }

class Bubble {
  Bubble(this.text, this.fromMe, {this.kind = BubbleKind.text, this.time = '09:41'});
  final String text;
  final bool fromMe;
  final BubbleKind kind;
  final String time;
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

enum TxType { topUp, giftSent, giftReceived, withdraw }

class WalletTx {
  WalletTx(this.type, this.title, this.amount, this.date);
  final TxType type;
  final String title;
  final int amount; // signed, in coins/diamonds
  final String date;
}

class CoinPack {
  const CoinPack(this.coins, this.price, {this.bonus = 0, this.popular = false});
  final int coins;
  final String price;
  final int bonus;
  final bool popular;
}

class AppNotification {
  AppNotification(this.icon, this.color, this.text, this.time, {this.unread = true});
  final IconData icon;
  final Color color;
  final String text;
  final String time;
  final bool unread;
}
