import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';

void main() {
  test('a profile row flagged is_ghost is a ghost viewer', () {
    final u = AppUser.fromRow({'id': 'a', 'name': 'G', 'username': 'g', 'is_ghost': true});
    expect(u.isGhost, isTrue);
  });

  test('an ordinary profile row (no flag, or false) is not', () {
    expect(AppUser.fromRow({'id': 'a', 'username': 'a'}).isGhost, isFalse);
    expect(AppUser.fromRow({'id': 'a', 'username': 'a', 'is_ghost': false}).isGhost, isFalse);
  });
}
