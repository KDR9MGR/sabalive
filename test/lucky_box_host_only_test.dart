import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Lucky Box is shown to the host only: no viewer screen draws it', () {
    for (final f in const [
      'lib/features/live/watch_live_screen.dart',
      'lib/features/live/watch_audio_room_screen.dart',
      'lib/features/live/watch_pk_battle_screen.dart',
    ]) {
      expect(File(f).readAsStringSync().contains('LuckyBoxBadge('), isFalse, reason: '$f must not show the Lucky Box');
    }
  });

  test('the host\'s own screen still shows it', () {
    expect(File('lib/features/live/live_broadcast_screen.dart').readAsStringSync().contains('LuckyBoxBadge('), isTrue);
  });
}
