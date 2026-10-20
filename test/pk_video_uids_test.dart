import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/pk_video_uids.dart';

/// A viewer of a video battle puts the right host's video on the right side: left = the room's own host, right = the other host.
void main() {
  ({int? left, int? right}) uids({int? mine, int? theirs, required Set<int> joined}) => pkVideoUids(mine: mine, theirs: theirs, joined: joined);

  test('both hosts known and joined: each on its own side, whatever the numbers (a bigger uid can be the room\'s own host)', () {
    expect(uids(mine: 900, theirs: 100, joined: {100, 900}), (left: 900, right: 100));
    expect(uids(mine: 100, theirs: 900, joined: {100, 900}), (left: 100, right: 900));
  });

  test('seat guests or others in the channel never take a half', () {
    expect(uids(mine: 50, theirs: 70, joined: {10, 50, 70, 99}), (left: 50, right: 70));
  });

  test('this room host\'s new uid is still on its way (the stored one is stale): the other host is known, so the OTHER joined uid is mine', () {
    // the room's host re-joined as 300 but the database still says 200; the other host is 100
    expect(uids(mine: 200, theirs: 100, joined: {100, 300}), (left: 300, right: 100));
  });

  test('the other host\'s uid is not known (yet): the joined uid that is not mine is theirs', () {
    expect(uids(mine: 300, theirs: null, joined: {100, 300}), (left: 300, right: 100));
    expect(uids(mine: 300, theirs: 555, joined: {100, 300}), (left: 300, right: 100), reason: 'a stale uid for them is ignored too');
  });

  test('only the other host is recognised: the rest is mine', () {
    expect(uids(mine: null, theirs: 100, joined: {100, 300}), (left: 300, right: 100));
  });

  test('one host has not joined the battle channel yet: its half waits, nobody else fills it', () {
    expect(uids(mine: 300, theirs: 100, joined: {300}), (left: 300, right: null));
    expect(uids(mine: 300, theirs: 100, joined: {100}), (left: null, right: 100));
  });

  test('neither is recognised: two hosts fill the halves in a fixed order, one unknown host waits', () {
    expect(uids(mine: null, theirs: null, joined: {700, 200}), (left: 200, right: 700));
    expect(uids(mine: null, theirs: null, joined: {700}), (left: null, right: null), reason: 'better empty than the wrong host');
    expect(uids(mine: 1, theirs: 2, joined: {}), (left: null, right: null));
  });

  test('the two halves are never the same person, even when the database gives the same uid for both lives', () {
    final r = uids(mine: 100, theirs: 100, joined: {100, 300});
    expect(r.left, 100);
    expect(r.right, 300, reason: 'theirs equals mine: it cannot be theirs, so the other joined uid is');
  });
}
