import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/profile_labels_repository.dart';
import 'package:sabalive/features/profile/widgets/profile_labels.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Badges and tags beyond the profile: a plate tag that is exactly as big as its artwork, bigger badges, the one-line version for lists, and the cache that
/// reads a whole list of people with two database reads.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  const url = 'https://x.supabase.co/storage/v1/object/public/gift-assets/tags/a.png';
  ProfileTag plate(String id, String name) => ProfileTag(id: id, name: name, color: const Color(0xFF118833), look: TagLook.plate, imageUrl: url);
  ProfileBadge badge(String id, String name) => ProfileBadge(id: id, name: name, emoji: '🏅');
  ProfileTag pill(String id, String name) => ProfileTag(id: id, name: name, color: const Color(0xFF7C3AED));

  group('a plate tag', () {
    // the artwork of the owner's staff tags: an SVGA, 4:1 (400 x 100), the text is part of the picture
    const svga = 'https://x.supabase.co/storage/v1/object/public/gift-assets/tags/agency.svga';
    Future<MovieEntity> banner(String _) async => MovieEntity()
      ..params = (MovieParams()
        ..viewBoxWidth = 400
        ..viewBoxHeight = 100
        ..fps = 20
        ..frames = 10);
    ProfileTag onBanner(String id, String name) => ProfileTag(id: id, name: name, color: const Color(0xFF118833), look: TagLook.plate, imageUrl: svga);

    Future<void> show(WidgetTester t, ProfileTag tag, {LabelSizes sizes = LabelSizes.profile, double width = 360}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: width, child: Wrap(children: [TagPill(tag: tag, sizes: sizes, svgaLoader: banner)]))),
      ));
      await t.pump();
      await t.pump();
    }

    testWidgets('is as big as its artwork at the tag height: the whole picture, not cut to the size of its name', (t) async {
      await show(t, onBanner('p', '.'));
      final size = t.getSize(find.byKey(const ValueKey('tag-p')));
      expect(size.height, LabelSizes.profile.tag);
      expect(size.width, LabelSizes.profile.tag * 4, reason: 'a 4:1 banner, every pixel of it; a "." used to make a tiny box that showed "Hos"');
    });

    testWidgets('a name with no letter or digit ("." or "-") is not written over the picture', (t) async {
      await show(t, onBanner('p', '.'));
      expect(find.text('.'), findsNothing);
      await show(t, onBanner('p', ' - '));
      expect(find.text('-'), findsNothing);
      expect(TagPill.nameIsWritten('.'), isFalse);
      expect(TagPill.nameIsWritten('...'), isFalse);
      expect(TagPill.nameIsWritten('Admin'), isTrue);
      expect(TagPill.nameIsWritten('७'), isTrue, reason: 'digits and letters of every script count');
    });

    testWidgets('does not stretch across the row it sits in, in a Wrap or in a stretching Column', (t) async {
      await show(t, onBanner('p', 'Agency'));
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).width, LabelSizes.profile.tag * 4);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [TagPill(tag: onBanner('p', 'Agency'), svgaLoader: banner)]),
          ),
        ),
      ));
      await t.pump();
      await t.pump();
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).width, LabelSizes.profile.tag * 4);
    });

    testWidgets('a name with letters is written once, centred on the picture, and never makes the plate bigger than the picture', (t) async {
      await show(t, onBanner('p', 'Agency'));
      final center = t.getCenter(find.byKey(const ValueKey('tag-p')));
      expect(find.text('Agency'), findsOneWidget);
      expect(t.getCenter(find.text('Agency')).dx, closeTo(center.dx, 1));
      await show(t, onBanner('p', 'A very long staff title that cannot fit on one small picture at all'));
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).width, LabelSizes.profile.tag * 4, reason: 'the name shrinks to fit the picture');
      expect(t.takeException(), isNull);
    });

    testWidgets('while the artwork is read, and if it fails, a coloured capsule stands in: one copy of the name, or nothing for "."', (t) async {
      final never = Completer<MovieEntity>();
      Future<void> pending(ProfileTag tag) async {
        await t.pumpWidget(MaterialApp(home: Scaffold(body: Wrap(children: [TagPill(tag: tag, svgaLoader: (_) => never.future)]))));
        await t.pump();
      }

      await pending(onBanner('p', 'Agency'));
      expect(find.text('Agency'), findsOneWidget, reason: 'written once, not on the capsule and again on the picture');
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).height, LabelSizes.profile.tag);
      await pending(onBanner('p', '.'));
      expect(find.text('.'), findsNothing);
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).height, LabelSizes.profile.tag, reason: 'it keeps its place in the row');

      await t.pumpWidget(MaterialApp(home: Scaffold(body: Wrap(children: [TagPill(tag: onBanner('p', 'Agency'), svgaLoader: (_) async => throw Exception('offline'))]))));
      await t.pump();
      await t.pump();
      expect(find.text('Agency'), findsOneWidget, reason: 'the tag never vanishes');
    });

    testWidgets('a plate on a plain still picture (PNG) is as tall as the tag and keeps the name on it', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: Wrap(children: [TagPill(tag: plate('p', 'Admin'))])))));
      expect(t.getSize(find.byKey(const ValueKey('tag-p'))).height, LabelSizes.profile.tag);
      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets('the compact size is smaller than the profile size', (t) async {
      await show(t, onBanner('p', '.'), sizes: LabelSizes.compact);
      final compact = t.getSize(find.byKey(const ValueKey('tag-p')));
      expect(compact.height, LabelSizes.compact.tag);
      expect(compact.width, LabelSizes.compact.tag * 4);
      expect(LabelSizes.compact.tag, lessThan(LabelSizes.profile.tag));
    });
  });

  group('badges are bigger on a profile', () {
    test('the profile sizes are larger than the compact ones, and the badge is taller than the tag', () {
      expect(LabelSizes.profile.badge, greaterThan(26), reason: 'it was 26');
      expect(LabelSizes.profile.badge, greaterThan(LabelSizes.profile.tag));
      expect(LabelSizes.profile.chipText, greaterThan(10.5), reason: 'the emoji chip text was 10.5');
      expect(LabelSizes.compact.badge, lessThan(LabelSizes.profile.badge));
    });

    testWidgets('a badge chip uses the profile size', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: ProfileLabelsRow(profileId: 'p1', loader: (_) async => ProfileLabels(badges: [badge('b1', 'Welcome')]))),
      ));
      await t.pump();
      final text = t.widget<w.Text>(find.text('Welcome'));
      expect(text.style!.fontSize, LabelSizes.profile.chipText);
    });
  });

  group('the one-line version for a list', () {
    Future<void> row(WidgetTester t, ProfileLabels labels, {double width = 320}) => t.pumpWidget(MaterialApp(
          home: Scaffold(body: SizedBox(width: width, child: ProfileLabelsRow(profileId: 'p1', compact: true, loader: (_) async => labels))),
        ));

    testWidgets('shows badges then tags in one line and never more than three', (t) async {
      await row(t, ProfileLabels(badges: [badge('b1', 'Welcome'), badge('b2', 'Verified')], tags: [pill('t1', 'Admin'), pill('t2', 'Staff'), pill('t3', 'Host')]));
      await t.pump();
      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget, reason: 'one tag fits the three');
      expect(find.text('Staff'), findsNothing);
      expect(find.text('+2'), findsOneWidget, reason: 'the two tags that do not fit');
      expect(t.getSize(find.byKey(const ValueKey('profile-labels'))).height, LabelSizes.compact.badge, reason: 'one line, as tall as a badge');
    });

    testWidgets('a person with nothing takes no room at all', (t) async {
      await row(t, const ProfileLabels());
      await t.pump();
      expect(find.byKey(const ValueKey('profile-labels')), findsNothing);
    });

    testWidgets('a narrow row clips instead of wrapping under the name', (t) async {
      await row(t, ProfileLabels(badges: [badge('b1', 'A long badge name'), badge('b2', 'Another long badge')]), width: 120);
      await t.pump();
      expect(tester(t), isNull);
      expect(t.getSize(find.byKey(const ValueKey('profile-labels'))).height, LabelSizes.compact.badge);
    });

    testWidgets('PersonLine puts the labels under the text', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [PersonLine(profileId: 'not-a-real-id', text: 'ID: 100123')]))));
      await t.pump();
      expect(find.text('ID: 100123'), findsOneWidget);
    });
  });

  group('reading many people at once', () {
    const a = '11111111-1111-1111-1111-111111111111';
    const b = '22222222-2222-2222-2222-222222222222';
    const c = '33333333-3333-3333-3333-333333333333';

    ProfileLabels some(String name) => ProfileLabels(badges: [badge(name, name)]);

    test('the asks made in the same moment become ONE read, and each person gets their own answer', () async {
      final calls = <List<String>>[];
      final cache = ProfileLabelsCache(loader: (ids) async {
        calls.add(List.of(ids));
        return {a: some('A'), c: some('C')};
      }, batchDelay: const Duration(milliseconds: 5));
      final results = await Future.wait([cache.get(a), cache.get(b), cache.get(c), cache.get(a)]);
      expect(calls, hasLength(1));
      expect(calls.single.toSet(), {a, b, c});
      expect(results[0].badges.single.name, 'A');
      expect(results[1].isEmpty, isTrue, reason: 'B has nothing');
      expect(results[2].badges.single.name, 'C');
      expect(results[3].badges.single.name, 'A', reason: 'asking twice in the same moment shares the answer');
    });

    test('an answer is kept: asking again costs no read, and peek shows it at once', () async {
      var reads = 0;
      final cache = ProfileLabelsCache(loader: (ids) async {
        reads++;
        return {a: some('A')};
      }, batchDelay: Duration.zero);
      expect(cache.peek(a), isNull);
      await cache.get(a);
      expect(cache.peek(a)!.badges.single.name, 'A');
      await cache.get(a);
      expect(reads, 1);
    });

    test('an answer expires after the ttl and is read again', () async {
      var reads = 0;
      var now = DateTime(2026, 10, 26, 12);
      final cache = ProfileLabelsCache(
        loader: (ids) async {
          reads++;
          return {a: some('A')};
        },
        batchDelay: Duration.zero,
        ttl: const Duration(minutes: 5),
        now: () => now,
      );
      await cache.get(a);
      now = now.add(const Duration(minutes: 4));
      await cache.get(a);
      expect(reads, 1);
      now = now.add(const Duration(minutes: 2));
      expect(cache.peek(a), isNull);
      await cache.get(a);
      expect(reads, 2);
    });

    test('a failed read is "no labels" and is NOT remembered, so the next screen tries again', () async {
      var reads = 0;
      final cache = ProfileLabelsCache(loader: (ids) async {
        reads++;
        throw Exception('offline');
      }, batchDelay: Duration.zero);
      expect((await cache.get(a)).isEmpty, isTrue);
      expect((await cache.get(a)).isEmpty, isTrue);
      expect(reads, 2);
    });

    test('a demo id (not a real uuid) is answered at once with nothing, without any read', () async {
      var reads = 0;
      final cache = ProfileLabelsCache(loader: (ids) async {
        reads++;
        return const {};
      });
      expect((await cache.get('nisha')).isEmpty, isTrue);
      expect(reads, 0);
    });

    test('a long list is read in pieces of at most 60 people', () async {
      final sizes = <int>[];
      final cache = ProfileLabelsCache(loader: (ids) async {
        sizes.add(ids.length);
        return const {};
      }, batchDelay: const Duration(milliseconds: 5));
      String id(int i) => '${i.toRadixString(16).padLeft(8, '0')}-1111-1111-1111-111111111111';
      await Future.wait([for (var i = 0; i < 130; i++) cache.get(id(i))]);
      expect(sizes, [60, 60, 10]);
    });

    test('the memory is bounded: the oldest answer goes when there are too many', () async {
      final cache = ProfileLabelsCache(loader: (ids) async => {for (final i in ids) i: some(i.substring(0, 2))}, batchDelay: Duration.zero, maxEntries: 2);
      await cache.get(a);
      await cache.get(b);
      await cache.get(c);
      expect(cache.peek(a), isNull);
      expect(cache.peek(b), isNotNull);
      expect(cache.peek(c), isNotNull);
    });
  });

  group('turning database rows into labels', () {
    test('tags are grouped per person and sorted by the panel order, then by name', () {
      final g = ProfileLabelsRepository.groupTags([
        {'profile_id': 'p1', 'profile_tags': {'id': 't2', 'name': 'Zed', 'color': '#111111', 'sort_order': 1}},
        {'profile_id': 'p1', 'profile_tags': {'id': 't1', 'name': 'Alpha', 'color': '#111111', 'sort_order': 1}},
        {'profile_id': 'p1', 'profile_tags': {'id': 't0', 'name': 'First', 'color': '#111111', 'sort_order': 0}},
        {'profile_id': 'p2', 'profile_tags': {'id': 't9', 'name': 'Other', 'color': '#111111', 'sort_order': 5}},
        {'profile_id': 'p3', 'profile_tags': null},
        {'profile_tags': {'id': 'tx', 'name': 'No person'}},
      ]);
      expect([for (final t in g['p1']!) t.name], ['First', 'Alpha', 'Zed']);
      expect(g['p2']!.single.name, 'Other');
      expect(g.containsKey('p3'), isFalse);
      expect(g.length, 2);
    });

    test('badges are grouped per person in the panel order; a missing emoji is a medal', () {
      final g = ProfileLabelsRepository.groupBadges([
        {'profile_id': 'p1', 'badges': {'id': 'b2', 'name': 'Second', 'emoji': '', 'icon_url': ' ', 'sort_order': 2}},
        {'profile_id': 'p1', 'badges': {'id': 'b1', 'name': 'First', 'emoji': '🎉', 'icon_url': 'https://x/y.svg', 'sort_order': 1}},
        {'profile_id': 'p2', 'badges': {'id': 'b3', 'name': 3}},
      ]);
      expect([for (final b in g['p1']!) b.name], ['First', 'Second']);
      expect(g['p1']![0].iconUrl, 'https://x/y.svg');
      expect(g['p1']![1].emoji, '🏅');
      expect(g['p1']![1].iconUrl, isNull);
      expect(g.containsKey('p2'), isFalse, reason: 'a badge without a name is dropped');
    });
  });
}

/// Placeholder so the narrow-row test reads naturally: nothing should have overflowed.
Object? tester(WidgetTester t) => t.takeException();
