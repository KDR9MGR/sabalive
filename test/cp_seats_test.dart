import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/cp_seats.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CP (couple) seats in an audio room, 2026-11-05: two extra seats (24 left = the host's, 25 right) above the grid on a couple banner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
    CpSeatsSupport.reset();
  });

  AppUser user(String id, String name) => AppUser(id: id, name: name, username: '@$id');

  Future<MovieEntity> neverLoads(String _) => Future<MovieEntity>.error('no banner in this test');

  group('the rules', () {
    test('seats 24 and 25 are the couple seats and nothing else is', () {
      expect(kCpSeats, [24, 25]);
      expect(isCpSeat(24), isTrue);
      expect(isCpSeat(25), isTrue);
      for (final n in [0, 1, 16, 23, 26]) {
        expect(isCpSeat(n), isFalse, reason: 'seat $n');
      }
    });

    test('a couple seat is claimed with its own function; an ordinary seat with the old one', () {
      expect(claimSeatRpc(24), 'claim_cp_seat');
      expect(claimSeatRpc(25), 'claim_cp_seat');
      expect(claimSeatRpc(1), 'claim_seat');
      expect(claimSeatRpc(16), 'claim_seat');
    });

    test('the seat count changes with the old function unless couple seats are on (the old one would delete them)', () {
      expect(setSeatCountRpc(cpSeats: false), 'set_seat_count');
      expect(setSeatCountRpc(cpSeats: true), 'set_seat_count_v2');
    });

    test('the room grid never reaches the couple seats: 16 is the most it draws', () {
      expect(kMaxAudioSeats, lessThan(kCpSeatLeft));
    });
  });

  group('the layout maths', () {
    test('the two seats sit either side of the heart, left then right, the same height', () {
      final l = CpLayout.forWidth(320);
      expect(l.left.dx, lessThan(l.right.dx));
      expect(l.left.dy, l.right.dy);
      // the file puts the avatar slots 151.5 canvas units apart
      expect(l.right.dx - l.left.dx, closeTo(151.5 * l.scale, 0.001));
      // the heart is centred between them and the row is centred on its wings: the pair is in the middle of the row
      expect((l.left.dx + l.right.dx) / 2, closeTo(160, 12));
    });

    test('the wings fit the row exactly: the banner is as wide as the row allows', () {
      for (final w in [300.0, 320.0, 360.0, 411.0]) {
        final l = CpLayout.forWidth(w);
        final wingsLeft = l.bannerLeft + CpBanner.wingsLeft * l.scale;
        final wingsRight = l.bannerLeft + CpBanner.wingsRight * l.scale;
        expect(wingsLeft, closeTo(0, 0.01), reason: 'width $w');
        expect(wingsRight, closeTo(w, 0.01), reason: 'width $w');
      }
    });

    test('both seats (picture slot and the name under it) are inside the row, and the row is as tall as the banner at least', () {
      for (final w in [300.0, 320.0, 360.0]) {
        final l = CpLayout.forWidth(w);
        for (final c in [l.left, l.right]) {
          expect(c.dx - CpSeatsRow.seatSlot / 2, greaterThanOrEqualTo(0), reason: 'width $w');
          expect(c.dx + CpSeatsRow.seatSlot / 2, lessThanOrEqualTo(w), reason: 'width $w');
          expect(c.dy - CpSeatsRow.seatSlot / 2, greaterThanOrEqualTo(0), reason: 'width $w');
          expect(c.dy + CpSeatsRow.seatSlot / 2 + CpSeatsRow.labelRoom, lessThanOrEqualTo(l.rowHeight + 0.001), reason: 'width $w');
        }
        expect(l.rowHeight, greaterThanOrEqualTo(l.bannerHeight));
      }
    });

    test('the two seat pictures do not overlap each other on a small phone', () {
      final l = CpLayout.forWidth(300);
      expect(l.right.dx - l.left.dx, greaterThan(CpSeatsRow.seatSize + 4));
    });
  });

  group('the bundled banner', () {
    testWidgets('is the 750 x 140 file with the two avatar slots, and loads with the placeholder discs hidden', (t) async {
      await t.runAsync(() async {
        final movie = await CpBanner.load(CpBanner.asset);
        expect(movie.params.viewBoxWidth, CpBanner.width);
        expect(movie.params.viewBoxHeight, CpBanner.height);
        expect(movie.params.frames, 64);
        for (final key in CpBanner.placeholders) {
          expect(movie.sprites.any((s) => s.imageKey == key), isTrue, reason: 'the file has the $key slot the layout assumes');
          expect(movie.dynamicItem.dynamicHidden[key], isTrue, reason: '$key is hidden: the real seat stands there');
        }
      });
    });
  });

  group('the row', () {
    Future<void> show(
      WidgetTester t, {
      Map<int, AppUser> occupants = const {},
      String hostId = 'host',
      void Function(int)? onTap,
      Set<int> speaking = const {},
      Set<int> muted = const {},
    }) {
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: CpSeatsRow(
              occupants: occupants,
              hostId: hostId,
              speakingSeats: speaking,
              mutedSeats: muted,
              onSeatTap: onTap ?? (_) {},
              bannerLoader: neverLoads,
            ),
          ),
        ),
      ));
    }

    testWidgets('empty seats say CP and each tap reports its own seat number', (t) async {
      final taps = <int>[];
      await show(t, onTap: taps.add);
      expect(find.text('CP'), findsNWidgets(2));
      await t.tap(find.byKey(const ValueKey('cp-seat-24')));
      await t.tap(find.byKey(const ValueKey('cp-seat-25')));
      expect(taps, [24, 25]);
    });

    testWidgets('the host on the left seat and a guest on the right show their names; the host is NOT drawn bigger', (t) async {
      await show(t, occupants: {24: user('host', 'Host Name'), 25: user('g1', 'Guest Name')});
      expect(find.text('Host Name'), findsOneWidget);
      expect(find.text('Guest Name'), findsOneWidget);
      expect(find.text('CP'), findsNothing);
      final left = t.getSize(find.byKey(const ValueKey('cp-seat-24')));
      final right = t.getSize(find.byKey(const ValueKey('cp-seat-25')));
      expect(left, right, reason: 'a couple looks even');
    });

    testWidgets('the two seats are inside the screen and in the middle of it', (t) async {
      await show(t);
      final l = t.getRect(find.byKey(const ValueKey('cp-seat-24')));
      final r = t.getRect(find.byKey(const ValueKey('cp-seat-25')));
      expect(l.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(360));
      expect(l.right, lessThan(r.left + 1));
      expect(((l.center.dx + r.center.dx) / 2), closeTo(180, 12));
    });

    testWidgets('a banner that cannot load does not break the seats', (t) async {
      await show(t, occupants: {24: user('host', 'Host Name')});
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('Host Name'), findsOneWidget);
    });

    testWidgets('the banner never takes the taps: they go to the seats', (t) async {
      await show(t);
      final banner = find.ancestor(of: find.byKey(const ValueKey('cp-banner')), matching: find.byType(IgnorePointer));
      expect(banner, findsWidgets);
    });

    testWidgets('a seat that is talking or muted still draws', (t) async {
      await show(t, occupants: {24: user('host', 'Host Name'), 25: user('g1', 'Guest')}, speaking: {24}, muted: {25});
      expect(t.takeException(), isNull);
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    });
  });

  group('in the seat grid', () {
    Future<void> grid(WidgetTester t, {required bool cp, Map<int, AppUser> occupants = const {}}) {
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SeatGrid(
              seatCount: 8,
              occupants: occupants,
              hostId: 'host',
              onSeatTap: (_) {},
              cpSeats: cp,
            ),
          ),
        ),
      ));
    }

    testWidgets('off (the default): exactly the grid it always was', (t) async {
      await grid(t, cp: false);
      expect(find.byType(CpSeatsRow), findsNothing);
      expect(find.byType(SeatCircle), findsNWidgets(8));
    });

    testWidgets('on: the couple row sits ABOVE the eight ordinary seats', (t) async {
      await grid(t, cp: true, occupants: {24: user('host', 'Host Name')});
      expect(find.byType(CpSeatsRow), findsOneWidget);
      expect(find.byType(SeatCircle), findsNWidgets(10), reason: '2 couple seats + 8 ordinary ones');
      expect(find.text('Host Name'), findsOneWidget);
      final cp = t.getRect(find.byType(CpSeatsRow));
      final firstSeat = t.getRect(find.byType(SeatCircle).at(2)); // the first ordinary seat
      expect(cp.bottom, lessThanOrEqualTo(firstSeat.top + 0.5));
      expect(t.takeException(), isNull);
    });

    testWidgets('a person on a couple seat is not also drawn in the ordinary grid', (t) async {
      await grid(t, cp: true, occupants: {24: user('host', 'Host Name'), 25: user('g1', 'Guest Name')});
      expect(find.text('Host Name'), findsOneWidget);
      expect(find.text('Guest Name'), findsOneWidget);
    });
  });

  group('the host\'s button', () {
    Future<void> room(WidgetTester t, {required bool cp, VoidCallback? toggle}) {
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SeatRoom(
            hostId: 'host',
            seatCount: 8,
            lockedSeats: const {},
            onSeatTap: (_) {},
            onAddSeat: () {},
            onRemoveSeat: () {},
            cpSeats: cp,
            onToggleCpSeats: toggle,
          ),
        ),
      ));
    }

    testWidgets('a viewer\'s room has no button (no callback)', (t) async {
      await room(t, cp: false);
      expect(find.text('Add CP seats'), findsNothing);
      expect(find.text('Remove CP seats'), findsNothing);
    });

    testWidgets('the host sees Add CP seats while they are off and Remove CP seats while they are on, and a tap reports', (t) async {
      var taps = 0;
      await room(t, cp: false, toggle: () => taps++);
      expect(find.text('Add CP seats'), findsOneWidget);
      await t.tap(find.text('Add CP seats'));
      expect(taps, 1);
      await room(t, cp: true, toggle: () => taps++);
      expect(find.text('Remove CP seats'), findsOneWidget);
      expect(find.byType(CpSeatsRow), findsOneWidget);
      await t.tap(find.text('Remove CP seats'));
      expect(taps, 2);
    });

    testWidgets('the existing Add 4 / Remove 4 buttons are still there', (t) async {
      await room(t, cp: false, toggle: () {});
      expect(find.text('Add 4'), findsOneWidget);
      expect(find.text('Remove 4'), findsOneWidget);
    });
  });

  group('a server that is behind the app', () {
    test('a "column does not exist" answer turns the column off and later reads leave it out', () {
      expect(CpSeatsSupport.column, ', cp_seats');
      expect(CpSeatsSupport.noteError(StateError('network')), isFalse, reason: 'a network error is not a missing column');
      expect(CpSeatsSupport.available, isTrue);
    });
  });
}
