import 'package:flutter/material.dart';

import 'models.dart';

/// Static sample content for the prototype.
class Mock {
  Mock._();

  static final AppUser me = AppUser(
    id: 'me',
    name: 'StarQueen',
    username: '@starqueen',
    bio: 'Live streamer • Singer\nLove to connect and vibe together ✨',
    location: 'Mumbai, India',
    level: 28,
    followers: 382000,
    following: 12400,
    fans: 1200,
    isHost: true,
    verified: true,
  );

  static final AppUser nisha = AppUser(
    id: 'nisha',
    name: 'Nisha Live',
    username: '@nishalive',
    bio: 'Music sessions every night 🎵',
    level: 21,
    followers: 75400,
    following: 320,
    isLive: true,
    isHost: true,
    verified: true,
  );

  static final AppUser arjun = AppUser(
    id: 'arjun',
    name: 'Arjun Star',
    username: '@arjunstar',
    bio: 'Singing evenings & PK battles 🔥',
    level: 24,
    followers: 98300,
    following: 210,
    isLive: true,
    isHost: true,
  );

  static final AppUser rocky = AppUser(
    id: 'rocky',
    name: 'Rocky Mike',
    username: '@rockymike',
    level: 19,
    followers: 68200,
    following: 540,
    isLive: true,
    isHost: true,
  );

  static final AppUser sweetheart = AppUser(
    id: 'sweetheart',
    name: 'SweetHeart',
    username: '@sweetheart',
    level: 17,
    followers: 41200,
    following: 610,
    isHost: true,
  );

  static final AppUser dreamGirl = AppUser(
    id: 'dreamgirl',
    name: 'Dream Girl',
    username: '@dreamgirl',
    level: 15,
    followers: 32100,
    following: 720,
    isHost: true,
  );

  static final AppUser mrPerfect = AppUser(
    id: 'mrperfect',
    name: 'Mr. Perfect',
    username: '@mrperfect',
    level: 14,
    followers: 28900,
    following: 430,
  );

  static final AppUser lovelyAngel = AppUser(
    id: 'lovelyangel',
    name: 'Lovely Angel',
    username: '@lovelyangel',
    level: 16,
    followers: 39400,
    following: 380,
    isHost: true,
  );

  static final AppUser kingRohan = AppUser(
    id: 'kingrohan',
    name: 'King Rohan',
    username: '@kingrohan',
    level: 12,
    followers: 15100,
    following: 900,
  );

  static final List<AppUser> people = [
    nisha, arjun, rocky, sweetheart, dreamGirl, mrPerfect, lovelyAngel, kingRohan,
  ];

  static const List<Category> categories = [
    Category('Music', Icons.music_note_rounded, streams: 2342),
    Category('Dance', Icons.local_fire_department_rounded, streams: 1876),
    Category('Chatting', Icons.chat_bubble_rounded, streams: 3421),
    Category('Gaming', Icons.sports_esports_rounded, streams: 1234),
    Category('PK Battles', Icons.bolt_rounded, streams: 986),
    Category('Radio', Icons.radio_rounded, streams: 654),
    Category('Talent', Icons.star_rounded, streams: 543),
    Category('Fashion', Icons.checkroom_rounded, streams: 421),
  ];

  static final List<LiveStream> liveStreams = [
    LiveStream(
      id: 's1',
      host: nisha,
      title: "Let's vibe together 💜  Sunday music session",
      category: 'Music',
      viewers: 12500,
      likes: 2400,
      gifts: 587,
      tags: ['#music', '#live', '#trending'],
    ),
    LiveStream(
      id: 's2',
      host: arjun,
      title: 'Singing Evening 🔥 request your songs',
      category: 'Music',
      viewers: 8200,
      likes: 1800,
      gifts: 340,
      tags: ['#singing', '#requests'],
    ),
    LiveStream(
      id: 's3',
      host: rocky,
      title: 'Gaming with Fans — rank push live',
      category: 'Gaming',
      viewers: 6300,
      likes: 1500,
      gifts: 210,
      tags: ['#gaming', '#ranked'],
    ),
    LiveStream(
      id: 's4',
      host: sweetheart,
      title: 'Just chatting & chilling with you all',
      category: 'Chatting',
      viewers: 4700,
      likes: 980,
      gifts: 150,
      tags: ['#chat', '#chill'],
    ),
    LiveStream(
      id: 's5',
      host: dreamGirl,
      title: 'PK Battle vs Lovely Angel — cheer me!',
      category: 'PK Battles',
      viewers: 3200,
      likes: 760,
      gifts: 430,
      tags: ['#pk', '#battle'],
      pk: true,
    ),
    LiveStream(
      id: 's6',
      host: lovelyAngel,
      title: 'Dance performance night ✨',
      category: 'Dance',
      viewers: 2600,
      likes: 640,
      gifts: 120,
      tags: ['#dance'],
    ),
  ];

  // Gifts are now real catalog data — see WalletController.gifts, backed by
  // the `gifts` table (supabase/seed.sql).

