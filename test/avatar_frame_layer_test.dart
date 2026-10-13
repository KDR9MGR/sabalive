import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:sabalive/features/live/widgets/speaking_waves.dart';

const _frame = 'https://x.co/frame.png';

AppUser _u(String id, {bool frame = true}) =>
    AppUser(id: id, name: id, username: '@$id', frameUrl: frame ? _frame : null);

void main() {
  testWidgets('the frame is drawn BEHIND the picture, so it can never cover the face', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: AppAvatar(name: 'Asha', size: 60, frameUrl: _frame))),
    ));
    // the avatar's own stack: frame first (bottom), picture last (top)
    final stack = t.widget<Stack>(find.descendant(of: find.byType(AppAvatar), matching: find.byType(Stack)).first);
    expect(stack.children.first, isA<IgnorePointer>(), reason: 'the frame is the bottom layer');
    expect(stack.children.last, isA<Container>(), reason: 'the picture is on top');
    expect(find.byType(RemoteMedia), findsOneWidget);
  });

  testWidgets('without a frame the avatar is just the picture', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: AppAvatar(name: 'Asha', size: 60)))));
    expect(find.byType(RemoteMedia), findsNothing);
  });

  testWidgets('the frame fills the avatar\'s box and the picture sits smaller inside it: nothing is drawn outside', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: AppAvatar(name: 'Asha', size: 60, frameUrl: _frame))),
    ));
    final avatar = t.getRect(find.byType(AppAvatar));
    final frame = t.getRect(find.byType(RemoteMedia));
    expect(avatar.size, const Size(60, 60), reason: 'the layout box does not grow because of a frame');
    expect(frame, avatar, reason: 'the frame is exactly the box');
    final picture = t.getSize(find.descendant(of: find.byType(AppAvatar), matching: find.byType(Container)).first);
    expect(picture.width, closeTo(60 / AppAvatar.frameScale, 0.01));
  });

  test('which avatars get a frame: only ones big enough for it to read', () {
    expect(AppAvatar.showsFrame(kFrameMinSize, _frame), isTrue);
    expect(AppAvatar.showsFrame(kFrameMinSize - 1, _frame), isFalse);
    expect(AppAvatar.showsFrame(96, null), isFalse);
    expect(AppAvatar.showsFrame(96, ''), isFalse);
    expect(AppAvatar.pictureSize(100, _frame), closeTo(100 / AppAvatar.frameScale, 0.01));
    expect(AppAvatar.pictureSize(100, null), 100, reason: 'no frame: the picture takes the whole box');
    expect(AppAvatar.pictureSize(30, _frame), 30, reason: 'too small for a frame: just the picture');
  });

  testWidgets('the speaking ring stands outside the frame when there is one, and keeps the colour it was given', (t) async {
    Future<CustomPainter> painterFor(double frameScale) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SpeakingWaves(
              active: false,
              diameter: 60,
              frameScale: frameScale,
              color: const Color(0xFF22C55E),
              child: const SizedBox.square(dimension: 60),
            ),
          ),
        ),
      ));
      final paint = t.widgetList<CustomPaint>(find.descendant(of: find.byType(SpeakingWaves), matching: find.byType(CustomPaint)))
          .firstWhere((c) => c.painter != null);
      return paint.painter!;
    }

    final plain = await painterFor(1) as dynamic;
    final framed = await painterFor(AppAvatar.frameScale) as dynamic;
    expect(plain.diameter, 60);
    expect(framed.diameter, closeTo(60 * AppAvatar.frameScale, 0.01), reason: 'the ring is measured from the frame edge');
    expect(framed.color, const Color(0xFF22C55E));
  });

  group('a framed seat', () {
    test('takes picture x frame scale, but never more than its slot (the host may reach a little past)', () {
      expect(SeatCircle.footprintOf(plain: 56, framed: false, slot: 76), 56);
      expect(SeatCircle.footprintOf(plain: 56, framed: true), closeTo(56 * AppAvatar.frameScale, 0.01), reason: 'no slot: as big as wanted');
      expect(SeatCircle.footprintOf(plain: 56, framed: true, slot: 70), 70, reason: 'capped to the slot');
      expect(SeatCircle.footprintOf(plain: 66, framed: true, slot: 70, isHost: true), 70 + SeatCircle.hostFrameOverhang * 2,
          reason: 'the host may overhang');
      expect(SeatCircle.footprintOf(plain: 40, framed: true, slot: 76), closeTo(56, 0.01), reason: 'a small seat is not stretched to the slot');
    });

    Future<void> pumpRoom(WidgetTester t, {required double width, required Map<int, AppUser> occupants, int seats = 8}) async {
      t.view.physicalSize = Size(width, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SeatRoom(hostId: 'host', seatCount: seats, lockedSeats: const {}, occupants: occupants, onSeatTap: (_) {}),
        ),
      ));
    }

    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets('on a ${width.toInt()} px phone no frame covers another seat, its name or the next row', (t) async {
        final occupants = {
          1: _u('host'),
          2: _u('a'),
          3: _u('b', frame: false),
          5: _u('c'),
          6: _u('d'),
        };
        await pumpRoom(t, width: width, occupants: occupants);
        final frames = [for (final e in find.byType(RemoteMedia).evaluate()) t.getRect(find.byWidget(e.widget))];
        expect(frames.length, 4, reason: 'one frame per framed occupant');
        final labels = [for (var i = 0; i < 8; i++) t.getRect(find.byType(SeatLabel).at(i))];
        final circles = [for (var i = 0; i < 8; i++) t.getRect(find.byType(SeatCircle).at(i))];

        // a frame never reaches a name
        for (final f in frames) {
          for (final l in labels) {
            expect(f.overlaps(l.deflate(1)), isFalse, reason: 'frame $f over the name $l');
          }
        }
        // a frame never reaches another seat's picture area (the circle's own box; the host may brush its neighbour's edge)
        for (var i = 0; i < frames.length; i++) {
          for (var j = 0; j < frames.length; j++) {
            if (i == j) continue;
            final overlap = frames[i].intersect(frames[j]);
            final w = overlap.width < 0 || overlap.height < 0 ? 0.0 : overlap.width;
            expect(w, lessThanOrEqualTo(SeatCircle.hostFrameOverhang + 0.5), reason: 'frames $i and $j overlap by $w');
          }
        }
        // the grid still has four seats to a row
        expect({for (var i = 0; i < 4; i++) circles[i].top.round()}.length, 1);
      });
    }

    testWidgets('names line up across a row whether or not a seat wears a frame', (t) async {
      await pumpRoom(t, width: 360, occupants: {1: _u('host'), 2: _u('b', frame: false), 3: _u('c')});
      final tops = [for (var i = 0; i < 4; i++) t.getRect(find.byType(SeatLabel).at(i)).top.round()];
      expect(tops.toSet().length, 1, reason: 'one baseline for the row, got $tops');
    });

    testWidgets('the host\'s frame is a little bigger than a guest\'s', (t) async {
      await pumpRoom(t, width: 360, occupants: {1: _u('host'), 2: _u('a')});
      final host = t.getSize(find.byType(RemoteMedia).at(0));
      final guest = t.getSize(find.byType(RemoteMedia).at(1));
      expect(host.width, greaterThan(guest.width));
    });

    testWidgets('a framed seat in the video column keeps its frame inside its own box', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SeatColumn(seatCount: 3, occupants: {1: _u('a'), 2: _u('b')}, onSeatTap: (_) {}),
          ),
        ),
      ));
      final circles = [for (var i = 0; i < 3; i++) t.getRect(find.byType(SeatCircle).at(i))];
      final frames = [for (var i = 0; i < 2; i++) t.getRect(find.byType(RemoteMedia).at(i))];
      for (var i = 0; i < 2; i++) {
        expect(circles[i].contains(frames[i].center), isTrue);
        expect(frames[i].width, lessThanOrEqualTo(circles[i].width + 0.01), reason: 'the frame is inside the seat\'s box');
      }
      // seats stack without touching
      expect(circles[1].top, greaterThanOrEqualTo(circles[0].bottom));
    });
  });
}
