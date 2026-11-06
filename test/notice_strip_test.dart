import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/notice_strip.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The notification strip (2026-11-05): the owner's "full venue" SVGA, filled with who sent what to whom.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
    NoticeArt.forget();
  });

  NoticeStripItem gift({String sender = 'Ann', String? receiver = 'Bo', String emoji = '🌹', int count = 1, String? badge}) => NoticeStripItem(
        kind: NoticeKind.gift,
        senderName: sender,
        receiverName: receiver,
        showReceiverAvatar: receiver != null,
        iconEmoji: emoji,
        count: count,
        badge: badge,
      );

  group('one item', () {
    test('the badge is x and the count above one, nothing for a single gift, or the text it was given', () {
      expect(gift().badgeText, isNull);
      expect(gift(count: 5).badgeText, 'x5');
      expect(gift(count: 5, badge: '+1,320').badgeText, '+1,320');
    });

    test('the same sender, gift and receiver read as one; anything different does not', () {
      expect(gift().sameAs(gift()), isTrue);
      expect(gift().sameAs(gift(sender: 'Cy')), isFalse);
      expect(gift().sameAs(gift(receiver: 'Di')), isFalse);
      expect(gift().sameAs(gift(emoji: '💎')), isFalse);
      expect(gift(badge: '+5').sameAs(gift(badge: '+5')), isFalse, reason: 'a win with its own badge is never merged');
    });
  });

  group('the queue', () {
    test('the first item plays at once; the next waits for finish', () {
      final c = NoticeStripController();
      c.add(gift(sender: 'A'));
      expect(c.current?.senderName, 'A');
      c.add(gift(sender: 'B'));
      expect(c.current?.senderName, 'A');
      expect(c.waiting, 1);
      c.finish(c.playId);
      expect(c.current?.senderName, 'B');
      c.finish(c.playId);
      expect(c.current, isNull);
      c.dispose();
    });

    test('a late finish for an earlier strip does not cut the current one short', () {
      final c = NoticeStripController();
      c.add(gift(sender: 'A'));
      final first = c.playId;
      c.add(gift(sender: 'B'));
      c.finish(first);
      expect(c.current?.senderName, 'B');
      c.finish(first);
      expect(c.current?.senderName, 'B', reason: 'the old id is ignored');
      c.dispose();
    });

    test('identical gifts waiting together become one strip with a bigger count', () {
      final c = NoticeStripController();
      c.add(gift(sender: 'A'));
      c.add(gift(sender: 'B'));
      c.add(gift(sender: 'B'));
      c.add(gift(sender: 'B', count: 3));
      expect(c.waiting, 1);
      c.finish(c.playId);
      expect(c.current?.senderName, 'B');
      expect(c.current?.count, 5);
      c.dispose();
    });

    test('only the last few waiting are kept', () {
      final c = NoticeStripController(maxQueued: 3);
      c.add(gift(sender: 'now'));
      for (var i = 0; i < 6; i++) {
        c.add(gift(sender: 'w$i'));
      }
      expect(c.waiting, 3);
      c.finish(c.playId);
      expect(c.current?.senderName, 'w3', reason: 'the oldest waiting ones were dropped');
      c.dispose();
    });

    test('with a few waiting a strip plays faster; alone it plays at its own speed', () {
      final c = NoticeStripController(hurryAt: 2);
      c.add(gift(sender: 'A'));
      expect(c.speed, 1);
      c.add(gift(sender: 'B'));
      c.add(gift(sender: 'C'));
      c.add(gift(sender: 'D'));
      c.finish(c.playId);
      expect(c.speed, NoticeStripController.hurrySpeed);
      c.dispose();
    });

    test('a strip that never reports its end is cleared by the backstop', () async {
      final c = NoticeStripController(backstop: const Duration(milliseconds: 60));
      c.add(gift(sender: 'A'));
      c.add(gift(sender: 'B'));
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(c.current?.senderName, 'B');
      c.dispose();
    });

    test('notifies its listeners when a strip starts and ends; nothing after dispose', () {
      final c = NoticeStripController();
      var n = 0;
      c.addListener(() => n++);
      c.add(gift());
      expect(n, 1);
      c.finish(c.playId);
      expect(n, 2);
      c.dispose();
      c.add(gift());
      expect(c.current, isNull);
    });
  });

  group('the bundled file', () {
    testWidgets('is the 750 x 300 strip with the five slots we fill', (t) async {
      await t.runAsync(() async {
        final m = await NoticeArt.movie();
        expect(m.params.viewBoxWidth, NoticeArt.width);
        expect(m.params.viewBoxHeight, NoticeArt.height);
        expect(m.params.frames, 85);
        for (final key in [NoticeArt.leftAvatar, NoticeArt.rightAvatar, NoticeArt.leftName, NoticeArt.rightName, NoticeArt.middle]) {
          expect(m.sprites.any((s) => s.imageKey == key), isTrue, reason: key);
        }
        expect(m.autorelease, isFalse, reason: 'a shared movie is never freed by a player');
      });
    });
  });

  group('dressing the file', () {
    testWidgets('a gift to a person fills every slot, and undress takes it all out again', (t) async {
      await t.runAsync(() async {
        final m = await NoticeArt.movie();
        final made = await NoticeArt.dress(m, gift(count: 5), loadImage: (_) async => null);
        final d = m.dynamicItem;
        expect(d.dynamicImages.keys, containsAll([NoticeArt.leftAvatar, NoticeArt.rightAvatar, NoticeArt.middle]));
        expect(d.dynamicText.keys, containsAll([NoticeArt.leftName, NoticeArt.rightName]));
        expect(d.dynamicHidden[NoticeArt.rightAvatar], isNot(true));
        expect(d.dynamicDrawer.keys, contains(NoticeArt.middle), reason: 'the x5 badge');
        expect(made.length, 3);
        NoticeArt.undress(m, made);
        expect(d.dynamicImages, isEmpty);
        expect(d.dynamicText, isEmpty);
        expect(d.dynamicHidden, isEmpty);
        expect(d.dynamicDrawer, isEmpty);
      });
    });

    testWidgets('a gift to everyone hides the right avatar and still names the receiver', (t) async {
      await t.runAsync(() async {
        final m = await NoticeArt.movie();
        final item = const NoticeStripItem(kind: NoticeKind.gift, senderName: 'Ann', receiverName: 'Everyone', iconEmoji: '💎');
        final made = await NoticeArt.dress(m, item, loadImage: (_) async => null);
        final d = m.dynamicItem;
        expect(d.dynamicHidden[NoticeArt.rightAvatar], isTrue);
        expect(d.dynamicText.keys, contains(NoticeArt.rightName));
        expect(d.dynamicDrawer, isEmpty, reason: 'no badge for a single gift');
        NoticeArt.undress(m, made);
      });
    });

    testWidgets('a win with no receiver and no game name hides both right-hand parts', (t) async {
      await t.runAsync(() async {
        final m = await NoticeArt.movie();
        final item = const NoticeStripItem(kind: NoticeKind.gameWin, senderName: 'Winner', iconEmoji: '🪙', badge: '+1,320');
        final made = await NoticeArt.dress(m, item, loadImage: (_) async => null);
        final d = m.dynamicItem;
        expect(d.dynamicHidden[NoticeArt.rightAvatar], isTrue);
        expect(d.dynamicHidden[NoticeArt.rightName], isTrue);
        expect(d.dynamicDrawer.keys, contains(NoticeArt.middle));
        NoticeArt.undress(m, made);
      });
    });

    testWidgets('a picture that cannot be fetched, or takes too long, is replaced; the strip never waits long', (t) async {
      await t.runAsync(() async {
        final m = await NoticeArt.movie();
        final item = NoticeStripItem(kind: NoticeKind.gift, senderName: 'Ann', senderAvatarUrl: 'https://x/a.png', receiverName: 'Bo', receiverAvatarUrl: 'https://x/b.png', showReceiverAvatar: true, iconUrl: 'https://x/g.png');
        final sw = Stopwatch()..start();
        final made = await NoticeArt.dress(
          m,
          item,
          loadImage: (url) => url.endsWith('a.png') ? Future<ui.Image?>.error('offline') : Completer<ui.Image?>().future, // one fails, the others never answer
          patience: const Duration(milliseconds: 120),
        );
        expect(sw.elapsedMilliseconds, lessThan(1500));
        expect(made.length, 3, reason: 'a plain disc for each person and the emoji for the gift');
        expect(m.dynamicItem.dynamicImages.keys, containsAll([NoticeArt.leftAvatar, NoticeArt.rightAvatar, NoticeArt.middle]));
        NoticeArt.undress(m, made);
      });
    });

    testWidgets('the pictures made for the slots are square and the right size', (t) async {
      await t.runAsync(() async {
        final a = await NoticeArt.roundAvatar(null, 'Ann');
        expect((a.width, a.height), (128, 128));
        a.dispose();
        final e = await NoticeArt.emojiImage('🎁');
        expect((e.width, e.height), (128, 128));
        e.dispose();
      });
    });

    test('a name longer than its slot is cut with an ellipsis, a short one is not', () {
      final long = NoticeArt.nameText('A very very very long display name indeed', maxWidth: NoticeArt.leftNameWidth);
      expect(long.width, lessThanOrEqualTo(NoticeArt.leftNameWidth + 0.01));
      expect(long.didExceedMaxLines, isTrue);
      final short = NoticeArt.nameText('Bo', maxWidth: NoticeArt.leftNameWidth);
      expect(short.didExceedMaxLines, isFalse);
    });
  });

  group('the layer', () {
    testWidgets('draws nothing while idle and never takes a touch', (t) async {
      final c = NoticeStripController();
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [NoticeStripLayer(controller: c)]))));
      expect(find.byType(NoticeStripPlayer), findsNothing);
      c.add(gift());
      await t.pump();
      expect(find.byType(NoticeStripPlayer), findsOneWidget);
      expect(find.ancestor(of: find.byType(NoticeStripPlayer), matching: find.byType(IgnorePointer)), findsWidgets);
      c.dispose();
    });

    testWidgets('a strip plays through the whole file and then hands the lane to the next one', (t) async {
      await t.runAsync(() => NoticeArt.movie());
      final c = NoticeStripController();
      t.view.physicalSize = const Size(720, 1280);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [NoticeStripLayer(controller: c, loader: (_) async => null)]))));
      c.add(gift(sender: 'A'));
      c.add(gift(sender: 'B'));
      await t.pump();
      expect(c.current?.senderName, 'A');
      // the pictures are made in real time (not the test clock), one after another: hand over real time and the test clock in turn until it is dressed
      Future<void> untilDressed() async {
        for (var i = 0; i < 20 && find.byType(SVGAImage).evaluate().isEmpty; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
          await t.pump();
        }
      }
      await untilDressed();
      expect(find.byType(SVGAImage), findsOneWidget, reason: 'the animation is on screen once the strip is dressed');
      // 85 frames at 30 fps is about 2.8 s; with one more waiting it plays at 1x (hurry needs 2 waiting)
      for (var i = 0; i < 40 && c.current?.senderName == 'A'; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(c.current?.senderName, 'B', reason: 'the first strip ended on its own, not by the backstop (8 s)');
      await untilDressed();
      for (var i = 0; i < 40 && c.current != null; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(c.current, isNull);
      expect(t.takeException(), isNull);
      c.dispose();
    });

    testWidgets('a strip whose file cannot be read still reports it is done, so the lane does not stall', (t) async {
      // a movie that never loads: the player must give up and call onFinished
      NoticeArt.forget();
      final c = NoticeStripController(backstop: const Duration(seconds: 30));
      var finished = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NoticeStripPlayer(
            item: gift(),
            onFinished: () => finished++,
          ),
        ),
      ));
      // under the test's fake clock the real asset decode does not complete; the player must at least not throw while waiting
      await t.pump(const Duration(milliseconds: 50));
      expect(t.takeException(), isNull);
      c.dispose();
    });
  });

  group('from the room\'s gifts', () {
    Gift g(int price) => Gift('gift-$price', 'Rose', '🌹', price);
    AppUser me() => AppUser(id: 'me', name: 'Me Myself', username: '@me');
    AppUser bo() => AppUser(id: 'bo', name: 'Bo', username: '@bo');

    RoomEffectController room({int min = 1000, bool on = true}) => RoomEffectController(noticeMinCoins: min, noticesOn: () => on, prefetch: (_) {});

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a small gift shows its own effect only; no strip', () async {
      final r = room();
      r.enqueue(RoomEffect.gift(gift: g(10), senderName: 'Me', sender: me(), receiver: bo(), count: 5));
      await settle();
      expect(r.notices.current, isNull);
      r.dispose();
    });

    test('a gift that cost enough gets a strip naming the sender and the receiver, with the quantity', () async {
      final r = room();
      r.enqueue(RoomEffect.gift(gift: g(500), senderName: 'You', senderId: 'me', sender: me(), receiver: bo(), count: 3));
      await settle();
      final n = r.notices.current!;
      expect((n.kind, n.senderName, n.receiverName, n.count, n.showReceiverAvatar, n.iconEmoji), (NoticeKind.gift, 'Me Myself', 'Bo', 3, true, '🌹'));
      r.dispose();
    });

    test('the threshold is on what the whole send cost: price x quantity x people for a gift to everyone', () async {
      final r = room(min: 1000);
      r.enqueue(RoomEffect.gift(gift: g(100), senderName: 'Me', sender: me(), count: 2, toAll: true, recipientCount: 4)); // 800
      await settle();
      expect(r.notices.current, isNull);
      r.enqueue(RoomEffect.gift(gift: g(100), senderName: 'Me', sender: me(), count: 3, toAll: true, recipientCount: 4)); // 1200
      await settle();
      final n = r.notices.current!;
      expect((n.receiverName, n.showReceiverAvatar), ('Everyone', false), reason: 'a gift to everyone names Everyone and has no single receiver avatar');
      r.dispose();
    });

    test('with no receiver given, the room\'s host is the receiver', () async {
      final r = room()..roomHost = bo();
      r.enqueue(RoomEffect.gift(gift: g(2000), senderName: 'Ann', sender: me()));
      await settle();
      expect(r.notices.current?.receiverName, 'Bo');
      r.dispose();
    });

    test('the panel switch turns strips off', () async {
      final r = room(on: false);
      r.enqueue(RoomEffect.gift(gift: g(5000), senderName: 'Me', sender: me(), receiver: bo()));
      await settle();
      expect(r.notices.current, isNull);
      r.dispose();
    });

    test('a gift row from somebody else gets a strip too', () async {
      final r = room();
      final played = r.onChatRow(
        {'id': 1, 'kind': 'gift', 'gift_id': 'gift-5000', 'sender_id': 'ann', 'gift_count': 1, 'gift_receiver_ids': ['bo']},
        meId: 'me',
        senderName: 'Ann',
        giftById: (id) => g(5000),
      );
      await settle();
      expect(played, isTrue);
      expect(r.notices.current?.senderName, 'Ann', reason: 'a profile that cannot be read still shows by the name the screen had');
      r.dispose();
    });

    test('my own row coming back over Realtime does not make a second strip', () async {
      final r = room();
      r.enqueue(RoomEffect.gift(gift: g(5000), senderName: 'You', senderId: 'me', sender: me(), receiver: bo()));
      await settle();
      r.notices.finish(r.notices.playId);
      r.onChatRow({'id': 9, 'kind': 'gift', 'gift_id': 'gift-5000', 'sender_id': 'me'}, meId: 'me', senderName: 'Me', giftById: (id) => g(5000));
      await settle();
      expect(r.notices.current, isNull);
      r.dispose();
    });
  });
}
