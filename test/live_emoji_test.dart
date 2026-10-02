import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/live_emojis_repository.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/live_chat_bubble.dart';
import 'package:sabalive/features/live/widgets/live_emoji_sheet.dart';

const _heart = LiveEmoji(id: 'e1', isGif: false, label: 'Heart', emoji: '❤️');
const _fire = LiveEmoji(id: 'e2', isGif: false, label: 'Fire', emoji: '🔥');
const _cat = LiveEmoji(
  id: 'g1', isGif: true, label: 'Dancing cat', emoji: '🐱',
  assetUrl: 'https://x.co/cat.gif',
);

/// Opens the picker the way a room screen does and reports what was chosen.
Future<void> _open(WidgetTester t, void Function(LiveEmoji?) onPicked) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => onPicked(await showLiveEmojiSheet(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  // The catalog read fails under test (no Supabase) and falls back to the cache.
  await t.pumpAndSettle();
}

void main() {
  tearDown(() => LiveEmojisRepository.cached = null);

  group('LiveEmoji.fromRow', () {
    test('a plain emoji', () {
      final e = LiveEmoji.fromRow({'id': 'a', 'kind': 'emoji', 'label': 'Fire', 'emoji': '🔥', 'asset_url': null});
      expect(e.isGif, isFalse);
      expect(e.emoji, '🔥');
      expect(e.assetUrl, isNull);
    });

    test('a GIF', () {
      final e = LiveEmoji.fromRow({'id': 'b', 'kind': 'gif', 'label': 'Cat', 'emoji': null, 'asset_url': 'https://x.co/c.gif'});
      expect(e.isGif, isTrue);
      expect(e.assetUrl, 'https://x.co/c.gif');
    });
  });

  group('picker', () {
    testWidgets('emoji only: no tabs, tapping one returns it', (t) async {
      LiveEmojisRepository.cached = [_heart, _fire];
      LiveEmoji? picked;
      await _open(t, (e) => picked = e);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('❤️'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      await t.tap(find.text('🔥'));
      await t.pumpAndSettle();
      expect(picked?.id, 'e2');
    });

    testWidgets('with GIFs there is a GIFs tab, and tapping a GIF returns it', (t) async {
      LiveEmojisRepository.cached = [_heart, _cat];
      LiveEmoji? picked;
      await _open(t, (e) => picked = e);
      expect(find.byType(TabBar), findsOneWidget);
      await t.tap(find.text('GIFs'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('gif-g1')));
      await t.pumpAndSettle();
      expect(picked?.isGif, isTrue);
      expect(picked?.id, 'g1');
    });

    testWidgets('an empty catalog says so rather than showing stale emoji', (t) async {
      LiveEmojisRepository.cached = [];
      await _open(t, (_) {});
      expect(find.text('No emojis available right now'), findsOneWidget);
    });

    testWidgets('when the catalog cannot be read at all, the built-in set is offered', (t) async {
      LiveEmojisRepository.cached = null;
      await _open(t, (_) {});
      expect(find.text('❤️'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
    });
  });

  group('sticker in chat', () {
    final user = AppUser(id: 'u', name: 'Sam', username: '@sam');

    testWidgets('shows the sender and the picture; its label stands in if it cannot load', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveChatLineBubble(
              line: LiveChatLine(user, 'Dancing cat', stickerUrl: 'https://x.co/none.gif'),
            ),
          ),
        ),
      );
      expect(find.text('Sam'), findsOneWidget);
      // flutter_test answers every HTTP request with a 400, so the image errors.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      await t.pump();
      expect(find.text('Dancing cat'), findsOneWidget);
    });

    test('LiveChatLine knows when it is a sticker', () {
      expect(LiveChatLine(user, 'hi').isSticker, isFalse);
      expect(LiveChatLine(user, 'cat', stickerUrl: 'https://x.co/c.gif').isSticker, isTrue);
    });
  });

  group('StoreItem', () {
    Map<String, dynamic> row({String category = 'entry_effect', Object? asset}) => {
      'id': 'i1', 'category': category, 'name': 'Fire Entry', 'emoji': '🔥',
      'price_coins': 100, 'duration_days': 7, 'asset_url': asset,
    };

    test('carries the uploaded artwork url', () {
      expect(StoreItem.fromRow(row(asset: 'https://x.co/e.svga')).assetUrl, 'https://x.co/e.svga');
    });

    test('a missing or blank url means "use the emoji"', () {
      expect(StoreItem.fromRow(row()).assetUrl, isNull);
      expect(StoreItem.fromRow(row(asset: '  ')).assetUrl, isNull);
    });

    test('knows every category the panel can create, including room skins', () {
      expect(StoreItem.fromRow(row(category: 'frame')).category, StoreCategory.frame);
      expect(StoreItem.fromRow(row(category: 'vip')).category, StoreCategory.vip);
      expect(StoreItem.fromRow(row(category: 'entry_effect')).category, StoreCategory.entryEffect);
      expect(StoreItem.fromRow(row(category: 'vehicle')).category, StoreCategory.vehicle);
      expect(StoreItem.fromRow(row(category: 'room_skin')).category, StoreCategory.roomSkin);
    });
  });
}
