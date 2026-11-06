import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/core/widgets/pills.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/cp_seats.dart';
import 'package:sabalive/features/live/widgets/golden_seat.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-11-06 (owner): the golden seat artwork for empty seats, nobody on a couple seat wears a frame, the seat rows sit closer, and the Rankings get a fourth chip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
    GoldenSeatArt.forget();
    // a seat grid never decodes the real file here: the grey circle (the fallback) is what shows
    GoldenSeatArt.debugLoader = (_) => Future<MovieEntity>.error('no art in this test');
    CpSeatsSupport.reset();
  });
  tearDown(() {
    GoldenSeatArt.debugLoader = null;
    GoldenSeatArt.forget();
  });

  AppUser user(String id, String name, {String? frame}) => AppUser(id: id, name: name, username: '@$id', frameUrl: frame);

  Future<void> grid(WidgetTester t, {int seats = 8, Map<int, AppUser> occupants = const {}, Set<int> locked = const {}, bool cp = false, bool reduceMotion = false}) {
    t.view.physicalSize = const Size(360, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    return t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion), child: child!),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SeatGrid(seatCount: seats, occupants: occupants, lockedSeats: locked, hostId: 'host', onSeatTap: (_) {}, cpSeats: cp),
        ),
      ),
    ));
  }

  group('the golden seat', () {
    testWidgets('every EMPTY seat of the grid is the golden seat; a locked seat keeps its padlock and a taken seat its person', (t) async {
      await grid(t, occupants: {3: user('a', 'Ann')}, locked: {2});
      expect(find.byType(GoldenSeat), findsNWidgets(6), reason: '8 seats - 1 locked - 1 taken');
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      expect(find.text('Ann'), findsOneWidget);
    });

    testWidgets('until the file is read (or if it cannot be) the old grey circle with a chair stands in, so a seat is never blank', (t) async {
      await grid(t);
      await t.pump();
      expect(find.byIcon(Icons.event_seat_rounded), findsNWidgets(8));
      expect(t.takeException(), isNull);
    });

    testWidgets('only the audio room grid asks for it: a seat drawn by anything else (video strip, PK arena) is the plain circle', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SeatCircle(seat: 1, size: 56))));
      expect(find.byType(GoldenSeat), findsNothing);
      expect(find.byIcon(Icons.event_seat_rounded), findsOneWidget);
    });

    testWidgets('it does not change how much room a seat takes: a seat is the same size with or without the art', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SeatCircle(seat: 1, size: kSeatPicture, slot: 58)))));
      final plain = t.getSize(find.byType(SeatCircle));
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SeatCircle(seat: 1, size: kSeatPicture, slot: 58, goldenSeat: true)))));
      expect(t.getSize(find.byType(SeatCircle)), plain);
    });

    testWidgets('the golden ring is as wide as the seat\'s own picture, and the picture around it spills over the seat\'s box', (t) async {
      // a video live's seat: no slot, so the seat is exactly its picture
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SeatCircle(seat: 1, size: kSeatPicture, showLabel: false, goldenSeat: true)))));
      final art = t.getSize(find.byType(GoldenSeat));
      expect(art.width, art.height);
      expect(art.width, closeTo(GoldenSeat.sideFor(kSeatPicture), 0.01));
      // the ring is 65 % of the file's picture: its diameter on screen is the 36 asked for
      expect(art.width * GoldenSeatArt.ringFraction, closeTo(kSeatPicture, 0.01));
      expect(art.width, greaterThan(t.getSize(find.byType(SeatCircle)).width), reason: 'bigger than the seat, so it needs the overflow');
    });

    testWidgets('the picture is centred on the seat', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SeatCircle(seat: 1, size: kSeatPicture, slot: 58, goldenSeat: true)))));
      final seatBox = t.getRect(find.byType(SeatCircle));
      final art = t.getRect(find.byType(GoldenSeat));
      expect(art.center.dx, closeTo(seatBox.center.dx, 0.5));
      // vertically it is centred on the 58 px square above the name, not on the whole seat with its name
      expect(art.center.dy, closeTo(seatBox.top + 29, 0.5));
    });

    testWidgets('with "remove animations" on the seat shows one still frame instead of playing', (t) async {
      await grid(t, reduceMotion: true);
      final media = t.widgetList<RemoteMedia>(find.byType(RemoteMedia));
      expect(media, isNotEmpty);
      expect(media.every((m) => !m.animate), isTrue);
      await grid(t, reduceMotion: false);
      expect(t.widgetList<RemoteMedia>(find.byType(RemoteMedia)).every((m) => m.animate && m.loop), isTrue);
    });

    test('the shared movie is read once for all the seats of a room, and a failed read is tried again next time', () async {
      var reads = 0;
      GoldenSeatArt.forget();
      GoldenSeatArt.debugLoader = (_) {
        reads++;
        return Future<MovieEntity>.error('offline');
      };
      await expectLater(GoldenSeatArt.movie(), throwsA(anything));
      await expectLater(GoldenSeatArt.movie(), throwsA(anything));
      expect(reads, 2, reason: 'a failure is not remembered');
    });

    testWidgets('the REAL bundled file is the owner\'s: a 159 x 159 square of 30 frames at 20 fps, and it is marked shared (never freed by a player)', (t) async {
      GoldenSeatArt.debugLoader = null;
      GoldenSeatArt.forget();
      MovieEntity? movie;
      await t.runAsync(() async {
        movie = await GoldenSeatArt.movie();
      });
      expect(movie, isNotNull);
      expect(movie!.params.viewBoxWidth, GoldenSeatArt.canvas);
      expect(movie!.params.viewBoxHeight, GoldenSeatArt.canvas);
      expect(movie!.params.frames, 30);
      expect(movie!.params.fps, 20);
      expect(movie!.autorelease, isFalse);
      // asking again gives the same decoded movie, not another decode
      late MovieEntity again;
      await t.runAsync(() async {
        again = await GoldenSeatArt.movie();
      });
      expect(identical(again, movie), isTrue);
    });
  });

  group('every seat is 36 px, empty or taken, in the audio room AND the video live (owner, 2026-11-06)', () {
    test('the shared size is 36 and the audio grid uses it (it was 56)', () {
      expect(kSeatPicture, 36);
      expect(SeatGrid.seatSize, 36);
    });

    testWidgets('audio grid: an empty seat\'s golden ring and a taken seat\'s picture are the same 36 px', (t) async {
      await grid(t, occupants: {1: user('a', 'Ann')});
      final ring = t.getSize(find.byType(GoldenSeat).first).width * GoldenSeatArt.ringFraction;
      expect(ring, closeTo(36, 0.01));
      // the taken seat: the avatar (32) inside its 2 px ring = 36
      expect(t.getSize(find.byType(AppAvatar).first).width + 4, closeTo(36, 0.01));
    });

    testWidgets('audio grid: the room for a seat\'s picture is just what its frame needs (36 x 1.6), so rows are not far apart', (t) async {
      await grid(t);
      final slot = SeatGrid.slotFor(320);
      expect(slot, closeTo(36 * 1.6, 0.01));
      // a cell is the seat's square plus one line for the name: no spare height
      expect(t.getRect(find.byType(SeatCircle).first).height, closeTo(slot + SeatGrid.labelRoom, 0.5));
    });

    testWidgets('video live column: an empty seat and a taken seat are the same size (it was 36 and 44), and the empty ones are golden', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SeatColumn(seatCount: 4, occupants: {2: user('a', 'Ann')}, hostId: 'host')),
      ));
      expect(find.byType(GoldenSeat), findsNWidgets(3), reason: '4 seats, one taken');
      final sizes = [for (var i = 0; i < 4; i++) t.getSize(find.byType(SeatCircle).at(i))];
      expect(sizes.toSet().length, 1, reason: 'every seat is the same size: $sizes');
      expect(sizes.first.width, 36);
    });

    testWidgets('video live column: a seat with a frame keeps its frame inside 36 x 1.6, and a locked seat keeps its padlock', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SeatColumn(seatCount: 3, occupants: {1: user('a', 'Ann', frame: 'https://x/f.png')}, lockedSeats: const {3}, hostId: 'host'),
        ),
      ));
      expect(t.getSize(find.byType(SeatCircle).at(0)).width, closeTo(36 * 1.6, 0.01));
      expect(find.byType(GoldenSeat), findsOneWidget, reason: 'seat 2 only: seat 1 is taken, seat 3 is locked');
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    });
  });

  group('the seat rows sit closer (it was 18 between rows)', () {
    testWidgets('the gap between one row\'s names and the next row\'s pictures is small', (t) async {
      await grid(t, seats: 12);
      final rects = [for (var i = 0; i < 12; i++) t.getRect(find.byType(SeatCircle).at(i))];
      final gap = rects[4].top - rects[0].bottom; // the next row's top to this row's bottom
      expect(SeatGrid.rowGap, lessThan(18));
      expect(gap, lessThanOrEqualTo(SeatGrid.rowGap + 4), reason: 'row 1 to row 2 is $gap');
      expect(rects[8].top - rects[4].bottom, closeTo(gap, 0.5), reason: 'every pair of rows is spaced the same');
    });

    testWidgets('the couple row is close to the first row of seats too (it was 14)', (t) async {
      await grid(t, cp: true, occupants: {24: user('host', 'Host')});
      final cp = t.getRect(find.byType(CpSeatsRow));
      final first = t.getRect(find.byType(SeatCircle).at(2));
      expect(first.top - cp.bottom, closeTo(SeatGrid.cpGap, 0.5));
      expect(SeatGrid.cpGap, lessThan(14));
    });
  });

  group('nobody on a couple seat wears an avatar frame', () {
    testWidgets('on a couple seat the person is drawn WITHOUT their frame', (t) async {
      await grid(t, cp: true, occupants: {24: user('host', 'Host', frame: 'https://x/frame.svga'), 25: user('g', 'Guest', frame: 'https://x/frame2.png')});
      for (final seat in [24, 25]) {
        final avatars = t.widgetList<AppAvatar>(find.descendant(of: find.byKey(ValueKey('cp-seat-$seat')), matching: find.byType(AppAvatar)));
        expect(avatars, hasLength(1));
        expect(avatars.single.frameUrl, isNull, reason: 'seat $seat');
      }
    });

    testWidgets('an ordinary seat still shows the frame (only the couple seats lose it)', (t) async {
      await grid(t, occupants: {1: user('a', 'Ann', frame: 'https://x/frame.png')});
      final avatars = t.widgetList<AppAvatar>(find.descendant(of: find.byType(SeatCircle).first, matching: find.byType(AppAvatar)));
      expect(avatars.single.frameUrl, 'https://x/frame.png');
    });

    testWidgets('the person on a couple seat is as big as the other one: no frame, no bigger host picture', (t) async {
      await grid(t, cp: true, occupants: {24: user('host', 'Host', frame: 'https://x/f.png'), 25: user('g', 'Guest')});
      final host = t.getSize(find.descendant(of: find.byKey(const ValueKey('cp-seat-24')), matching: find.byType(AppAvatar)));
      final guest = t.getSize(find.descendant(of: find.byKey(const ValueKey('cp-seat-25')), matching: find.byType(AppAvatar)));
      expect(host, guest);
    });
  });

  group('the Rankings period chips', () {
    testWidgets('four chips (Daily, Weekly, Monthly, Lifetime) all fit a 360 px phone with the tighter padding', (t) async {
      t.view.physicalSize = const Size(360, 400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      // the real font: the test font draws every letter as a wide block and would make any chip look too wide
      await t.runAsync(() async {
        final loader = FontLoader('Poppins')..addFont(rootBundle.load('assets/fonts/Poppins-SemiBold.ttf'));
        await loader.load();
      });
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChipRow(items: const ['Daily', 'Weekly', 'Monthly', 'Lifetime'], index: 3, chipPadding: 12, onChanged: (_) {}),
        ),
      ));
      final last = t.getRect(find.text('Lifetime'));
      expect(last.right, lessThanOrEqualTo(360 - 12), reason: 'the Lifetime chip is fully on screen without scrolling');
      expect(find.text('Monthly'), findsOneWidget);
    });
  });
}