  static List<ChatMessagePreview> conversations() => [
        ChatMessagePreview(
          user: me,
          lastMessage: 'Hey! Thanks for the gift 🎁',
          time: '09:41 AM',
          unread: 2,
          online: true,
        ),
        ChatMessagePreview(
          user: arjun,
          lastMessage: "Let's go live together 🔥",
          time: '09:30 AM',
          unread: 1,
          online: true,
        ),
        ChatMessagePreview(
          user: nisha,
          lastMessage: 'Sent you a Rose 🌹',
          time: '09:15 AM',
          online: true,
        ),
        ChatMessagePreview(
          user: rocky,
          lastMessage: 'You: See you there!',
          time: '08:50 AM',
          sentByMe: true,
        ),
        ChatMessagePreview(
          user: sweetheart,
          lastMessage: 'Alright, good night!',
          time: '12:20 AM',
        ),
        ChatMessagePreview(
          user: dreamGirl,
          lastMessage: 'You: ❤️',
          time: 'Yesterday',
          sentByMe: true,
        ),
      ];

  static List<Bubble> thread() => [
        Bubble('Hey there! 👋', false, time: '09:40'),
        Bubble('Hi StarQueen! 💜', true, time: '09:40'),
        Bubble('Thanks for supporting me in the live! 😊', false, time: '09:41'),
        Bubble('You were amazing! Keep shining ✨', true, time: '09:41'),
        Bubble('Sent a Heart', true, kind: BubbleKind.gift, time: '09:41'),
        Bubble('🥰', false, kind: BubbleKind.sticker, time: '09:42'),
      ];

  static List<LiveChatLine> liveChat() => [
        LiveChatLine(arjun, 'Wowww amazing! 🔥'),
        LiveChatLine(nisha, 'Love this song! 💜'),
        LiveChatLine(rocky, 'You rock! 🙌'),
        LiveChatLine(sweetheart, 'sent Diamond ×2', gift: true),
        LiveChatLine(dreamGirl, 'Hi from Delhi!'),
        LiveChatLine(me, 'Thank you all for the love! 💜', pinned: true),
      ];

  static List<RankingEntry> rankings() => [
        RankingEntry(me, 128600, 0),
        RankingEntry(arjun, 98300, 1),
        RankingEntry(nisha, 75400, -1),
        RankingEntry(rocky, 62100, 2),
        RankingEntry(sweetheart, 54800, 0),
        RankingEntry(dreamGirl, 41200, -2),
        RankingEntry(lovelyAngel, 38900, 1),
        RankingEntry(mrPerfect, 28400, 0),
        RankingEntry(kingRohan, 21100, 3),
      ];

  static List<WalletTx> transactions() => [
        WalletTx(TxType.giftReceived, 'Gift from Arjun Star', 590, '2 May, 09:12 PM'),
        WalletTx(TxType.giftSent, 'Diamond ×2 to Nisha Live', -200, '1 May, 08:40 PM'),
        WalletTx(TxType.topUp, 'Coin top-up', 1180, '30 Apr, 06:05 PM'),
        WalletTx(TxType.giftReceived, 'Rose ×10 from fans', 100, '29 Apr, 10:30 PM'),
        WalletTx(TxType.withdraw, 'Withdrawal to bank', -5000, '25 Apr, 02:15 PM'),
        WalletTx(TxType.giftSent, 'Crown to Rocky Mike', -200, '24 Apr, 09:00 PM'),
      ];

  // Coin packages are now real catalog data — see WalletController.coinPacks,
  // backed by the `coin_packages` table (supabase/seed.sql).

  static List<AppNotification> notifications() => [
        AppNotification(Icons.favorite_rounded, const Color(0xFFF5279B),
            'Nisha Live started a live stream', '2m'),
        AppNotification(Icons.card_giftcard_rounded, const Color(0xFFFFC93C),
            'Arjun Star sent you a Crown 👑', '18m'),
        AppNotification(Icons.person_add_rounded, const Color(0xFF9B3DF5),
            'Rocky Mike started following you', '1h'),
        AppNotification(Icons.emoji_events_rounded, const Color(0xFF32D583),
            'You reached #1 on the daily ranking!', '3h', unread: false),
        AppNotification(Icons.chat_bubble_rounded, const Color(0xFF43B0FF),
            'Dream Girl mentioned you in a comment', '5h', unread: false),
        AppNotification(Icons.workspace_premium_rounded, const Color(0xFFFFC93C),
            'You leveled up to Level 28 🎉', 'Yesterday', unread: false),
      ];

  static const List<String> interests = [
    'Music', 'Gaming', 'Dance', 'Singing', 'Travel', 'Fitness',
    'Fashion', 'Comedy', 'Food', 'Pets', 'Art', 'Tech',
  ];

  static const List<String> badges = [
    '🏆', '👑', '💎', '🔥', '⭐', '🎤', '🎁', '🚀', '🦄', '🌟',
  ];
}
