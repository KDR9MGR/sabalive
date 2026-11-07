import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/notice_feed.dart';
import 'package:sabalive/features/live/widgets/home_notice_layer.dart';
import 'package:sabalive/features/live/widgets/notice_strip.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-11-07 (owner: "for any user winning 5,000 coins it should trigger", "both gift and game win strip should show in home and in room"): the server's feed of big
/// gifts and big game wins becomes a strip on Home and in every open live room.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  Map<String, dynamic> win({String? name = 'Winner One', String? avatar = 'https://x/a.png', String? game = 'Rocket Star', String? image = 'https://x/g.png', num coins = 5000}) =>
      {'id': 'n1', 'winner_name': name, 'winner_avatar_url': avatar, 'game_name': game, 'game_image_url': image, 'coins': coins};

  group('one game win', () {
    test('reads the winner, the game and the coins from the row', () {
      final n = GameWinNotice.fromRow(win());
      expect((n.winnerName, n.winnerAvatarUrl, n.gameName, n.gameImageUrl, n.coins), ('Winner One', 'https://x/a.png', 'Rocket Star', 'https://x/g.png', 5000));
    });

    test('a missing or empty name reads "Someone", empty pictures and game are nothing, coins can come as a double', () {
      final n = GameWinNotice.fromRow(win(name: '  ', avatar: '', game: null, image: ' ', coins: 6000.0));
      expect((n.winnerName, n.winnerAvatarUrl, n.gameName, n.gameImageUrl, n.coins), ('Someone', null, null, null, 6000));
    });

    test('is a strip: winner on the left, a coin with +5,000 in the middle, the game on the right', () {
      final item = NoticeStripItem.fromFeed(GameWinNotice.fromRow(win()));
      expect(item.kind, NoticeKind.gameWin);
      expect((item.senderName, item.senderAvatarUrl), ('Winner One', 'https://x/a.png'));
      expect((item.receiverName, item.receiverAvatarUrl, item.showReceiverAvatar), ('Rocket Star', 'https://x/g.png', true));
      expect((item.iconEmoji, item.badgeText), ('🪙', '+5,000'));
    });

    test('big numbers get thousands separators; a game with no picture leaves the right-hand picture out', () {
      final item = NoticeStripItem.fromFeed(GameWinNotice.fromRow(win(coins: 1234567, image: null, game: null)));
      expect((item.badgeText, item.showReceiverAvatar, item.receiverName), ('+1,234,567', false, null));
    });
  });

  group('one gift', () {
    Map<String, dynamic> gift({bool toAll = false, String? receiver = 'Bo', num qty = 1, num coins = 5000, String? emoji = '🌹', String? icon}) => {
          'id': 'g1', 'sender_name': 'Ann', 'sender_avatar_url': 'https://x/a.png', 'receiver_name': receiver, 'receiver_avatar_url': receiver == null ? null : 'https://x/b.png',
          'to_all': toAll, 'gift_name': 'Rose', 'gift_emoji': emoji, 'gift_icon_url': icon, 'quantity': qty, 'coins': coins,
        };

    test('reads the sender, the receiver, the gift, the quantity and the whole cost from the row', () {
      final n = GiftNotice.fromRow(gift(qty: 5, coins: 25000, icon: 'https://x/rose.png'));
      expect((n.senderName, n.receiverName, n.toAll, n.giftName, n.giftEmoji, n.giftIconUrl, n.quantity, n.coins),
          ('Ann', 'Bo', false, 'Rose', '🌹', 'https://x/rose.png', 5, 25000));
    });

    test('an empty emoji reads as the gift box, a quantity is kept between 1 and 99', () {
      expect(GiftNotice.fromRow(gift(emoji: '')).giftEmoji, '🎁');
      expect(GiftNotice.fromRow(gift(qty: 0)).quantity, 1);
      expect(GiftNotice.fromRow(gift(qty: 500)).quantity, 99);
    });

    test('is a strip: sender, the gift with xN, the receiver; to everyone it says Everyone with no single picture', () {
      final one = NoticeStripItem.fromFeed(GiftNotice.fromRow(gift(qty: 3)));
      expect((one.kind, one.senderName, one.receiverName, one.showReceiverAvatar, one.count, one.iconEmoji), (NoticeKind.gift, 'Ann', 'Bo', true, 3, '🌹'));
      final all = NoticeStripItem.fromFeed(GiftNotice.fromRow(gift(toAll: true, receiver: null)));
      expect((all.receiverName, all.showReceiverAvatar, all.receiverAvatarUrl), ('Everyone', false, null));
    });
  });

  group('the shared feed', () {
    tearDown(() => NoticeFeed.debugSource = null);

    test('opens its source when the first listener arrives and closes it when the last one leaves; every listener gets every notice', () async {
      var opened = 0, closed = 0;
      late StreamController<FeedNotice> src;
      NoticeFeed.debugSource = () {
        src = StreamController<FeedNotice>(onListen: () => opened++, onCancel: () => closed++);
        return src.stream;
      };
      final a = <String>[], b = <String>[];
      final subA = NoticeFeed.instance.stream.listen((n) => a.add(n.id));
      final subB = NoticeFeed.instance.stream.listen((n) => b.add(n.id));
      expect(opened, 1, reason: 'one channel for the whole phone, however many listeners');
      src.add(GameWinNotice.fromRow(win()));
      await Future<void>.delayed(Duration.zero);
      expect(a, ['n1']);
      expect(b, ['n1']);
      await subA.cancel();
      expect(closed, 0, reason: 'somebody is still listening');
      await subB.cancel();
      expect(closed, 1, reason: 'nobody listens any more: the channel goes');
    });
  });

  group('in a live room', () {
    late StreamController<FeedNotice> feed;
    late RoomEffectController c;
    var on = true;

    setUp(() {
      feed = StreamController<FeedNotice>.broadcast();
      on = true;
      c = RoomEffectController(noticeFeed: feed.stream, noticesOn: () => on, prefetch: (_) {});
    });
    tearDown(() async {
      c.dispose();
      await feed.close();
    });

    test('a big win plays a strip', () async {
      feed.add(GameWinNotice.fromRow(win()));
      await Future<void>.delayed(Duration.zero);
      expect(c.notices.current?.kind, NoticeKind.gameWin);
    });

    test('the panel switch for notification strips turns the wins off too', () async {
      on = false;
      feed.add(GameWinNotice.fromRow(win()));
      await Future<void>.delayed(Duration.zero);
      expect(c.notices.current, isNull);
    });

    test('two wins in a row are two strips, never merged into "x2"', () async {
      feed.add(GameWinNotice.fromRow(win()));
      feed.add(GameWinNotice.fromRow(win()));
      await Future<void>.delayed(Duration.zero);
      expect(c.notices.current, isNotNull);
      expect(c.notices.waiting, 1);
    });

    test('a room that is closed stops listening', () async {
      c.dispose();
      feed.add(GameWinNotice.fromRow(win()));
      await Future<void>.delayed(Duration.zero);
      expect(feed.hasListener, isFalse);
      c = RoomEffectController(); // the tearDown disposes this one
    });
  });

  group('on Home', () {
    late StreamController<FeedNotice> feed;
    setUp(() => feed = StreamController<FeedNotice>.broadcast());
    tearDown(() => feed.close());

    Widget layer({required bool active, bool on = true}) => MaterialApp(home: Scaffold(body: Stack(children: [HomeNoticeLayer(active: active, feed: feed.stream, noticesOn: () => on)])));

    testWidgets('a big win draws a strip at the strip height; it listens only while active (signed in, no full-screen live)', (t) async {
      t.view.physicalSize = const Size(411, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(layer(active: false));
      expect(feed.hasListener, isFalse, reason: 'not active: the channel stays closed');
      await t.pumpWidget(layer(active: true));
      expect(feed.hasListener, isTrue);
      feed.add(GameWinNotice.fromRow(win()));
      await t.pump();
      await t.pump();
      expect(find.byType(NoticeStripPlayer), findsOneWidget);
      expect(t.getTopLeft(find.byType(NoticeStripPlayer)).dy + NoticeStripLayer.canvasHeight(411) / 2, closeTo(kNoticeStripCentre, 0.01), reason: 'the same height as in a room');
      await t.pumpWidget(layer(active: false));
      expect(feed.hasListener, isFalse, reason: 'a full-screen live opened: the room draws its own strips, Home stops');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with the panel switch off it draws nothing', (t) async {
      await t.pumpWidget(layer(active: true, on: false));
      feed.add(GameWinNotice.fromRow(win()));
      await t.pump();
      expect(find.byType(NoticeStripPlayer), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
