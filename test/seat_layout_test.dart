import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/emote_overlay.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';

AppUser _u(String id, String name) => AppUser(id: id, name: name, username: '@$id');

void main() {
  testWidgets('the audio room lays seats out four to a row', (t) async {
    t.view.physicalSize = const Size(400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeatRoom(hostId: 'h', seatCount: 8, lockedSeats: const {}, onSeatTap: (_) {}),
      ),
    ));
    final rects = [for (var i = 0; i < 8; i++) t.getRect(find.byType(SeatCircle).at(i))];
    final firstRow = rects.take(4).toList();
    final secondRow = rects.skip(4).toList();
    expect({for (final r in firstRow) r.top.round()}.length, 1, reason: 'one row');
    expect({for (final r in firstRow) r.left.round()}.length, 4, reason: 'four across');
    expect(secondRow.first.top, greaterThan(firstRow.first.top), reason: 'the fifth seat starts a new row');
    expect({for (final r in secondRow) r.left.round()}, {for (final r in firstRow) r.left.round()});
  });

  testWidgets('a full room of 16 seats is four rows of four', (t) async {
    t.view.physicalSize = const Size(400, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeatRoom(hostId: 'h', seatCount: kMaxAudioSeats, lockedSeats: const {}, onSeatTap: (_) {}),
      ),
    ));
    expect(find.byType(SeatCircle), findsNWidgets(16));
    final tops = {for (var i = 0; i < 16; i++) t.getRect(find.byType(SeatCircle).at(i)).top.round()};
    expect(tops.length, 4);
  });

  test('the seat limits are 4 to 16 in steps of 4', () {
    expect(kMinAudioSeats, 4);
    expect(kMaxAudioSeats, 16);
    expect(kSeatStep, 4);
    expect(kSeatsPerRow, 4);
    expect(kMaxAudioSeats % kSeatStep, 0);
  });

  testWidgets('the viewer\'s SeatGrid (not only the host\'s stage) is four to a row too', (t) async {
    t.view.physicalSize = const Size(360, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SeatGrid(seatCount: 8, occupants: const {}, hostId: 'h', onSeatTap: (_) {}),
        ),
      ),
    ));
    final rects = [for (var i = 0; i < 8; i++) t.getRect(find.byType(SeatCircle).at(i))];
    expect({for (final r in rects.take(4)) r.top.round()}.length, 1);
    expect({for (final r in rects.take(4)) r.left.round()}.length, 4);
    expect(rects[4].top, greaterThan(rects[0].top));
  });

  testWidgets('an emote plays over the picture circle of the seat it was sent from, and only that seat', (t) async {
    final emotes = EmoteController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeatGrid(
          seatCount: 4,
          occupants: {1: _u('a', 'Ann'), 2: _u('b', 'Bo')},
          hostId: 'h',
          emotes: emotes,
          onSeatTap: (_) {},
        ),
      ),
    ));
    expect(find.byType(EmoteOverlay), findsNothing);
    emotes.show('b', emoji: '🔥');
    await t.pump();
    expect(find.byType(EmoteOverlay), findsOneWidget);
    // it sits on Bo's seat (the second), not Ann's
    final circle2 = t.getRect(find.byType(SeatCircle).at(1));
    final overlay = t.getRect(find.byType(EmoteOverlay));
    expect(circle2.contains(overlay.center), isTrue);
    expect(t.getRect(find.byType(SeatCircle).at(0)).contains(overlay.center), isFalse);
    await t.pump(const Duration(seconds: 7));
    expect(find.byType(EmoteOverlay), findsNothing);
    emotes.dispose();
  });

  test('Add seats / Remove seats move by four, and stop at the limits', () {
    expect(nextSeatCount(8, more: true), 12);
    expect(nextSeatCount(12, more: true), 16);
    expect(nextSeatCount(16, more: true), 16, reason: 'already full');
    expect(nextSeatCount(16, more: false), 12);
    expect(nextSeatCount(8, more: false), 4);
    expect(nextSeatCount(4, more: false), 4, reason: 'the least is 4');
  });

  test('a room that is not on a multiple of four (older rooms) snaps to the next step', () {
    expect(nextSeatCount(5, more: true), 8);
    expect(nextSeatCount(10, more: true), 12);
    expect(nextSeatCount(25, more: true), 25, reason: 'above the limit: nothing to add');
    expect(nextSeatCount(10, more: false), 8);
    expect(nextSeatCount(5, more: false), 4);
  });

  testWidgets('the host\'s seat is drawn a little bigger than a guest\'s', (t) async {
    final host = _u('h', 'Host');
    final guest = _u('g', 'Guest');
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SeatCircle(seat: 1, size: 60, occupant: host, isHost: true),
            SeatCircle(seat: 2, size: 60, occupant: guest),
          ],
        ),
      ),
    ));
    final hostBox = t.getSize(find.byType(SeatCircle).at(0));
    final guestBox = t.getSize(find.byType(SeatCircle).at(1));
    expect(hostBox.width, greaterThan(guestBox.width));
    expect(hostBox.width - guestBox.width, closeTo(SeatCircle.hostExtra, 0.5));
  });

  testWidgets('the video seats are stacked one above the other on one edge', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SeatColumn(
            seatCount: 5,
            occupants: {1: _u('a', 'Asha'), 3: _u('b', 'Bela')},
            hostId: 'a',
            onSeatTap: (_) {},
          ),
        ),
      ),
    ));
    final seats = [for (var i = 0; i < 5; i++) t.getRect(find.byType(SeatCircle).at(i))];
    expect({for (final s in seats) s.center.dx.round()}.length, 1, reason: 'one column');
    for (var i = 1; i < seats.length; i++) {
      expect(seats[i].top, greaterThan(seats[i - 1].bottom - 1), reason: 'each seat below the last');
    }
  });

  testWidgets('a tap on a video seat reports which seat', (t) async {
    final tapped = <int>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SeatColumn(seatCount: 3, occupants: const {}, onSeatTap: tapped.add),
        ),
      ),
    ));
    await t.tap(find.byType(SeatCircle).at(1));
    expect(tapped, [2]);
  });
}
