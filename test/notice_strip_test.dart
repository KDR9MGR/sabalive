import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/notice_feed.dart';
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

  group('the bundled files', () {
    for (final kind in NoticeKind.values) {
      testWidgets('the ${kind.name} strip is a 750 x 300 file of 85 frames with the five slots we fill', (t) async {
        await t.runAsync(() async {
          final m = await NoticeArt.movie(kind: kind);
          expect(m.params.viewBoxWidth, NoticeArt.width);
          expect(m.params.viewBoxHeight, NoticeArt.height);
          expect(m.params.frames, 85);
          for (final key in [NoticeArt.leftAvatar, NoticeArt.rightAvatar, NoticeArt.leftName, NoticeArt.rightName, NoticeArt.middle]) {
            expect(m.sprites.any((s) => s.imageKey == key), isTrue, reason: key);
          }
          expect(m.autorelease, isFalse, reason: 'a shared movie is never freed by a player');
        });
      });
    }

    test('a gift plays full_venue_one (gift_strip.svga), a game win keeps the other file (game_win_strip.svga); each is read once and kept apart', () async {
      final asked = <String>[];
      Future<MovieEntity> fake(String path) async {
        asked.add(path);
        return MovieEntity();
      }

      final g1 = await NoticeArt.movie(kind: NoticeKind.gift, loader: fake);
      final g2 = await NoticeArt.movie(kind: NoticeKind.gift, loader: fake);
      final w1 = await NoticeArt.movie(kind: NoticeKind.gameWin, loader: fake);
      expect(asked, ['assets/notice/gift_strip.svga', 'assets/notice/game_win_strip.svga']);
      expect(identical(g1, g2), isTrue);
      expect(identical(g1, w1), isFalse);
      expect(NoticeArt.assetFor(NoticeKind.gift), isNot(NoticeArt.assetFor(NoticeKind.gameWin)));
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

  group('from the server\'s feed', () {
    GiftNotice giftNotice({String sender = 'Ann', String? receiver = 'Bo', bool toAll = false, String emoji = '🌹', String? icon, int qty = 1, int coins = 5000}) => GiftNotice(
          id: 'g1',
          senderName: sender,
          senderAvatarUrl: 'https://x/a.png',
          receiverName: receiver,
          receiverAvatarUrl: receiver == null ? null : 'https://x/b.png',
          toAll: toAll,
          giftName: 'Rose',
          giftEmoji: emoji,
          giftIconUrl: icon,
          quantity: qty,
          coins: coins,
        );

    RoomEffectController room({bool on = true, Stream<FeedNotice>? feed}) => RoomEffectController(noticesOn: () => on, noticeFeed: feed, prefetch: (_) {});

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a big gift announced by the server is a strip naming the sender and the receiver, with the quantity', () async {
      final feed = StreamController<FeedNotice>.broadcast();
      final r = room(feed: feed.stream);
      feed.add(giftNotice(qty: 3, icon: 'https://x/rose.png'));
      await settle();
      final n = r.notices.current!;
      expect((n.kind, n.senderName, n.senderAvatarUrl, n.receiverName, n.receiverAvatarUrl, n.count, n.showReceiverAvatar, n.iconEmoji, n.iconUrl),
          (NoticeKind.gift, 'Ann', 'https://x/a.png', 'Bo', 'https://x/b.png', 3, true, '🌹', 'https://x/rose.png'));
      r.dispose();
      await feed.close();
    });

    test('a gift to everyone names Everyone and has no single receiver picture', () async {
      final feed = StreamController<FeedNotice>.broadcast();
      final r = room(feed: feed.stream);
      feed.add(giftNotice(receiver: null, toAll: true));
      await settle();
      final n = r.notices.current!;
      expect((n.receiverName, n.showReceiverAvatar, n.receiverAvatarUrl), ('Everyone', false, null));
      r.dispose();
      await feed.close();
    });

    test('a gift whose receiver the server could not name leaves the right-hand picture out', () async {
      final feed = StreamController<FeedNotice>.broadcast();
      final r = room(feed: feed.stream);
      feed.add(giftNotice(receiver: null));
      await settle();
      expect((r.notices.current!.receiverName, r.notices.current!.showReceiverAvatar), (null, false));
      r.dispose();
      await feed.close();
    });

    test('the panel switch turns strips off', () async {
      final feed = StreamController<FeedNotice>.broadcast();
      final r = room(on: false, feed: feed.stream);
      feed.add(giftNotice());
      await settle();
      expect(r.notices.current, isNull);
      r.dispose();
      await feed.close();
    });

    test('a gift\'s OWN effect in the room no longer makes a strip: strips come only from the server\'s feed (one strip per big gift, on Home and in every room)', () async {
      final r = room();
      r.enqueue(RoomEffect.gift(gift: Gift('gift-5000', 'Rose', '🌹', 5000), senderName: 'Me', sender: AppUser(id: 'me', name: 'Me', username: '@me'), receiver: AppUser(id: 'bo', name: 'Bo', username: '@bo')));
      await settle();
      expect(r.notices.current, isNull);
      expect(r.current, isNotNull, reason: 'the gift effect itself still plays');
      r.dispose();
    });

    test('the same gift announced twice while one waits is one strip with a bigger count', () async {
      final feed = StreamController<FeedNotice>.broadcast();
      final r = room(feed: feed.stream);
      for (var i = 0; i < 3; i++) {
        feed.add(giftNotice());
      }
      await settle();
      expect(r.notices.current!.count, 1);
      expect(r.notices.waiting, 1);
      expect(r.notices.waiting == 1 && r.notices.current != null, isTrue);
      r.dispose();
      await feed.close();
    });
  });

  group('the strip\'s height', () {
    testWidgets('the middle of the strip is the same distance below the safe area on every screen width: the height of the couple seats', (t) async {
      for (final width in [320.0, 360.0, 411.0, 480.0]) {   // a phone; a tablet's canvas is taller than the line is deep, so it just starts at the top
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        final c = NoticeStripController();
        await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [NoticeStripLayer(controller: c, loader: (_) async => null)]))));
        c.add(const NoticeStripItem(kind: NoticeKind.gameWin, senderName: 'W', iconEmoji: '🪙'));
        await t.pump();
        // the canvas starts at (centre - canvas height / 2), so the strip, which is in the middle of the canvas, is centred on the line (the movie itself does not decode under the
        // test's fake clock, so the player is empty here and its top is what can be measured)
        expect(t.getTopLeft(find.byType(NoticeStripPlayer)).dy + NoticeStripLayer.canvasHeight(width) / 2, closeTo(kNoticeStripCentre, 0.01), reason: 'width $width');
        c.dispose();
        await t.pumpWidget(const SizedBox.shrink());
      }
      addTearDown(t.view.reset);
    });

    testWidgets('a strip is NOT in the middle of the screen any more (it sat over the seats before): it starts near the top', (t) async {
      t.view.physicalSize = const Size(411, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = NoticeStripController();
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [NoticeStripLayer(controller: c, loader: (_) async => null)]))));
      c.add(const NoticeStripItem(kind: NoticeKind.gift, senderName: 'A', iconEmoji: '🌹'));
      await t.pump();
      expect(t.getRect(find.byType(NoticeStripPlayer)).bottom, lessThan(450));
      c.dispose();
    });
  });
}
