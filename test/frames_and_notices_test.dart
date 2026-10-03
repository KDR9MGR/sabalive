import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/data/frames_repository.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/live_chat_bubble.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';

ProfileFrame _frame({
  String type = 'free',
  int value = 0,
  int price = 0,
  bool owned = false,
  bool equipped = false,
}) => ProfileFrame(
  id: 'f1',
  name: 'Gold Ring',
  emoji: '⭕',
  unlockType: type,
  unlockValue: value,
  priceCoins: price,
  owned: owned,
  equipped: equipped,
);

void main() {
  group('frameActionFor', () {
    test('an owned frame is worn or taken off', () {
      expect(frameActionFor(_frame(owned: true), level: 1).kind, FrameActionKind.equip);
      expect(frameActionFor(_frame(owned: true, equipped: true), level: 1).kind, FrameActionKind.remove);
    });

    test('a free frame can be claimed by anyone', () {
      final a = frameActionFor(_frame(), level: 1);
      expect(a.kind, FrameActionKind.claim);
      expect(a.enabled, isTrue);
    });

    test('a level frame is locked until the level is reached', () {
      final locked = frameActionFor(_frame(type: 'level', value: 5), level: 4);
      expect(locked.kind, FrameActionKind.locked);
      expect(locked.label, 'Level 5');
      expect(locked.enabled, isFalse);
      expect(frameActionFor(_frame(type: 'level', value: 5), level: 5).kind, FrameActionKind.claim);
    });

    test('a coin frame shows its price; one with no price is unavailable', () {
      final buy = frameActionFor(_frame(type: 'coins', price: 300), level: 1);
      expect(buy.kind, FrameActionKind.buy);
      expect(buy.label, '300 coins');
      expect(frameActionFor(_frame(type: 'coins', price: 0), level: 1).kind, FrameActionKind.locked);
    });

    test('VIP and event frames are given out by the team', () {
      expect(frameActionFor(_frame(type: 'vip'), level: 99).label, 'VIP only');
      expect(frameActionFor(_frame(type: 'event'), level: 99).label, 'Event');
      expect(frameActionFor(_frame(type: 'event'), level: 99).enabled, isFalse);
    });

    test('a frame already owned is never locked, whatever its rule', () {
      expect(frameActionFor(_frame(type: 'event', owned: true), level: 1).kind, FrameActionKind.equip);
    });
  });

  group('rows', () {
    test('a frame row keeps its artwork; a blank url means none', () {
      final f = ProfileFrame.fromRow({
        'id': 'f1', 'name': 'Ring', 'emoji': '⭕', 'unlock_type': 'coins',
        'unlock_value': 0, 'price_coins': 250, 'icon_url': 'https://x.co/r.svga',
      });
      expect(f.iconUrl, 'https://x.co/r.svga');
      expect(f.priceCoins, 250);
      expect(ProfileFrame.fromRow({'id': 'f2', 'icon_url': '  '}).iconUrl, isNull);
    });

    test('AppUser carries the equipped frame', () {
      expect(AppUser.fromRow({'id': 'u', 'frame_url': 'https://x.co/r.svga'}).frameUrl, 'https://x.co/r.svga');
      expect(AppUser.fromRow({'id': 'u', 'frame_url': ''}).frameUrl, isNull);
      expect(AppUser.fromRow({'id': 'u'}).frameUrl, isNull);
    });

    test('a gift knows its category, which drives the Event tab', () {
      final g = Gift.fromRow({'id': 'g', 'name': 'Lantern', 'emoji': '🏮', 'price_coins': 5, 'category': 'event'});
      expect(g.category, 'event');
      expect(Gift.fromRow({'id': 'g', 'name': 'x', 'emoji': 'x', 'price_coins': 1}).category, 'basic');
    });
  });

  group('AppAvatar frame', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

    testWidgets('draws the frame over the picture, larger than it, without taking taps', (t) async {
      await t.pumpWidget(host(const AppAvatar(name: 'Sam', size: 50, frameUrl: 'https://x.co/ring.svga')));
      final media = t.widget<RemoteMedia>(find.byType(RemoteMedia));
      expect(media.url, 'https://x.co/ring.svga');
      final box = t.getSize(find.descendant(of: find.byType(OverflowBox), matching: find.byType(SizedBox)).first);
      expect(box.width, closeTo(50 * AppAvatar.frameScale, 0.01));
      expect(find.ancestor(of: find.byType(RemoteMedia), matching: find.byType(IgnorePointer)), findsWidgets);
    });

    testWidgets('no frame, no extra layers', (t) async {
      await t.pumpWidget(host(const AppAvatar(name: 'Sam', size: 50)));
      expect(find.byType(RemoteMedia), findsNothing);
      expect(find.byType(OverflowBox), findsNothing);
    });

    testWidgets('keeps its own size so layouts do not shift when a frame is on', (t) async {
      await t.pumpWidget(host(const AppAvatar(name: 'Sam', size: 50, frameUrl: 'https://x.co/ring.svga')));
      expect(t.getSize(find.byType(AppAvatar)), const Size(50, 50));
    });
  });

  group('join and leave notices', () {
    final sam = AppUser(id: 'u', name: 'Sam', username: '@sam');

    test('a leave row is recognised like a join row', () {
      expect(LiveChatLine(sam, 'left the live stream', system: true).isLeave, isTrue);
      expect(LiveChatLine(sam, 'joined the live stream', system: true).isLeave, isFalse);
      expect(LiveChatLine(sam, 'left the live stream', system: true).isJoin, isFalse);
      expect(LiveChatLine(sam, 'left it', system: false).isLeave, isFalse);
    });

    testWidgets('someone leaving gets the same styled notice as someone joining', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            LiveChatLineBubble(line: LiveChatLine(sam, 'joined the live stream', system: true)),
            LiveChatLineBubble(line: LiveChatLine(sam, 'left the live stream', system: true)),
          ]),
        ),
      ));
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining('joined', findRichText: true), findsOneWidget);
      expect(find.textContaining('left', findRichText: true), findsOneWidget);
      expect(find.textContaining('Sam', findRichText: true), findsWidgets);
    });
  });

  group('RoomEffect screen coverage', () {
    test('a full-screen gift (the panel switch) is marked to cover the screen', () {
      const g = Gift('g', 'Lion', '🦁', 500, effect: true, iconUrl: 'https://x.co/l.mp4');
      expect(RoomEffect.gift(gift: g, senderName: 'Sam').fillScreen, isTrue);
      const plain = Gift('g2', 'Rose', '🌹', 10, iconUrl: 'https://x.co/r.svga');
      expect(RoomEffect.gift(gift: plain, senderName: 'Sam').fillScreen, isFalse);
    });

    testWidgets('a gift animation is laid out over the whole screen, with its caption', (t) async {
      final controller = RoomEffectController();
      await t.pumpWidget(MaterialApp(home: Scaffold(body: RoomEffectLayer(controller: controller))));
      controller.enqueue(RoomEffect.gift(
        gift: const Gift('g', 'Lion', '🦁', 500, effect: true, iconUrl: 'https://x.co/l.svga'),
        senderName: 'Sam',
      ));
      await t.pump();
      final media = find.byType(RemoteMedia);
      expect(media, findsOneWidget);
      expect(t.getSize(media), t.getSize(find.byType(Scaffold)), reason: 'covers the screen, not a box in the middle');
      expect(t.widget<RemoteMedia>(media).muted, isFalse, reason: 'MP4 effects keep their sound');
      expect(find.text('Sam sent Lion'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
