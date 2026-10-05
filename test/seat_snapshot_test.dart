import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/seat_snapshot.dart';

AppUser _u(String id) => AppUser(id: id, name: id, username: '@$id');

void main() {
  test('seatOf finds the seat a user is on, or null', () {
    final snap = SeatSnapshot(
      occupants: {1: _u('host'), 4: _u('guest')},
      muted: {4},
      agoraUids: {1: 10, 4: null},
    );
    expect(snap.seatOf('host'), 1);
    expect(snap.seatOf('guest'), 4);
    expect(snap.seatOf('nobody'), isNull);
    expect(snap.seatOf(null), isNull);
  });
}
